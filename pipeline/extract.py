"""Stage 1 extraction module.

Routes URLs to type-specific extractors and returns ExtractedSource objects.
Each extractor lives in pipeline/extractors/<type>.py with a common interface.

Shared utilities are in pipeline/extractors/_shared.py.
Uses subprocess + curl for all external calls (Python urllib gets 403).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional

from pipeline.config import Config
from pipeline.models import ExtractedSource, Manifest, SourceType

# ─── Re-exports for backward compatibility (tests patch these names) ──────────
from pipeline.extractors._shared import (  # noqa: F401
    _run,
    _curl_get,
    _curl_post_json,
    _strip_markdown,
    extract_title,
    _extract_youtube_video_id,
    _extract_arxiv_paper_id,
    _is_challenge_page,
    validate_extraction as _validate_extraction,
    _YT_PATTERNS,
    _PODCAST_PATTERNS,
    _TWITTER_PATTERNS,
    _ARXIV_PATTERN,
    _YT_VIDEO_ID_PATTERNS,
    _CHALLENGE_PATTERNS,
    transcribe_with_whisper,
    transcribe_assemblyai,
)

# ─── Re-exports from extractor modules (tests patch these) ────────────────────
from pipeline.extractors.youtube import (  # noqa: F401
    extract_youtube as _extract_youtube,
    _try_youtube_transcript,
)
from pipeline.extractors.podcast import (  # noqa: F401
    extract_podcast as _extract_podcast,
    _episode_title_match,
    _parse_rss_episode,
    _transcribe_podcast_audio,
)
from pipeline.extractors.web import (  # noqa: F401
    extract_web as _extract_web,
    _extract_web_content,
    _try_defuddle,
    _try_defuddle_json,
    _try_curl_extract,
    _try_archive_extract,
)

log = logging.getLogger(__name__)


# ─── Source Type Detection ────────────────────────────────────────────────────

def detect_source_type(url: str) -> SourceType:
    """Detect source type from URL patterns."""
    if _YT_PATTERNS.search(url):
        return SourceType.YOUTUBE
    if _PODCAST_PATTERNS.search(url):
        return SourceType.PODCAST
    if _TWITTER_PATTERNS.search(url):
        return SourceType.TWITTER
    return SourceType.WEB


# ─── Content Index (Recommendation 5: URL + Content Dedup) ───────────────────

class ContentIndex:
    """Persistent index of processed URLs and content hashes.

    Prevents re-extraction of already-processed content and detects
    cross-source duplicates (same content, different URLs).

    Stored as JSON at extract_dir/content_index.json.
    Isolated per vault via PIPELINE_TMPDIR or per-vault extract dirs.
    """

    def __init__(self, index_path: Path):
        self.index_path = index_path
        self._url_index: dict[str, str] = {}      # url_hash -> url
        self._content_index: dict[str, str] = {}   # content_hash -> vault filename
        self._lock = threading.Lock()
        self._load()

    def _load(self) -> None:
        if self.index_path.exists():
            try:
                data = json.loads(self.index_path.read_text())
                self._url_index = data.get("urls", {})
                self._content_index = data.get("content", {})
                log.info("Loaded content index: %d URLs, %d content hashes",
                         len(self._url_index), len(self._content_index))
            except (json.JSONDecodeError, Exception) as e:
                log.warning("Failed to load content index: %s", e)
                self._url_index = {}
                self._content_index = {}

    def _save(self) -> None:
        self.index_path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "urls": self._url_index,
            "content": self._content_index,
        }
        self.index_path.write_text(json.dumps(data, ensure_ascii=False, indent=2))

    @staticmethod
    def _normalize_url(url: str) -> str:
        """Normalize URL for dedup comparison.

        Strips tracking params, trailing slashes, and lowercases.
        """
        from urllib.parse import urlparse, parse_qs, urlencode, urlunparse
        parsed = urlparse(url)
        # Strip common tracking params
        skip_params = {"utm_source", "utm_medium", "utm_campaign", "utm_content",
                       "utm_term", "ref", "source", "fbclid", "gclid"}
        params = parse_qs(parsed.query)
        filtered = {k: v for k, v in params.items() if k.lower() not in skip_params}
        clean_query = urlencode(filtered, doseq=True)
        # Lowercase scheme + host, strip trailing slash
        normalized = urlunparse((
            parsed.scheme.lower(),
            parsed.netloc.lower(),
            parsed.path.rstrip("/") or "/",
            parsed.params,
            clean_query,
            "",  # fragment
        ))
        return normalized

    @staticmethod
    def _url_hash(url: str) -> str:
        return hashlib.md5(ContentIndex._normalize_url(url).encode()).hexdigest()[:12]

    @staticmethod
    def _content_hash(content: str) -> str:
        normalized = re.sub(r"\s+", " ", content.lower().strip())[:2000]
        return hashlib.md5(normalized.encode()).hexdigest()[:16]

    def is_url_processed(self, url: str) -> bool:
        with self._lock:
            return self._url_hash(url) in self._url_index

    def is_content_duplicate(self, content: str) -> bool:
        with self._lock:
            return self._content_hash(content) in self._content_index

    def get_content_duplicate(self, content: str) -> str:
        """Return vault filename of duplicate content, or empty string."""
        with self._lock:
            return self._content_index.get(self._content_hash(content), "")

    def register(self, url: str, content_hash: str, vault_filename: str = "") -> None:
        """Register a processed URL and its content hash."""
        with self._lock:
            self._url_index[self._url_hash(url)] = url
            if content_hash:
                self._content_index[content_hash] = vault_filename
            self._save()

    @classmethod
    def load_or_create(cls, extract_dir: Path) -> ContentIndex:
        index_path = extract_dir / "content_index.json"
        return cls(index_path)


# ─── Main Entry Points ───────────────────────────────────────────────────────

def extract_url(url: str, cfg: Config,
                content_index: Optional[ContentIndex] = None) -> ExtractedSource:
    """Extract a single URL with retry logic, quality validation, and dedup.

    Routes to appropriate extractor based on type.
    Retries on transient failures (network errors, timeouts).
    Returns ExtractedSource and saves JSON to cfg.resolved_extract_dir / {hash}.json.
    """
    # URL-level dedup: skip if already processed
    if content_index and content_index.is_url_processed(url):
        log.info("Dedup: skipping already-processed URL %s", url[:80])
        return ExtractedSource(
            url=url,
            title="[dedup: already processed]",
            content="",
            type=detect_source_type(url),
        )

    source_type = detect_source_type(url)
    max_retries = cfg.max_retries
    last_error = ""

    for attempt in range(max_retries):
        try:
            if source_type == SourceType.YOUTUBE:
                source = _extract_youtube(url, cfg)
            elif source_type == SourceType.PODCAST:
                source = _extract_podcast(url, cfg)
            else:
                source = _extract_web(url, cfg, source_type=source_type)

            # Validate extraction quality
            is_valid, reason = _validate_extraction(source.content)
            if not is_valid:
                last_error = reason
                log.warning("Extraction quality check failed (attempt %d/%d) for %s: %s",
                            attempt + 1, max_retries, url, reason)
                if attempt < max_retries - 1:
                    wait_time = 2 ** attempt
                    log.info("Retrying in %ds...", wait_time)
                    time.sleep(wait_time)
                continue

            # Content-level dedup: check if extracted content already exists
            if content_index:
                chash = source.content_hash
                if content_index.is_content_duplicate(source.content):
                    dup_name = content_index.get_content_duplicate(source.content)
                    log.info("Dedup: content matches existing source '%s' — skipping %s",
                             dup_name, url[:80])
                    return ExtractedSource(
                        url=url,
                        title=f"[dedup: matches {dup_name}]",
                        content="",
                        type=source_type,
                    )
                content_index.register(url, chash)

            source.save(cfg.resolved_extract_dir)
            return source

        except Exception as e:
            last_error = str(e)
            log.error("Extraction failed (attempt %d/%d) for %s: %s",
                      attempt + 1, max_retries, url, e)
            if attempt < max_retries - 1:
                time.sleep(2 ** attempt)

    # All retries exhausted — create a minimal source
    log.error("All %d extraction attempts failed for %s: %s", max_retries, url, last_error)
    source = ExtractedSource(
        url=url,
        title=url,
        content=f"URL: {url}\\n\\nNote: Extraction failed after {max_retries} attempts. Last error: {last_error}",
        type=source_type,
    )
    source.save(cfg.resolved_extract_dir)
    return source


def extract_all(urls: list[str], cfg: Config, parallel: int = 4) -> Manifest:
    """Extract multiple URLs in parallel with quality validation and dedup.

    Invalid extractions (empty, Cloudflare, too short, duplicates) are excluded.
    """
    manifest = Manifest()
    if not urls:
        return manifest

    # Load or create content index for dedup
    content_index = ContentIndex.load_or_create(cfg.resolved_extract_dir)

    def _extract_one(url: str) -> Optional[ExtractedSource]:
        try:
            source = extract_url(url, cfg, content_index=content_index)
            # Skip dedup stubs (empty content, title starts with [dedup:)
            if not source.content or source.title.startswith("[dedup:"):
                return None
            return source
        except Exception as e:
            log.error("Failed to extract %s: %s", url, e)
            return None

    with ThreadPoolExecutor(max_workers=parallel) as executor:
        futures = {executor.submit(_extract_one, url): url for url in urls}
        for future in as_completed(futures):
            result = future.result()
            if result:
                is_valid, reason = _validate_extraction(result.content)
                if is_valid:
                    manifest.entries.append(result)
                else:
                    url = futures[future]
                    log.warning("Skipping invalid extraction for %s: %s", url, reason)

    # Save manifest
    manifest.save(cfg.resolved_extract_dir)
    return manifest
