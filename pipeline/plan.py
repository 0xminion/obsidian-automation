"""Stage 2 planning module.

Takes extracted sources from Stage 1, performs semantic dedup and concept
pre-search, then generates creation plans via hermes agent.

Flow:
  plan_sources(manifest, cfg) -> Plans
    ├─ dedup_check()          — content fingerprint dedup against vault
    ├─ concept_search()       — semantic concept matching via qmd
    └─ generate_plans()       — hermes agent plan generation
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
from pathlib import Path
from typing import Optional

from pipeline.config import Config
from pipeline.models import ConceptMatch, ExtractedSource, Language, Manifest, Plan, Plans, Template

log = logging.getLogger(__name__)


# ─── Fingerprint helpers ──────────────────────────────────────────────────────

def _fingerprint(text: str) -> str:
    """Normalize and extract content fingerprint (first 800 chars).

    Lowercases, collapses whitespace, and truncates.
    """
    normalized = re.sub(r"\s+", " ", text.lower().strip())[:800]
    return normalized


def _jaccard_similarity(fp1: str, fp2: str, ngram: int = 3) -> float:
    """Character n-gram Jaccard similarity. O(n) with sets."""
    if not fp1 or not fp2:
        return 0.0
    ng1 = {fp1[i:i + ngram] for i in range(len(fp1) - ngram + 1)}
    ng2 = {fp2[i:i + ngram] for i in range(len(fp2) - ngram + 1)}
    if not ng1 or not ng2:
        return 0.0
    return len(ng1 & ng2) / len(ng1 | ng2)


def _extract_body(content: str) -> str:
    """Extract body text (after YAML frontmatter) from a markdown file."""
    m = re.match(r"^---\n.*?\n---\n(.*)", content, re.DOTALL)
    return m.group(1) if m else content


# ─── Dedup check ──────────────────────────────────────────────────────────────

def dedup_check(manifest: Manifest, cfg: Config) -> Manifest:
    """Check each source against existing vault sources using content fingerprinting.

    Builds fingerprints from existing vault source files, then compares each
    manifest entry using Jaccard similarity on character 3-grams.
    Sources with similarity > 0.85 are considered duplicates.

    Returns a filtered Manifest with duplicates removed.
    """
    sources_dir = cfg.sources_dir

    # Build fingerprint index from existing sources
    existing_fps: list[dict] = []
    if sources_dir.is_dir():
        for fpath in sorted(sources_dir.glob("*.md")):
            try:
                content = fpath.read_text(encoding="utf-8", errors="replace")
                body = _extract_body(content)
                fp = _fingerprint(body)
                if len(fp) > 100:  # Skip empty/stub sources
                    existing_fps.append({"name": fpath.stem, "fp": fp})
            except Exception:
                continue

    # Check each manifest entry against existing sources
    filtered: list[ExtractedSource] = []
    for entry in manifest.entries:
        entry_fp = _fingerprint(entry.content)
        if len(entry_fp) < 100:
            filtered.append(entry)
            continue

        is_dup = False
        for existing in existing_fps:
            sim = _jaccard_similarity(entry_fp, existing["fp"])
            if sim > 0.85:
                log.info(
                    "Dedup: %s matches existing %s (sim=%.3f)",
                    entry.hash,
                    existing["name"],
                    round(sim, 3),
                )
                is_dup = True
                break

        if not is_dup:
            filtered.append(entry)

    return Manifest(entries=filtered)


# ─── QMD concept search ──────────────────────────────────────────────────────

def _run_qmd(query: str, cfg: Config) -> list[ConceptMatch]:
    """Run qmd CLI semantic search and return concept matches.

    Uses flags: --json -n 5 --min-score 0.2 -c <collection> --no-rerank
    Falls back to empty list on any error (timeout, parse failure, etc.).
    """
    if not query or not query.strip():
        return []

    cmd = [
        cfg.qmd_cmd, "query", query,
        "--json", "-n", "5",
        "--min-score", "0.2",
        "-c", cfg.qmd_collection,
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=cfg.plan_timeout,
        )

        # Strip cmake/Vulkan noise from stdout — find JSON array start
        stdout = result.stdout
        for marker in ["[\n  {", "[\n{", "[{"]:
            idx = stdout.find(marker)
            if idx >= 0:
                stdout = stdout[idx:].rstrip()
                break

        data = json.loads(stdout)
        matches = []
        for item in data:
            if not isinstance(item, dict):
                continue
            score = item.get("score", 0)
            if score < 0.2:
                continue
            # Extract concept name from file path
            f = item.get("file", item.get("path", ""))
            name = f.split("/")[-1].replace(".md", "") if "/" in f else f.replace(".md", "")
            if name:
                matches.append(ConceptMatch(concept=name, score=round(score, 3)))
        return matches

    except subprocess.TimeoutExpired:
        log.warning("qmd timeout for query: %s", query[:80])
        return []
    except (json.JSONDecodeError, KeyError, Exception) as e:
        log.warning("qmd error: %s", e)
        return []


def concept_search(manifest: Manifest, cfg: Config) -> dict[str, list[ConceptMatch]]:
    """Search existing concepts via qmd for each source.

    Builds query from title + content preview + concept names.
    Returns hash -> [ConceptMatch] mapping.
    """
    result: dict[str, list[ConceptMatch]] = {}

    for entry in manifest.entries:
        # Build query from title + content preview
        query = f"{entry.title} {entry.content[:500]}".strip()[:800]
        if not query:
            result[entry.hash] = []
            continue

        matches = _run_qmd(query, cfg)
        result[entry.hash] = matches

    return result


# ─── Plan prompt builder ─────────────────────────────────────────────────────

def build_plan_prompt(
    manifest: Manifest,
    concept_matches: dict[str, list[ConceptMatch]],
    cfg: Config,
) -> str:
    """Compose the agent prompt with all extracted data.

    Includes rules for language detection, template selection, tag suggestions,
    and existing concept/MoC context.
    """
    # Load common instructions if available
    common_path = cfg.prompts_dir / "common-instructions.prompt"
    common = ""
    if common_path.exists():
        try:
            common = common_path.read_text(encoding="utf-8").strip()
            common = common.replace("{VAULT_PATH}", str(cfg.vault_path))
        except Exception:
            pass

    # Count existing concepts
    concept_count = 0
    if cfg.concepts_dir.is_dir():
        concept_count = len(list(cfg.concepts_dir.glob("*.md")))

    # Build sources block
    sources_block = ""
    for i, entry in enumerate(manifest.entries):
        h = entry.hash
        title = entry.title[:120]
        content_preview = entry.content[:300].replace("\n", " ")
        source_type = entry.type.value if hasattr(entry.type, "value") else str(entry.type)
        author = entry.author or "unknown"
        matches = concept_matches.get(h, [])
        match_dicts = [{"concept": m.concept, "score": m.score} for m in matches]

        sources_block += f"""
