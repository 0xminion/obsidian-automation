"""Stage 1 extraction module.

Routes URLs to appropriate extractors and returns ExtractedSource objects.
Uses subprocess + curl for all external calls (Python urllib gets 403).
"""

from __future__ import annotations

import json
import logging
import re
import subprocess
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional
from urllib.parse import quote

from pipeline.config import Config
from pipeline.models import ExtractedSource, Manifest, SourceType

log = logging.getLogger(__name__)

# ─── Constants ────────────────────────────────────────────────────────────────

_YT_PATTERNS = re.compile(
    r"(?:youtube\.com|youtu\.be|youtube-nocookie\.com)"
)
_PODCAST_PATTERNS = re.compile(
    r"(?:podcasts\.apple\.com|open\.spotify\.com/show|"
    r"feeds\.|podbean\.com|anchor\.fm|spotify\.com/episode)"
)
_TWITTER_PATTERNS = re.compile(
    r"(?:x\.com|twitter\.com)/"
)
_ARXIV_PATTERN = re.compile(
    r"arxiv\.org/(?:abs|pdf|html)/\d{4}\.\d{4,5}"
)
_YT_VIDEO_ID_PATTERNS = [
    re.compile(r"[?&]v=([a-zA-Z0-9_-]{11})"),
    re.compile(r"youtu\.be/([a-zA-Z0-9_-]{11})"),
    re.compile(r"shorts/([a-zA-Z0-9_-]{11})"),
    re.compile(r"embed/([a-zA-Z0-9_-]{11})"),
]


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


# ─── Title Extraction ────────────────────────────────────────────────────────

def extract_title(content: str) -> str:
    """Extract a title from content text.

    Strategy:
      1. Find first # heading (skip "Original content")
      2. Fallback to first non-empty line (max 120 chars)
    """
    if not content:
        return ""

    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.startswith("# ") and not stripped.lstrip("# ").startswith("Original content"):
            title = stripped.lstrip("# ").strip()
            if len(title) > 5:
                return title[:120]

    # Fallback: first non-empty, non-URL, non-image line
    for line in content.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(("http", "!", "[")):
            continue
        if len(stripped) > 20:
            return stripped[:120]

    # Last resort: first non-empty line
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped:
            return stripped[:120]

    return ""


# ─── URL Helpers ──────────────────────────────────────────────────────────────

def _extract_youtube_video_id(url: str) -> str:
    """Extract 11-char YouTube video ID from URL."""
    for pat in _YT_VIDEO_ID_PATTERNS:
        m = pat.search(url)
        if m:
            return m.group(1)
    # Fallback: find any 11-char alphanumeric sequence
    m = re.search(r"[a-zA-Z0-9_-]{11}", url)
    return m.group(0) if m else ""


def _extract_arxiv_paper_id(url: str) -> str:
    """Extract arxiv paper ID (e.g. 2503.03312) from URL."""
    m = re.search(r"(\d{4}\.\d{4,5})", url)
    return m.group(1) if m else ""


# ─── CLI / API Helpers ───────────────────────────────────────────────────────

def _run(args: list[str], timeout: int = 45, check: bool = False,
         input_data: Optional[str] = None) -> subprocess.CompletedProcess:
    """Run a subprocess with timeout. Returns CompletedProcess."""
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=check,
        input=input_data,
    )


def _curl_get(url: str, headers: Optional[dict] = None, timeout: int = 45) -> str:
    """GET via curl (not Python urllib — urllib gets 403)."""
    args = ["curl", "-sL", "--max-time", str(timeout)]
    if headers:
        for k, v in headers.items():
            args.extend(["-H", f"{k}: {v}"])
    args.append(url)
    result = _run(args, timeout=timeout + 5)
    return result.stdout.strip()


def _curl_post_json(url: str, data: dict, headers: Optional[dict] = None,
                    timeout: int = 45) -> str:
    """POST JSON via curl."""
    args = ["curl", "-sL", "--max-time", str(timeout), "-X", "POST",
            "-H", "Content-Type: application/json"]
    if headers:
        for k, v in headers.items():
            args.extend(["-H", f"{k}: {v}"])
    args.extend(["-d", json.dumps(data)])
    args.append(url)
    result = _run(args, timeout=timeout + 5)
    return result.stdout.strip()


