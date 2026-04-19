"""Vault stats module — dashboard metrics for the wiki.

Generates a health/growth dashboard at 06-Config/dashboard.md.
Consolidates vault-stats.sh into Python.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from pipeline.config import Config


def _count_md(directory: Path) -> int:
    """Count .md files in a directory."""
    if not directory.exists():
        return 0
    return len(list(directory.glob("*.md")))


def _extract_frontmatter_field(content: str, field: str) -> str:
    """Extract a single field value from YAML frontmatter."""
    import re
    match = re.search(rf"^{field}:\s*[\"']?(.*?)[\"']?\s*$", content, re.MULTILINE)
    return match.group(1).strip() if match else ""


def generate_dashboard(cfg: Config) -> str:
    """Generate the dashboard markdown content."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [f"# Wiki Dashboard — {today}", ""]

    # ─── Vault Size ────────────────────────────────────────────────────────────
    entries = _count_md(cfg.entries_dir)
    concepts = _count_md(cfg.concepts_dir)
    mocs = _count_md(cfg.mocs_dir)
    sources = _count_md(cfg.sources_dir)
    total = entries + concepts + mocs + sources

    lines.extend([
        "## Vault Size",
        "",
        "| Type | Count |",
        "|------|-------|",
        f"| Entries | {entries} |",
        f"| Concepts | {concepts} |",
        f"| MoCs | {mocs} |",
        f"| Sources | {sources} |",
        f"| **Total** | **{total}** |",
        "",
    ])

    # ─── Growth (last 7 days) ──────────────────────────────────────────────────
    cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d")
    recent_entries = 0
    if cfg.entries_dir.exists():
        for md in cfg.entries_dir.glob("*.md"):
            content = md.read_text(encoding="utf-8", errors="replace")
            entry_date = _extract_frontmatter_field(content, "date_entry")
            if entry_date and entry_date > cutoff:
                recent_entries += 1

    lines.extend([
        "## Growth (last 7 days)",
        "",
        f"- New entries (7d): {recent_entries}",
        "",
    ])

    # ─── Review Status ─────────────────────────────────────────────────────────
    reviewed_count = 0
    unreviewed_count = 0
    if cfg.entries_dir.exists():
        for md in cfg.entries_dir.glob("*.md"):
            content = md.read_text(encoding="utf-8", errors="replace")
            reviewed = _extract_frontmatter_field(content, "reviewed")
            if not reviewed or reviewed in ("", "null", "None"):
                unreviewed_count += 1
            else:
                reviewed_count += 1

    lines.extend([
        "## Review Status",
        "",
        "| Status | Count |",
        "|--------|-------|",
        f"| Reviewed | {reviewed_count} |",
        f"| Unreviewed | {unreviewed_count} |",
        "",
    ])

    # ─── Health Indicators ─────────────────────────────────────────────────────
    # Orphan check (quick)
    orphan_count = 0
    if cfg.entries_dir.exists():
        for md in cfg.entries_dir.glob("*.md"):
            name = md.stem
            # Check if any other file references this entry
            referenced = False
            for other_dir in (cfg.entries_dir, cfg.concepts_dir, cfg.mocs_dir, cfg.sources_dir):
                if not other_dir.exists():
                    continue
                for other_md in other_dir.glob("*.md"):
                    if other_md == md:
                        continue
                    other_content = other_md.read_text(encoding="utf-8", errors="replace")
                    if f"[[{name}]]" in other_content:
                        referenced = True
                        break
                if referenced:
                    break
            if not referenced:
                orphan_count += 1

    # Edges count
    edge_count = 0
    if cfg.edges_file.exists():
        content = cfg.edges_file.read_text(encoding="utf-8", errors="replace").strip()
        edge_count = max(0, len(content.split("\n")) - 1)

    # Last ingest
    log_file = cfg.config_dir / "log.md"
    last_ingest = "never"
    if log_file.exists():
        import re
        log_content = log_file.read_text(encoding="utf-8", errors="replace")
        matches = re.findall(r"^## \[.*?\] ingest", log_content, re.MULTILINE)
        if matches:
            last_ingest = matches[-1]

    # URL index size
    url_index_size = 0
    if cfg.url_index.exists():
        url_index_size = len(cfg.url_index.read_text(encoding="utf-8", errors="replace").strip().split("\n"))

    lines.extend([
        "## Health",
        "",
        "| Indicator | Status |",
        "|-----------|--------|",
        f"| Orphaned entries | {orphan_count} |",
        f"| Typed edges | {edge_count} |",
        f"| Last ingest | {last_ingest} |",
        f"| URL index size | {url_index_size} entries |",
        "",
    ])

    # ─── Recent Activity ───────────────────────────────────────────────────────
    lines.extend(["## Recent Activity", ""])
    if log_file.exists():
        log_content = log_file.read_text(encoding="utf-8", errors="replace")
        import re
        recent = re.findall(r"^## \[.*?\].*", log_content, re.MULTILINE)
        lines.append("```")
        lines.extend(recent[-5:] if recent else ["(no activity)"])
        lines.append("```")
    else:
        lines.append("(no log.md found)")
    lines.append("")
    lines.append(f"*Generated by pipeline stats on {today}*")
    lines.append("")

    return "\n".join(lines)


def run_stats(cfg: Config) -> dict:
    """Generate and write dashboard. Returns summary dict."""
    content = generate_dashboard(cfg)
    dashboard_path = cfg.config_dir / "dashboard.md"
    cfg.config_dir.mkdir(parents=True, exist_ok=True)
    dashboard_path.write_text(content, encoding="utf-8")

    # Parse counts for return
    entries = _count_md(cfg.entries_dir)
    concepts = _count_md(cfg.concepts_dir)
    mocs = _count_md(cfg.mocs_dir)
    sources = _count_md(cfg.sources_dir)
    total = entries + concepts + mocs + sources

    return {
        "total": total,
        "entries": entries,
        "concepts": concepts,
        "mocs": mocs,
        "sources": sources,
        "dashboard_path": str(dashboard_path),
    }
