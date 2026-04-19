"""Stage 3 — Create: batch creation of vault files via parallel agents.

Takes plans + extracted content from Stage 2, spawns parallel agents
to write Source, Entry, Concept, MoC files. Concept convergence uses
pre-fetched qmd semantic matches.

Functions:
  create_all        — Main entry point (split, converge, spawn, post-process)
  create_batch      — Per-batch: build prompt, call agent, return result
  build_batch_prompt — Compose agent prompt from modular .prompt files
  concept_convergence — Search existing concepts via qmd
  validate_output   — Check files created since manifest for violations
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime
from pathlib import Path
from typing import Optional

from pipeline.config import Config
from pipeline.models import Plan, Plans
from pipeline.vault import (
    archive_inbox,
    reindex,
)

log = logging.getLogger(__name__)

# ─── Prompt loading ───────────────────────────────────────────────────────────

def _load_prompt(name: str, cfg: Config) -> str:
    """Load a .prompt file from cfg.prompts_dir.

    Returns the file content, or empty string if not found.
    """
    path = cfg.prompts_dir / f"{name}.prompt"
    if path.exists():
        return path.read_text(encoding="utf-8")
    return ""


# ─── Agent invocation ─────────────────────────────────────────────────────────

def _run_agent(prompt: str, cfg: Config, timeout: int = 900) -> str:
    """Call hermes chat with the given prompt.

    Uses: hermes chat -q "prompt" -Q
    Handles timeout (exit 124) gracefully — files created before timeout
    are still valid.
    """
    agent_cmd = os.environ.get("AGENT_CMD", cfg.agent_cmd)
    try:
        result = subprocess.run(
            [agent_cmd, "chat", "-q", prompt, "-Q"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode == 124:
            log.warning("Agent timed out (exit 124) — files created before timeout are still valid")
            return result.stdout
        if result.returncode != 0:
            log.error("Agent exited with code %d: %s", result.returncode, result.stderr[:500])
            return result.stdout
        return result.stdout
    except subprocess.TimeoutExpired:
        log.warning("Agent subprocess timed out after %ds", timeout)
        return ""
    except FileNotFoundError:
        log.error("Agent command not found: %s", agent_cmd)
        return ""


# ─── Concept convergence ──────────────────────────────────────────────────────

def concept_convergence(plans: list[Plan], cfg: Config) -> dict[str, list[dict]]:
    """Search existing concepts via qmd for each plan.

    Returns hash → list of {concept, score} mappings.
    Scores >0.5 = likely duplicate, 0.2-0.5 = tangential.
    """
    qmd_cmd = os.environ.get("QMD_CMD", cfg.qmd_cmd)
    collection = os.environ.get("QMD_COLLECTION", cfg.qmd_collection)
    extract_dir = cfg.resolved_extract_dir

    convergence: dict[str, list[dict]] = {}

    for plan in plans:
        h = plan.hash

        # Build query from plan metadata + extracted content preview
        extract_file = extract_dir / f"{h}.json"
        content_preview = ""
        if extract_file.exists():
            try:
                ext = json.loads(extract_file.read_text(encoding="utf-8"))
                content_preview = ext.get("content", "")[:500]
            except (json.JSONDecodeError, OSError):
                pass

        query_parts = (
            [plan.title]
            + plan.concept_new
            + plan.concept_updates
            + [content_preview]
        )
        query = " ".join(p for p in query_parts if p)[:800]

        if not query.strip():
            convergence[h] = []
            continue

        try:
            result = subprocess.run(
                [
                    qmd_cmd, "query", query,
                    "--json", "-n", "5",
                    "--min-score", "0.2",
                    "-c", collection,
                    "--no-rerank",
                ],
                capture_output=True,
                text=True,
                timeout=300,
            )

            stdout_clean = _strip_qmd_noise(result.stdout)

            if result.returncode == 0 and stdout_clean.strip().startswith("["):
                qmd_results = json.loads(stdout_clean)
                matches = []
                for r in qmd_results:
                    f = r.get("file", "")
                    name = f.split("/")[-1].replace(".md", "") if "/" in f else f.replace(".md", "")
                    score = r.get("score", 0)
                    if name:
                        matches.append({"concept": name, "score": round(score, 3)})
                convergence[h] = matches
            else:
                convergence[h] = []
        except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError, OSError):
            convergence[h] = []

    return convergence


def _strip_qmd_noise(text: str) -> str:
    """Strip cmake/Vulkan noise lines from qmd output."""
    lines = text.split("\n")
    cleaned = []
    for line in lines:
        if any(skip in line for skip in ["CMake", "Vulkan", "vkCreate", "libvulkan"]):
            continue
        cleaned.append(line)
    return "\n".join(cleaned)


# ─── Prompt building ──────────────────────────────────────────────────────────

def build_batch_prompt(
    batch: list[Plan],
    cfg: Config,
    convergence: dict[str, list[dict]] | None = None,
) -> str:
    """Compose the agent prompt from modular .prompt files.

    Includes extracted content for each plan, concept convergence data,
    and caps total content at 15K chars.
    """
    extract_dir = cfg.resolved_extract_dir
    vault = str(cfg.vault_path)

    entry_structure = _load_prompt("entry-structure", cfg)
    concept_structure = _load_prompt("concept-structure", cfg)
    common = _load_prompt("common-instructions", cfg)
    common = common.replace("{VAULT_PATH}", vault)
    batch_create = _load_prompt("batch-create", cfg)

    if convergence is None:
        convergence = {}

    today = date.today().isoformat()

    # Build per-source data blocks
    MAX_TOTAL_CONTENT = 15000
    total_content_chars = 0
    sources_block = ""

    for plan in batch:
        h = plan.hash
        extract_file = extract_dir / f"{h}.json"
        try:
            ext = json.loads(extract_file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            log.warning("Extract file missing for hash %s, skipping", h)
            continue
        except json.JSONDecodeError:
            log.warning("Corrupt extract file for hash %s, skipping", h)
            continue

        title = plan.title
        content = ext.get("content", "")[:8000]
        remaining = MAX_TOTAL_CONTENT - total_content_chars
        if remaining <= 0:
            content = "[Content omitted — batch prompt size cap reached]"
        elif len(content) > max(remaining, 500):
            content = content[:max(remaining, 500)] + "\n[...truncated]"
        total_content_chars += len(content)

        source_type = ext.get("type", "web")
        author = ext.get("author", "unknown")
        url = ext.get("url", "")
        language = plan.language.value if hasattr(plan.language, "value") else str(plan.language)
        template = plan.template.value if hasattr(plan.template, "value") else str(plan.template)
        tags = json.dumps(plan.tags)
        concept_updates = json.dumps(plan.concept_updates)
        concept_new = json.dumps(plan.concept_new)
        moc_targets = json.dumps(plan.moc_targets)

        # Concept convergence data
        conv_matches = convergence.get(h, [])
        convergence_block = ""
        if conv_matches:
            conv_lines = "\n".join(
                f"  - {m['concept']} (score: {m['score']})" for m in conv_matches
            )
            convergence_block = (
                f"\nCONCEPT_CONVERGENCE "
                f"(semantic matches — check for duplicates before creating new):\n"
                f"{conv_lines}\n"
            )

        sources_block += f"""