# ─── YouTube Extraction ──────────────────────────────────────────────────────

def _extract_youtube(url: str, cfg: Config) -> ExtractedSource:
    """Extract YouTube video transcript.

    Chain: TranscriptAPI → Supadata → yt-dlp + faster-whisper.
    Falls back to metadata-only on total failure.
    """
    video_id = _extract_youtube_video_id(url)
    timeout = cfg.extract_timeout

    # Fetch metadata from YouTube oEmbed
    title = ""
    author = ""
    meta_json = _curl_get(
        f"https://www.youtube.com/oembed?url={quote(url, safe='')}&format=json",
        timeout=timeout,
    )
    if meta_json:
        try:
            meta = json.loads(meta_json)
            title = meta.get("title", "")
            author = meta.get("author_name", "")
        except (json.JSONDecodeError, KeyError):
            pass

    # Try transcript extraction chain
    transcript = _try_youtube_transcript(url, video_id, cfg)

    if not transcript or len(transcript) < 50:
        log.warning("YouTube transcript extraction failed for %s", video_id)
        content = f"Title: {title}\nAuthor: {author}\nURL: {url}\n\nNote: Full transcript unavailable (extraction failed)."
    else:
        content = transcript

    return ExtractedSource(
        url=url,
        title=title or url,
        content=content,
        type=SourceType.YOUTUBE,
        author=author,
    )


def _try_youtube_transcript(url: str, video_id: str, cfg: Config) -> str:
    """Try TranscriptAPI → Supadata → Whisper fallback chain."""
    timeout = cfg.extract_timeout

    # 1) TranscriptAPI (primary) — MUST pass full URL
    if cfg.transcript_api_key:
        try:
            api_url = (
                f"https://transcriptapi.com/api/v2/youtube/transcript"
                f"?video_url={quote(url, safe='')}&format=text&include_timestamp=true&send_metadata=true"
            )
            resp = _curl_get(
                api_url,
                headers={"Authorization": f"Bearer {cfg.transcript_api_key}"},
                timeout=timeout,
            )
            if resp and len(resp) > 50:
                # Try to parse as JSON and extract transcript field
                try:
                    data = json.loads(resp)
                    return data.get("transcript", data.get("content", resp))
                except json.JSONDecodeError:
                    return resp
        except (subprocess.TimeoutExpired, Exception) as e:
            log.debug("TranscriptAPI failed: %s", e)

    # 2) Supadata (fallback)
    if cfg.supadata_api_key:
        try:
            resp = _curl_post_json(
                "https://api.supadata.ai/v1/youtube/transcript",
                data={"video_url": f"https://www.youtube.com/watch?v={video_id}",
                      "format": "text"},
                headers={"x-api-key": cfg.supadata_api_key},
                timeout=timeout,
            )
            if resp and len(resp) > 50:
                try:
                    data = json.loads(resp)
                    return data.get("transcript", data.get("content", resp))
                except json.JSONDecodeError:
                    return resp
        except (subprocess.TimeoutExpired, Exception) as e:
            log.debug("Supadata failed: %s", e)

    # 3) yt-dlp + faster-whisper (last resort)
    try:
        import tempfile, os
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            tmp_audio = f.name

        try:
            dl = _run(
                ["yt-dlp", "-x", "--audio-format", "mp3",
                 "--max-filesize", "200M", "-o", tmp_audio, url],
                timeout=120,
            )
            if dl.returncode != 0 or not os.path.exists(tmp_audio):
                return ""

            from faster_whisper import WhisperModel
            model = WhisperModel("base", device="cpu", compute_type="int8")
            segments, _info = model.transcribe(tmp_audio, language="en")
            text = " ".join(s.text for s in segments)
            return text if len(text) > 50 else ""
        finally:
            if os.path.exists(tmp_audio):
                os.unlink(tmp_audio)
    except (ImportError, subprocess.TimeoutExpired, Exception) as e:
        log.debug("Whisper fallback failed: %s", e)
        return ""


# ─── Podcast Extraction ──────────────────────────────────────────────────────

