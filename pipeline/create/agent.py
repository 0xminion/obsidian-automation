"""Agent orchestration — subprocess execution, concept convergence, batch creation."""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from pathlib import Path

from pipeline.config import Config
from pipeline.models import Plan
from pipeline.utils import strip_qmd_noise
from pipeline.create.prompts import build_batch_prompt

log = logging.getLogger(__name__)


def _run_agent(prompt: str, cfg: Config, timeout: int = 900) -> str:
    """Run the agent command with the given prompt.

    Uses: hermes chat -q "prompt" -Q
    Handles timeout (exit 124) gracefully — files created before timeout
    are still valid.
    """
    agent_cmd = os.environ.get("AGENT_CMD", cfg.agent_cmd)
    try:
        # Save prompt to temp file to avoid shell escaping issues
        prompt_file = cfg.resolved_extract_dir / "_agent_prompt.md"
        prompt_file.parent.mkdir(parents=True, exist_ok=True)
        prompt_file.write_text(prompt, encoding="utf-8")

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


def concept_convergence(plans: list[Plan], cfg: Config) -> dict[str, list[dict]]:
    """Search existing concepts via qmd for each plan.

    Returns hash -> list of {concept, score} mappings.
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
            proc = subprocess.run(
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

            stdout_clean = strip_qmd_noise(proc.stdout)

            if proc.returncode == 0 and stdout_clean.strip().startswith("["):
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
        except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError, OSError) as e:
            log.debug("Concept search failed for %s: %s", plan.hash, e)
            convergence[h] = []

    return convergence


def create_batch(batch: list[Plan], batch_idx: int, cfg: Config) -> dict:
    """Create vault files for a single batch of plans.

    1. Build batch prompt (with concept convergence data)
    2. Call hermes agent (with retry on failure)
    3. Validate output was created
    4. Return result dict with status and plan hashes
    """
    from pipeline.vault import title_to_filename

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
            filename = title_to_filename(plan.title)
            entry_file = cfg.entries_dir / f"{filename}.md"
            source_file = cfg.sources_dir / f"{filename}.md"
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