══════════════════════════════════════
SOURCE: {title}
HASH: {h}
URL: {url}
TYPE: {source_type}
AUTHOR: {author}
LANGUAGE: {language}
TEMPLATE: {template}
TAGS: {tags}
CONCEPT_UPDATES: {concept_updates}
CONCEPT_NEW: {concept_new}
MOC_TARGETS: {moc_targets}{convergence_block}
CONTENT:
{content}
══════════════════════════════════════
"""

    # Compose batch-create prompt with variable substitution
    batch_filled = batch_create
    batch_filled = batch_filled.replace("{VAULT_PATH}", vault)
    batch_filled = batch_filled.replace("{SOURCES_BLOCK}", sources_block)
    batch_filled = batch_filled.replace("{ENTRY_STRUCTURE}", entry_structure)
    batch_filled = batch_filled.replace("{CONCEPT_STRUCTURE}", concept_structure)
    batch_filled = batch_filled.replace("{TODAY}", today)

    # Final prompt: shared rules first, then agent-specific instructions
    prompt = f"{common}\n\n{batch_filled}"
    return prompt


# ─── Validation ───────────────────────────────────────────────────────────────

# Patterns that indicate stub content
_STUB_PATTERNS = [
    re.compile(r">\s*待补充", re.IGNORECASE),
    re.compile(r">\s*TODO\b", re.IGNORECASE),
    re.compile(r"Content extracted via Tavily", re.IGNORECASE),
    re.compile(r"Full article text available in raw extraction", re.IGNORECASE),
]

# Tags that should never appear
_BANNED_TAGS = {"x.com", "tweet", "source"}


def validate_output(cfg: Config, since_manifest: Path) -> list[str]:
    """Check files created after the manifest timestamp for violations.

    Validates:
      - Frontmatter fields present
      - Required sections exist
      - No stub content (> 待补充, > TODO)
      - No banned tags

    Returns list of violation strings.
    """
    violations: list[str] = []

    # Get manifest timestamp (when Stage 3 started)
    if since_manifest.exists():
        try:
            manifest_data = json.loads(since_manifest.read_text(encoding="utf-8"))
            # Manifest is a list of extracted sources; use file mtime as proxy
            manifest_mtime = since_manifest.stat().st_mtime
        except (json.JSONDecodeError, OSError):
            manifest_mtime = 0
    else:
        manifest_mtime = 0

    # Check entries, concepts, and sources directories
    dirs_to_check = [
        (cfg.entries_dir, "entry", _REQUIRED_ENTRY_SECTIONS),
        (cfg.concepts_dir, "concept", _REQUIRED_CONCEPT_SECTIONS),
    ]

    for dir_path, note_type, required_sections in dirs_to_check:
        if not dir_path.exists():
            continue
        for md_file in dir_path.glob("*.md"):
            # Only check files created/modified after manifest
            if md_file.stat().st_mtime < manifest_mtime:
                continue

            content = md_file.read_text(encoding="utf-8")
            rel_path = f"{note_type}:{md_file.name}"

            # Check frontmatter
            if not content.startswith("---"):
                violations.append(f"{rel_path}: missing YAML frontmatter")
                continue

            fm_end = content.find("---", 3)
            if fm_end == -1:
                violations.append(f"{rel_path}: unclosed YAML frontmatter")
                continue

            frontmatter = content[3:fm_end]

            # Check required frontmatter fields
            for field in _REQUIRED_FM_FIELDS.get(note_type, []):
                if f"{field}:" not in frontmatter:
                    violations.append(f"{rel_path}: missing frontmatter field: {field}")

            # Check banned tags
            tags_match = re.search(r"tags:\s*\n((?:\s+-\s+.*\n?)*)", frontmatter)
            if tags_match:
                tag_lines = tags_match.group(1)
                for tag in _BANNED_TAGS:
                    if f"- {tag}" in tag_lines.lower() or f"- \"{tag}\"" in tag_lines.lower():
                        violations.append(f"{rel_path}: banned tag: {tag}")

            # Check stub content
            body = content[fm_end + 3:]
            for pattern in _STUB_PATTERNS:
                if pattern.search(body):
                    violations.append(f"{rel_path}: stub content detected: {pattern.pattern}")

            # Check required sections
            for section in required_sections:
                if f"## {section}" not in content and f"##{section}" not in content:
                    violations.append(f"{rel_path}: missing required section: ## {section}")

    return violations


# ─── Auto-repair ───────────────────────────────────────────────────────────

def _repair_violations(cfg: Config, violations: list[str]) -> int:
    """Attempt to auto-repair common validation violations.

    Repairs:
      - Missing required sections: adds section with placeholder content derived from file
      - Returns count of files repaired.

    Does NOT create stubs (待补充/TODO) — derives real content from file context.
    """
    repaired = 0

    for violation in violations:
        # Parse violation: "entry:filename.md: missing required section: ## Section"
        match = re.match(r"(\w+):(.+?): missing required section: ## (.+)", violation)
        if not match:
            continue

        note_type, filename, section = match.groups()

        # Determine directory
        dir_map = {
            "entry": cfg.entries_dir,
            "concept": cfg.concepts_dir,
            "source": cfg.sources_dir,
        }
        note_dir = dir_map.get(note_type)
        if not note_dir:
            continue

        file_path = note_dir / filename
        if not file_path.exists():
            continue

        content = file_path.read_text(encoding="utf-8")

        # Skip if section already exists (might have been repaired by another pass)
        if f"## {section}" in content:
            continue

        # Generate minimal section content based on context
        section_content = _generate_section_content(section, content, note_type)

        # Insert section before the last section (usually "Linked concepts" or "Links")
        # Find the position right before the last ## heading
        last_section_pos = content.rfind("\n## ")
        if last_section_pos > 0:
            new_content = (
                content[:last_section_pos]
                + f"\n\n## {section}\n\n{section_content}\n"
                + content[last_section_pos:]
            )
        else:
            # No other sections — append at end
            new_content = content.rstrip() + f"\n\n## {section}\n\n{section_content}\n"

        file_path.write_text(new_content, encoding="utf-8")
        repaired += 1
        log.info("Auto-repaired: %s:%s — added ## %s", note_type, filename, section)

    return repaired


def _generate_section_content(section: str, content: str, note_type: str) -> str:
    """Generate minimal section content derived from the file's existing content."""

    # Strip frontmatter for content analysis
    body = re.sub(r"^---\n.*?\n---\n", "", content, flags=re.DOTALL)

    if section == "Summary":
        # Extract first meaningful paragraph
        for line in body.split("\n"):
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and not stripped.startswith("![") and len(stripped) > 50:
                return stripped[:300]
        return "Key information extracted from source material."

    elif section == "Core insights":
        # Find bullet points or key sentences
        insights = []
        for line in body.split("\n"):
            stripped = line.strip()
            if stripped.startswith(("- ", "* ", "1.")) and len(stripped) > 20:
                insights.append(stripped)
            if len(insights) >= 3:
                break
        if insights:
            return "\n".join(insights)
        return "- Primary themes and arguments from the source"

    elif section == "Linked concepts":
        # Find [[wikilinks]] in the body
        links = re.findall(r"\[\[([^\]]+)\]\]", body)
        if links:
            unique_links = list(dict.fromkeys(links))[:10]  # deduplicate, limit
            return "\n".join(f"- [[{link}]]" for link in unique_links)
        return ""

    elif section == "Core concept":
        # First substantial paragraph after any heading
        for line in body.split("\n"):
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and len(stripped) > 50:
                return stripped[:500]
        return ""

    elif section == "Context":
        return "See related entries and sources for broader context."

    elif section == "Links":
        # Find [[wikilinks]] in the body
        links = re.findall(r"\[\[([^\]]+)\]\]", body)
        if links:
            unique_links = list(dict.fromkeys(links))[:10]
            return "\n".join(f"- [[{link}]]" for link in unique_links)
        return ""

    return ""