def _extract_podcast(url: str, cfg: Config) -> ExtractedSource:
    """Extract podcast episode via iTunes lookup → RSS → transcription.

    Chain: iTunes Lookup API → RSS parse → yt-dlp download → AssemblyAI transcribe.
    Falls back to RSS description if transcription unavailable.
    """
    timeout = cfg.extract_timeout

    # Step 1: iTunes Lookup for RSS feed URL
    feed_url = ""
    podcast_name = ""
    episode_id = ""

    # Extract IDs from Apple Podcasts URL
    id_match = re.search(r"id(\d+)", url)
    ep_match = re.search(r"[?&]i=(\d+)", url)
    podcast_id = id_match.group(1) if id_match else ""
    episode_id = ep_match.group(1) if ep_match else ""

    if podcast_id:
        lookup_json = _curl_get(
            f"https://itunes.apple.com/lookup?id={podcast_id}&entity=podcast",
            timeout=timeout,
        )
        if lookup_json:
            try:
                lookup = json.loads(lookup_json)
                if lookup.get("results"):
                    feed_url = lookup["results"][0].get("feedUrl", "")
                    podcast_name = lookup["results"][0].get("collectionName", "")
            except (json.JSONDecodeError, KeyError, IndexError):
                pass

    # Step 2: Parse RSS feed
    audio_url = ""
    description = ""
    episode_title = ""

    if feed_url:
        try:
            audio_url, description, episode_title = _parse_rss_episode(
                feed_url, episode_id, timeout
            )
        except Exception as e:
            log.debug("RSS parse failed: %s", e)

    # Step 3: Transcribe audio
    transcript = ""
    if audio_url:
        try:
            transcript = _transcribe_podcast_audio(audio_url, cfg)
        except Exception as e:
            log.debug("Podcast transcription failed: %s", e)

    # Step 4: Assemble content
    if transcript and len(transcript) > 100:
        content = (f"Podcast: {podcast_name}\nEpisode: {episode_title}\nURL: {url}\n\n"
                   f"## Transcript\n\n{transcript}")
    elif description and len(description) > 100:
        content = (f"Podcast: {podcast_name}\nEpisode: {episode_title}\nURL: {url}\n\n"
                   f"## Description\n\n{description}\n\nNote: Audio transcription unavailable. "
                   f"Description extracted from RSS feed.")
    else:
        content = (f"Podcast: {podcast_name}\nEpisode: {episode_title}\nURL: {url}\n\n"
                   f"Note: Could not extract transcript or description. "
                   f"Audio URL: {audio_url or 'unavailable'}")

    return ExtractedSource(
        url=url,
        title=episode_title or podcast_name or url,
        content=content,
        type=SourceType.PODCAST,
        author=podcast_name,
    )


def _parse_rss_episode(feed_url: str, episode_id: str,
                       timeout: int = 30) -> tuple[str, str, str]:
    """Parse RSS feed to find episode audio URL, description, and title.

    Returns (audio_url, description, episode_title).
    """
    rss_xml = _curl_get(feed_url, timeout=timeout)
    if not rss_xml:
        return "", "", ""

    try:
        root = ET.fromstring(rss_xml)
    except ET.ParseError:
        return "", "", ""

    itunes_ns = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"
    items = list(root.iter("item"))

    target_item = None

    # Try to match by episode ID
    if episode_id:
        for item in items:
            guid = item.find("guid")
            link = item.find("link")
            guid_text = guid.text if guid is not None else ""
            link_text = link.text if link is not None else ""
            if (guid_text and episode_id in guid_text) or \
               (link_text and episode_id in link_text):
                target_item = item
                break

    # Fallback to latest episode
    if target_item is None and items:
        target_item = items[0]

    if target_item is None:
        return "", "", ""

    enclosure = target_item.find("enclosure")
    audio_url = enclosure.get("url", "") if enclosure is not None else ""

    desc_elem = target_item.find("description")
    description = (desc_elem.text or "")[:5000] if desc_elem is not None else ""

    title_elem = target_item.find("title")
    episode_title = (title_elem.text or "") if title_elem is not None else ""

    return audio_url, description, episode_title