---
Source {i+1}:
  hash: {h}
  title: {title}
  type: {source_type}
  author: {author}
  content_preview: {content_preview}
  concept_matches: {json.dumps(match_dicts)}
"""

    common_section = f"{common}\n\n" if common else ""

    prompt = f"""{common_section}You are a planning agent for an Obsidian wiki pipeline. For each extracted source below, output a creation plan as JSON.

VAULT CONCEPTS DIRECTORY: {concept_count} existing concepts

SOURCES TO PLAN:{sources_block}
---

For EACH source, output a JSON object in a JSON array. Schema per source:

{{"hash": "<source hash>", "title": "<ACTUAL content title for filename — NOT URL slug, NOT platform name>", "language": "en" or "zh", "template": "standard" or "technical" or "chinese", "tags": ["topic-specific tags in English"], "concept_updates": ["existing concept names to update"], "concept_new": ["new concept names to create"], "moc_targets": ["MoC names this source belongs to"]}}

RULES:
- title: Use the content REAL title. Tweet → first meaningful topic. Blog → article title. YouTube → video title.
- NEVER use: "Tweet - user - ID", "Blog - slug", "YouTube - VIDEO_ID", URL slugs
- language: Chinese content → "zh", everything else → "en"
- template: Data/methodology/findings → "technical". Narrative/philosophical → "standard". Chinese → "chinese".
- tags: Topic-specific English only. NO: x.com, tweet, source, url
- concept_matches are pre-found via semantic search — rank-sorted by relevance, confirm which are real matches vs tangential
- concept_new: only if genuinely new concept
- Be concise. Output ONLY the JSON array, no explanation.