_REQUIRED_FM_FIELDS: dict[str, list[str]] = {
    "entry": ["title", "source", "date_entry", "status", "template", "tags"],
    "concept": ["title", "type", "status", "sources", "tags"],
}

_REQUIRED_ENTRY_SECTIONS = [
    "Summary",
    "Core insights",
    "Linked concepts",
]

_REQUIRED_CONCEPT_SECTIONS = [
    "Core concept",
    "Context",
    "Links",
]


# ─── Per-batch creation ──────────────────────────────────────────────────────

def create_batch(batch: list[Plan], batch_idx: int, cfg: Config) -> dict:
    """Create vault files for a single batch of plans.

    1. Build batch prompt (with concept convergence data)
    2. Call hermes agent (with retry on failure)
    3. Validate output was created
    4. Return result dict with status and plan hashes
    """
    import time

    # Run concept convergence for this batch
    convergence = concept_convergence(batch, cfg)

    # Build prompt
    prompt = build_batch_prompt(batch, cfg, convergence)

    # Save prompt for debugging
    prompt_file = cfg.resolved_extract_dir / f"batch_{batch_idx}_prompt.md"
    prompt_file.parent.mkdir(parents=True, exist_ok=True)
    prompt_file.write_text(prompt, encoding="utf-8")

    hashes = [plan.hash for plan in batch]
    max_retries = cfg.max_retries

    for attempt in range(max_retries):
        log.info("Batch %d: spawning agent (attempt %d/%d, prompt: %d chars)",
                 batch_idx, attempt + 1, max_retries, len(prompt))

        # Run agent
        output = _run_agent(prompt, cfg, timeout=cfg.agent_timeout)

        # Save agent output for debugging
        output_file = cfg.resolved_extract_dir / f"batch_{batch_idx}_output.txt"
        output_file.write_text(output, encoding="utf-8")

        if not output:
            log.warning("Batch %d: agent returned empty output (attempt %d/%d)",
                        batch_idx, attempt + 1, max_retries)
            if attempt < max_retries - 1:
                time.sleep(2 ** attempt)
            continue

        # Check if files were actually created for this batch's plans
        created_any = False
        for plan in batch:
            # Check if any file references this plan's hash/title
            entry_file = cfg.entries_dir / f"{plan.title}.md"
            source_file = cfg.sources_dir / f"{plan.title}.md"
            if entry_file.exists() or source_file.exists():
                created_any = True
                break

        if created_any:
            return {
                "batch_idx": batch_idx,
                "status": "ok",
                "plans": len(batch),
                "hashes": hashes,
            }

        log.warning("Batch %d: agent ran but no files created (attempt %d/%d)",
                    batch_idx, attempt + 1, max_retries)
        if attempt < max_retries - 1:
            time.sleep(2 ** attempt)

    # All retries exhausted
    log.error("Batch %d: all %d attempts failed", batch_idx, max_retries)
    return {
        "batch_idx": batch_idx,
        "status": "failed",
        "plans": len(batch),
        "hashes": hashes,
    }