def _transcribe_podcast_audio(audio_url: str, cfg: Config) -> str:
    """Download podcast audio and transcribe with AssemblyAI.

    Falls back to local whisper if AssemblyAI fails.
    """
    import tempfile, os

    timeout = cfg.extract_timeout

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        tmp_audio = f.name

    try:
        # Download audio
        dl = _run(
            ["yt-dlp", "-x", "--audio-format", "mp3", "-o", tmp_audio, audio_url],
            timeout=120,
        )
        if dl.returncode != 0 or not os.path.exists(tmp_audio):
            return ""

        # Try AssemblyAI first
        if cfg.assemblyai_api_key:
            transcript = _transcribe_assemblyai(tmp_audio, cfg)
            if transcript:
                return transcript

        # Fallback to local whisper
        try:
            from faster_whisper import WhisperModel
            model = WhisperModel("base", device="cpu", compute_type="int8")
            segments, _info = model.transcribe(tmp_audio, language="en")
            return " ".join(s.text for s in segments)
        except ImportError:
            return ""

    finally:
        if os.path.exists(tmp_audio):
            os.unlink(tmp_audio)


def _transcribe_assemblyai(audio_file: str, cfg: Config) -> str:
    """Upload audio to AssemblyAI and poll for transcription result."""
    timeout = cfg.extract_timeout
    api_key = cfg.assemblyai_api_key
    api_url = "https://api.assemblyai.com"

    # Step 1: Upload
    upload_result = _run(
        ["curl", "-s", "-X", "POST", f"{api_url}/v2/upload",
         "-H", f"Authorization: Bearer {api_key}",
         "-H", "Content-Type: application/octet-stream",
         "--data-binary", f"@{audio_file}",
         "--max-time", str(min(timeout, 300))],
        timeout=timeout + 10,
    )
    if upload_result.returncode != 0:
        return ""
    try:
        upload_url = json.loads(upload_result.stdout).get("upload_url", "")
    except (json.JSONDecodeError, AttributeError):
        return ""
    if not upload_url:
        return ""

    # Step 2: Submit transcript request
    submit_data = json.dumps({
        "audio_url": upload_url,
        "speech_models": ["universal-2"],
        "punctuate": True,
        "format_text": True,
    })
    submit_result = _run(
        ["curl", "-s", "-X", "POST", f"{api_url}/v2/transcript",
         "-H", f"Authorization: Bearer {api_key}",
         "-H", "Content-Type: application/json",
         "-d", submit_data,
         "--max-time", "30"],
        timeout=35,
    )
    if submit_result.returncode != 0:
        return ""
    try:
        transcript_id = json.loads(submit_result.stdout).get("id", "")
    except (json.JSONDecodeError, AttributeError):
        return ""
    if not transcript_id:
        return ""

    # Step 3: Poll until complete
    import time
    for _ in range(120):  # max 10 minutes
        poll_result = _run(
            ["curl", "-s", f"{api_url}/v2/transcript/{transcript_id}",
             "-H", f"Authorization: Bearer {api_key}",
             "--max-time", "10"],
            timeout=15,
        )
        if poll_result.returncode != 0:
            return ""
        try:
            poll_data = json.loads(poll_result.stdout)
        except json.JSONDecodeError:
            return ""

        status = poll_data.get("status", "")
        if status == "completed":
            return poll_data.get("text", "")
        elif status == "error":
            return ""
        else:
            time.sleep(5)

    return ""


# ─── Web Extraction ──────────────────────────────────────────────────────────

def _extract_web(url: str, cfg: Config) -> ExtractedSource:
    """Extract web content via defuddle CLI with curl fallback.

    Handles arxiv URLs specially (alphaxiv.org fallback).
    """
    timeout = cfg.extract_timeout
    content = _extract_web_content(url, timeout)

    if not content or len(content) < 50:
        log.warning("Web extraction failed for %s", url)
        content = f"URL: {url}\n\nNote: Content extraction failed."

    title = extract_title(content)

    return ExtractedSource(
        url=url,
        title=title or url,
        content=content,
        type=SourceType.WEB,
    )


def _extract_web_content(url: str, timeout: int = 45) -> str:
    """Extract web content. Tries defuddle → curl fallback.

    Handles arxiv specially via alphaxiv.org.
    """
    # Arxiv special handling
    if _ARXIV_PATTERN.search(url):
        paper_id = _extract_arxiv_paper_id(url)
        if paper_id:
            # Try arxiv HTML first
            html_url = f"https://arxiv.org/html/{paper_id}v1"
            content = _try_defuddle(html_url, timeout)
            if content and len(content) > 500:
                return content

            # Try alphaxiv full text
            content = _curl_get(
                f"https://www.alphaxiv.org/abs/{paper_id}.md",
                timeout=timeout,
            )
            if content and len(content) > 500:
                return content

            # Try alphaxiv overview
            content = _curl_get(
                f"https://www.alphaxiv.org/overview/{paper_id}.md",
                timeout=timeout,
            )
            if content and len(content) > 200 and "No intermediate report" not in content:
                return content

    # Standard defuddle extraction
    content = _try_defuddle(url, timeout)
    if content and len(content) > 200:
        return content

    # Fallback: curl + liteparse
    content = _try_curl_extract(url, timeout)
    if content and len(content) > 200:
        return content

    # Last resort: defuddle --json
    content = _try_defuddle_json(url, timeout)
    if content and len(content) > 200:
        return content

    return ""


