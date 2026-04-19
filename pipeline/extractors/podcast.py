"""Podcast episode extraction.

Chain: iTunes lookup → iTunes search → RSS parse → transcription.
Handles Apple Podcasts store ID ≠ iTunes API ID mismatch.
Falls back to RSS description if transcription unavailable.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from typing import Optional
from urllib.parse import quote

from pipeline.config import Config
from pipeline.models import ExtractedSource, SourceType
from pipeline.extractors._shared import (
    _curl_get,
    _run,
    transcribe_with_whisper,
    transcribe_assemblyai,
)

log = logging.getLogger(__name__)


def extract_podcast(url: str, cfg: Config) -> ExtractedSource:
    """Extract podcast episode via iTunes lookup → RSS → transcription.

    Chain: iTunes Lookup API → iTunes Search → RSS parse → yt-dlp → AssemblyAI.
    Handles Apple Podcasts store ID ≠ iTunes API ID mismatch.
    Falls back to RSS description if transcription unavailable.
    """
    timeout = cfg.extract_timeout

    # Step 1: Find podcast RSS feed URL
    feed_url = ""
    podcast_name = ""
    episode_id = ""

    # Extract IDs from Apple Podcasts URL
    id_match = re.search(r"id(\d+)", url)
    ep_match = re.search(r"[?&]i=(\d+)", url)
    podcast_id = id_match.group(1) if id_match else ""
    episode_id = ep_match.group(1) if ep_match else ""

    # Extract episode slug for title matching: /podcast/NAME/id123?i=EPID
    episode_slug = ""
    description = ""
    slug_match = re.search(r"/podcast/([^/]+)/id\d+", url)
    if slug_match:
        episode_slug = slug_match.group(1).replace("-", " ").strip()

    # Strategy 1: iTunes lookup (works when store ID maps to API collection ID)
    if podcast_id:
        lookup_json = _curl_get(
            f"https://itunes.apple.com/lookup?id={podcast_id}&entity=podcast",
            timeout=timeout,
        )
        if lookup_json:
            try:
                lookup = json.loads(lookup_json)
                if lookup.get("resultCount", 0) > 0 and lookup.get("results"):
                    feed_url = lookup["results"][0].get("feedUrl", "")
                    podcast_name = lookup["results"][0].get("collectionName", "")
            except (json.JSONDecodeError, KeyError, IndexError):
                pass

    # Strategy 2: iTunes lookup with entity=podcastEpisode
    if not feed_url and podcast_id:
        lookup_ep_json = _curl_get(
            f"https://itunes.apple.com/lookup?id={podcast_id}&entity=podcastEpisode&limit=50",
            timeout=timeout,
        )
        if lookup_ep_json:
            try:
                lookup_ep = json.loads(lookup_ep_json)
                if lookup_ep.get("resultCount", 0) > 0:
                    for r in lookup_ep.get("results", []):
                        if r.get("feedUrl"):
                            feed_url = r["feedUrl"]
                            podcast_name = r.get("collectionName", podcast_name)
                            break
                    if episode_slug and feed_url:
                        for r in lookup_ep.get("results", []):
                            ep_title = r.get("trackName", "")
                            if ep_title and _episode_title_match(episode_slug, ep_title):
                                if not description:
                                    description = r.get("description", "")
                                if not episode_id:
                                    episode_id = str(r.get("trackId", ""))
                                break
            except (json.JSONDecodeError, KeyError, IndexError):
                pass

    # Strategy 3: iTunes search by podcast name from URL
    if not feed_url:
        search_term = episode_slug if episode_slug else ""
        if not search_term and podcast_id:
            search_term = slug_match.group(1).replace("-", " ") if slug_match else ""
        if search_term:
            search_json = _curl_get(
                f"https://itunes.apple.com/search?term={quote(search_term)}&media=podcast&limit=5",
                timeout=timeout,
            )
            if search_json:
                try:
                    search = json.loads(search_json)
                    if search.get("results"):
                        feed_url = search["results"][0].get("feedUrl", "")
                        podcast_name = search["results"][0].get("collectionName", podcast_name)
                except (json.JSONDecodeError, KeyError, IndexError):
                    pass

    # Step 2: Parse RSS feed
    audio_url = ""
    rss_description = ""
    episode_title = ""

    if feed_url:
        try:
            audio_url, rss_description, episode_title = _parse_rss_episode(
                feed_url, episode_id, episode_slug, timeout
            )
        except Exception as e:
            log.debug("RSS parse failed: %s", e)

    # Use RSS description if we don't have one from iTunes
    if not description:
        description = rss_description

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


def _episode_title_match(slug: str, title: str) -> bool:
    """Check if an episode title matches the URL slug.

    Uses keyword overlap: at least 60% of slug words must appear in the title.
    """
    slug_words = set(re.sub(r"[^a-z0-9 ]", "", slug.lower()).split())
    title_words = set(re.sub(r"[^a-z0-9 ]", "", title.lower()).split())
    slug_words = {w for w in slug_words if len(w) > 2}
    title_words = {w for w in title_words if len(w) > 2}
    if not slug_words:
        return False
    overlap = slug_words & title_words
    return len(overlap) / len(slug_words) >= 0.6


def _parse_rss_episode(feed_url: str, episode_id: str, episode_slug: str = "",
                       timeout: int = 30) -> tuple[str, str, str]:
    """Parse RSS feed to find episode audio URL, description, and title.

    Tries matching in order:
      1. By episode ID in GUID/link
      2. By episode title slug (keyword overlap)
      3. Fallback to latest episode

    Returns (audio_url, description, episode_title).
    """
    rss_xml = _curl_get(feed_url, timeout=timeout)
    if not rss_xml:
        return "", "", ""

    try:
        root = ET.fromstring(rss_xml)
    except ET.ParseError:
        return "", "", ""

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

    # Try to match by episode title slug (keyword overlap)
    if target_item is None and episode_slug:
        best_score = 0.0
        best_item = None
        for item in items:
            title_elem = item.find("title")
            if title_elem is None or not title_elem.text:
                continue
            item_title = title_elem.text
            slug_words = set(re.sub(r"[^a-z0-9 ]", "", episode_slug.lower()).split())
            title_words = set(re.sub(r"[^a-z0-9 ]", "", item_title.lower()).split())
            slug_words = {w for w in slug_words if len(w) > 2}
            title_words = {w for w in title_words if len(w) > 2}
            if not slug_words:
                continue
            overlap = slug_words & title_words
            score = len(overlap) / len(slug_words)
            if score > best_score:
                best_score = score
                best_item = item
        if best_score >= 0.5 and best_item is not None:
            target_item = best_item
            log.info("RSS: matched episode by title (score=%.2f): %s",
                     best_score,
                     (best_item.find("title").text if best_item.find("title") is not None else "?"))

    # Fallback to latest episode
    if target_item is None and items:
        target_item = items[0]
        log.warning("RSS: no episode match found, falling back to latest episode: %s",
                    (target_item.find("title").text if target_item.find("title") is not None else "?"))

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
            transcript = transcribe_assemblyai(tmp_audio, cfg.assemblyai_api_key, timeout)
            if transcript:
                return transcript

        # Fallback to local whisper
        return transcribe_with_whisper(tmp_audio)

    finally:
        if os.path.exists(tmp_audio):
            os.unlink(tmp_audio)