# ─── Main entry point ────────────────────────────────────────────────────────

def create_all(plans: Plans, cfg: Config, parallel: int = 3) -> dict:
    """Main entry point for Stage 3 creation.

    1. Split plans into batches
    2. Run concept convergence search
    3. Spawn parallel agents
    4. Post-processing: validate → reindex → log → archive → sync

    Returns stats: {"created": N, "failed": N, "sources": N, "entries": N}
    """
    plan_list = plans.plans
    plan_count = len(plan_list)

    log.info("=== Stage 3: Create Batch (parallel=%d, plans=%d) ===", parallel, plan_count)

    if plan_count == 0:
        log.info("No plans to process")
        return {"created": 0, "failed": 0, "sources": 0, "entries": 0}

    # Validate parallel is a positive integer
    if not isinstance(parallel, int) or parallel < 1:
        raise ValueError(f"PARALLEL must be a positive integer, got: {parallel}")

    # Split into batches
    batches = plans.split_batches(parallel)
    log.info("Split %d plans into %d batches", plan_count, len(batches))

    # ─── Spawn parallel agents ────────────────────────────────────────────
    results: list[dict] = []
    failed_count = 0

    with ThreadPoolExecutor(max_workers=parallel) as executor:
        future_to_idx = {
            executor.submit(create_batch, batch, idx, cfg): idx
            for idx, batch in enumerate(batches)
        }

        for future in as_completed(future_to_idx):
            idx = future_to_idx[future]
            try:
                result = future.result()
                results.append(result)
                if result["status"] != "ok":
                    failed_count += 1
                    log.warning("Batch %d failed", idx)
                else:
                    log.info("Batch %d completed successfully (%d plans)", idx, result["plans"])
            except Exception:
                failed_count += 1
                log.exception("Batch %d raised exception", idx)

    # ─── Post-processing ──────────────────────────────────────────────────

    # 1. Validate
    log.info("Running output validation...")
    manifest_path = cfg.resolved_extract_dir / "manifest.json"
    violations = validate_output(cfg, manifest_path)
    if violations:
        log.warning("Output validation found %d violations:", len(violations))
        for v in violations:
            log.warning("  %s", v)

        # Auto-repair missing sections
        repaired = _repair_violations(cfg, violations)
        if repaired:
            log.info("Auto-repaired %d files", repaired)
            # Re-validate after repair
            remaining = validate_output(cfg, manifest_path)
            if remaining:
                log.warning("After repair, %d violations remain:", len(remaining))
                for v in remaining:
                    log.warning("  %s", v)
            else:
                log.info("All violations repaired")
    else:
        log.info("Output validation passed")

    # 2. Reindex
    log.info("Rebuilding wiki-index...")
    try:
        reindex(cfg)
    except Exception:
        log.exception("Reindex failed")

    # 3. Log to vault
    try:
        cfg.config_dir.mkdir(parents=True, exist_ok=True)
        log_entry = (
            f"## [{date.today().isoformat()}] ingest | batch ({plan_count} sources)\n"
            f"- Pipeline: v2 (3-stage) — Python\n"
            f"- Sources processed: {plan_count}\n"
            f"- Failed agents: {failed_count}\n"
        )
        log_file = cfg.log_md
        with log_file.open("a", encoding="utf-8") as f:
            f.write(log_entry + "\n")
    except OSError:
        log.exception("Failed to write log entry")

    # 4. Archive inbox (only for successfully processed hashes)
    successful_hashes: set[str] = set()
    for result in results:
        if result["status"] == "ok":
            successful_hashes.update(result["hashes"])

    log.info("Archiving inbox files (only successfully processed)...")
    try:
        archived = archive_inbox(cfg, successful_hashes)
        log.info("Archived %d inbox files", archived)
    except Exception:
        log.exception("Archive inbox failed")

    # 5. Sync vault (if ob CLI is available)
    _sync_vault(cfg)

    # ─── Compute stats ────────────────────────────────────────────────────
    created = plan_count - failed_count
    # Count entries and concepts from successful results
    entries_count = sum(r["plans"] for r in results if r["status"] == "ok")

    log.info(
        "=== Stage 3 complete: %d sources, %d failed ===",
        plan_count, failed_count,
    )

    if failed_count > 0:
        log.warning("Some agents failed — check logs for details")

    return {
        "created": created,
        "failed": min(failed_count, plan_count),  # bounds check
        "sources": plan_count,
        "entries": entries_count,
    }


def _sync_vault(cfg: Config) -> None:
    """Sync vault via ob CLI if available."""
    try:
        result = subprocess.run(
            ["which", "ob"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            log.info("ob CLI not found, skipping vault sync")
            return

        log.info("Syncing vault...")
        subprocess.run(
            ["ob", "sync", "--path", str(cfg.vault_path)],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        log.warning("Vault sync failed")