def _try_defuddle(url: str, timeout: int = 45) -> str:
    """Try defuddle parse --markdown URL -o tmpfile."""
    import tempfile, os
    try:
        with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as f:
            tmpfile = f.name
        try:
            result = _run(
                ["defuddle", "parse", "--markdown", url, "-o", tmpfile],
                timeout=timeout,
            )
            if result.returncode == 0 and os.path.exists(tmpfile) and os.path.getsize(tmpfile) > 0:
                return Path(tmpfile).read_text(encoding="utf-8", errors="replace")
        finally:
            if os.path.exists(tmpfile):
                os.unlink(tmpfile)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return ""


def _try_defuddle_json(url: str, timeout: int = 45) -> str:
    """Try defuddle parse --json URL."""
    try:
        result = _run(
            ["defuddle", "parse", "--json", url],
            timeout=timeout,
        )
        if result.returncode == 0 and result.stdout:
            data = json.loads(result.stdout)
            content = data.get("content", "")
            if content and len(content) > 200:
                return content
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
        pass
    return ""


def _try_curl_extract(url: str, timeout: int = 45) -> str:
    """Try liteparse: curl download → liteparse parse --format text."""
    import tempfile, os
    try:
        with tempfile.NamedTemporaryFile(suffix=".html", delete=False) as f:
            tmpfile = f.name
        try:
            dl = _run(
                ["curl", "-sL", "--max-time", str(timeout),
                 "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                 url, "-o", tmpfile],
                timeout=timeout + 5,
            )
            if dl.returncode == 0 and os.path.exists(tmpfile) and os.path.getsize(tmpfile) > 0:
                parse = _run(
                    ["liteparse", "parse", "--format", "text", tmpfile],
                    timeout=timeout,
                )
                if parse.returncode == 0 and parse.stdout:
                    return parse.stdout[:5000]
        finally:
            if os.path.exists(tmpfile):
                os.unlink(tmpfile)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return ""


# ─── Main Entry Points ───────────────────────────────────────────────────────

def extract_url(url: str, cfg: Config) -> ExtractedSource:
    """Extract a single URL. Routes to appropriate extractor based on type.

    Returns ExtractedSource and saves JSON to cfg.resolved_extract_dir / {hash}.json.
    """
    source_type = detect_source_type(url)

    try:
        if source_type == SourceType.YOUTUBE:
            source = _extract_youtube(url, cfg)
        elif source_type == SourceType.PODCAST:
            source = _extract_podcast(url, cfg)
        else:
            source = _extract_web(url, cfg)
    except Exception as e:
        log.error("Extraction failed for %s: %s", url, e)
        source = ExtractedSource(
            url=url,
            title=url,
            content=f"URL: {url}\n\nNote: Extraction failed with error: {e}",
            type=source_type,
        )

    # Save extracted JSON
    source.save(cfg.resolved_extract_dir)
    return source


def extract_all(urls: list[str], cfg: Config, parallel: int = 4) -> Manifest:
    """Extract multiple URLs in parallel.

    Returns Manifest with all successful extractions.
    """
    manifest = Manifest()
    if not urls:
        return manifest

    def _extract_one(url: str) -> Optional[ExtractedSource]:
        try:
            return extract_url(url, cfg)
        except Exception as e:
            log.error("Failed to extract %s: %s", url, e)
            return None

    with ThreadPoolExecutor(max_workers=parallel) as executor:
        futures = {executor.submit(_extract_one, url): url for url in urls}
        for future in as_completed(futures):
            result = future.result()
            if result:
                manifest.entries.append(result)

    # Save manifest
    manifest.save(cfg.resolved_extract_dir)
    return manifest