OUTPUT ONLY VALID JSON."""

    return prompt


# ─── Plan generation via hermes agent ─────────────────────────────────────────

def _parse_agent_output(raw: str) -> list[dict]:
    """Parse hermes agent output into a list of plan dicts.

    Handles ANSI escape codes, box-drawing characters, and partial failures.
    Tries fast-path JSON array first, then falls back to object-by-object parsing.
    """
    # Strip ANSI escape codes and box-drawing characters
    raw_clean = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", raw)
    raw_clean = re.sub(r"[╭╮╰╯│─╮╰╯├┤┬┴┼]", "", raw_clean)

    # Fast path: try to find a JSON array
    json_match = re.search(r"\[.*\]", raw_clean, re.DOTALL)
    if json_match:
        try:
            plans = json.loads(json_match.group())
            if isinstance(plans, list):
                return [p for p in plans if isinstance(p, dict) and "hash" in p]
        except json.JSONDecodeError:
            pass  # Fall through to object-by-object parsing

    # Object-by-object parsing with partial failure recovery
    plans = []
    depth = 0
    start = -1
    for i, c in enumerate(raw_clean):
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0 and start >= 0:
                try:
                    obj = json.loads(raw_clean[start:i + 1])
                    if isinstance(obj, dict) and "hash" in obj:
                        plans.append(obj)
                except (json.JSONDecodeError, Exception):
                    log.warning("Failed to parse JSON object at offset %d", start)
                start = -1

    return plans


def generate_plans(
    manifest: Manifest,
    concept_matches: dict[str, list[ConceptMatch]],
    cfg: Config,
) -> Plans:
    """Generate creation plans via hermes agent.

    Builds the planning prompt, calls hermes chat, parses the JSON response,
    and validates each plan against the schema.
    """
    prompt = build_plan_prompt(manifest, concept_matches, cfg)

    # Save prompt for debugging
    extract_dir = cfg.resolved_extract_dir
    extract_dir.mkdir(parents=True, exist_ok=True)
    prompt_file = extract_dir / "plan_prompt.md"
    prompt_file.write_text(prompt, encoding="utf-8")
    log.info("Plan prompt size: %d chars", len(prompt))

    # Call hermes agent
    cmd = [cfg.agent_cmd, "chat", "-q", prompt, "-Q"]
    plan_dicts: list[dict] = []

    for attempt in range(cfg.max_retries):  # configurable retries
        try:
            log.info("Plan agent attempt %d/%d", attempt + 1, cfg.max_retries)
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=cfg.plan_timeout,
            )
            if result.returncode == 0 and result.stdout.strip():
                plan_dicts = _parse_agent_output(result.stdout)
                if plan_dicts:
                    break
            log.warning("Plan agent attempt %d failed (exit %d): %s",
                        attempt + 1, result.returncode,
                        result.stderr[:200] if result.stderr else "no stderr")
            import time
            if attempt < cfg.max_retries - 1:
                time.sleep(2 ** attempt)
        except subprocess.TimeoutExpired:
            log.warning("Plan agent timeout on attempt %d", attempt + 1)
            import time
            if attempt < cfg.max_retries - 1:
                time.sleep(2 ** attempt)

    if not plan_dicts:
        log.error("Could not parse any plans from agent output")
        return Plans(plans=[])

    # Convert to Plan objects with validation
    plans: list[Plan] = []
    known_hashes = {e.hash for e in manifest.entries}

    for d in plan_dicts:
        try:
            # Validate required fields
            if "hash" not in d or "title" not in d:
                log.warning("Plan missing required fields (hash/title), skipping")
                continue

            # Skip plans for unknown hashes
            if d["hash"] not in known_hashes:
                log.warning("Plan for unknown hash %s, skipping", d.get("hash"))
                continue

            plan = Plan(
                hash=d["hash"],
                title=d["title"][:120],
                language=Language(d.get("language", "en")),
                template=Template(d.get("template", "standard")),
                tags=d.get("tags", []),
                concept_updates=d.get("concept_updates", []),
                concept_new=d.get("concept_new", []),
                moc_targets=d.get("moc_targets", []),
            )
            plans.append(plan)
        except (ValueError, KeyError) as e:
            log.warning("Failed to validate plan: %s", e)
            continue

    log.info("Parsed %d plans from %d agent outputs", len(plans), len(plan_dicts))

    # Save plans
    plans_collection = Plans(plans=plans)
    plans_collection.save(extract_dir)

    return plans_collection


# ─── Main entry point ─────────────────────────────────────────────────────────

def plan_sources(manifest: Manifest, cfg: Config) -> Plans:
    """Main entry point for Stage 2 planning.

    Step 0: Dedup check — skip sources already in vault
    Step 1: Semantic concept pre-search via qmd
    Step 2: Generate plans via hermes agent

    Returns Plans object (possibly empty on total failure).
    """
    log.info("=== Stage 2: Plan Batch (%d sources) ===", len(manifest.entries))

    if not manifest.entries:
        log.info("No sources to plan, returning empty Plans")
        return Plans(plans=[])

    # Step 0: Dedup check
    log.info("Running semantic dedup check against existing sources...")
    filtered_manifest = dedup_check(manifest, cfg)
    removed = len(manifest.entries) - len(filtered_manifest.entries)
    if removed > 0:
        log.info("Found %d semantic duplicates — removed from pipeline", removed)
    else:
        log.info("No semantic duplicates found")

    if not filtered_manifest.entries:
        log.info("All sources were duplicates, returning empty Plans")
        return Plans(plans=[])

    # Step 1: Concept pre-search
    log.info("Pre-searching concept matches via qmd (semantic)...")
    concept_matches = concept_search(filtered_manifest, cfg)
    matched_count = sum(len(v) for v in concept_matches.values())
    log.info(
        "Concept matching complete: %d total matches across %d sources",
        matched_count,
        len(filtered_manifest.entries),
    )

    # Step 2: Generate plans
    log.info("Spawning planning agent...")
    plans = generate_plans(filtered_manifest, concept_matches, cfg)

    if plans.plans:
        log.info("=== Stage 2 complete: %d plans generated ===", len(plans.plans))
    else:
        log.error("=== Stage 2 complete: 0 plans generated ===")

    return plans
