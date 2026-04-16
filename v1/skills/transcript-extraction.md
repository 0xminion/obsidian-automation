---
name: transcript-extraction
description: Universal transcript extraction for YouTube videos and podcasts with prioritized fallback chains. Always checks for existing transcripts first, then uses API services in order of preference, with local processing as last resort.
version: 2.0.0
author: hermes
created: 2026-04-16
tags: [transcript, youtube, podcast, assemblyai, whisper, supadata, obsidian]
dependencies: [curl, jq, yt-dlp, whisper, assemblyai]
environment_variables: [TRANSCRIPT_API_KEY, SUPADATA_API_KEY, ASSEMBLYAI_API_KEY]
metadata: {"requires":{"bins":["curl","jq","yt-dlp"],"config":["~/.openclaw/openclaw.json"]}}
---

# Universal Transcript Extraction

Unified transcript extraction system for YouTube videos and podcasts with intelligent fallback chains. Always checks for existing content before making API calls.

## Quick Reference

| Content Type | Primary | Fallback | Last Resort |
|--------------|---------|----------|-------------|
| **YouTube**  | TranscriptAPI | Supadata | Local Whisper |
| **Podcast**  | Check existing | AssemblyAI | Manual search |

---

## YouTube Video Extraction

### Step 0: Check for Existing Transcript
Before any API calls, search for existing transcripts:

```bash
# Search Obsidian vault for existing YouTube notes
find ~/MyVault -name "*.md" -exec grep -l "VIDEO_ID\|VIDEO_URL" {} \;

# Check local cache
ls ~/.hermes/cache/transcripts/ | grep VIDEO_ID

# Check if video exists in recent notes
grep -r "youtube.com/watch\|youtu.be" ~/MyVault/04-Wiki/ --include="*.md" -l
```

**If found:** Return existing content, skip to formatting.

### Step 1: TranscriptAPI (Primary)
Use the existing `transcriptapi` skill:

```bash
# Extract transcript
curl -s "https://transcriptapi.com/api/v2/youtube/transcript\
?video_url=VIDEO_URL&format=text&include_timestamp=true&send_metadata=true" \
  -H "Authorization: Bearer $TRANSCRIPT_API_KEY"
```

**Cost:** 1 credit per transcript  
**Rate limit:** 300 req/min  
**Free tier:** 100 credits

### Step 2: Supadata (Fallback)
If TranscriptAPI fails (404, 429, 500, or no captions):

```bash
# Extract via Supadata
curl -s -X POST "https://api.supadata.ai/v1/youtube/transcript" \
  -H "Authorization: Bearer $SUPADATA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"video_id": "VIDEO_ID", "format": "text"}'
```

**Error handling:**
- 404: Video not found or no captions → move to Whisper
- 429: Rate limited → wait, retry once
- 500: Server error → retry once, then move to Whisper

### Step 3: Local Whisper (Last Resort)
When all APIs fail, download audio and transcribe locally:

```bash
# Download audio
yt-dlp -x --audio-format mp3 -o "/tmp/%(id)s.%(ext)s" "VIDEO_URL"

# Transcribe with Whisper
whisper "/tmp/VIDEO_ID.mp3" \
  --model medium \
  --language en \
  --output_format txt \
  --output_dir ~/.hermes/cache/transcripts/

# Clean up
rm "/tmp/VIDEO_ID.mp3"
```

**Time:** 2-10 minutes depending on video length  
**Quality:** High accuracy, supports 90+ languages

---

## Podcast Extraction

### Step 0: Check for Existing Transcript
Search multiple sources for existing transcripts:

```bash
# Search Obsidian vault
find ~/MyVault -name "*.md" -exec grep -l "PODCAST_NAME\|EPISODE_NAME" {} \;

# Check podcast website/show notes (if URL available)
curl -s "PODCAST_WEBSITE/EPISODE_URL" | grep -i "transcript"

# Search RSS feed for transcript links
curl -s "RSS_FEED_URL" | xmllint --xpath '//item[contains(title, "EPISODE")]/link/text()' -

# Check common transcript aggregators
curl -s "https://api.podscribe.ai/v1/episodes?feed=FEED_URL&title=EPISODE_TITLE"
```

**If found:** Parse and return existing transcript.

### Step 1: AssemblyAI (Primary Fallback)
If no existing transcript found:

```bash
# Upload audio file to AssemblyAI
UPLOAD_URL=$(curl -s -X POST "https://api.assemblyai.com/v2/upload" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@PODCAST_AUDIO_FILE.mp3" \
  | jq -r '.upload_url')

# Request transcription
TRANSCRIPT_ID=$(curl -s -X POST "https://api.assemblyai.com/v2/transcript" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"audio_url\": \"$UPLOAD_URL\", \"speaker_labels\": true}" \
  | jq -r '.id')

# Poll for completion
while true; do
  STATUS=$(curl -s "https://api.assemblyai.com/v2/transcript/$TRANSCRIPT_ID" \
    -H "Authorization: $ASSEMBLYAI_API_KEY" \
    | jq -r '.status')
  
  if [ "$STATUS" = "completed" ]; then
    break
  elif [ "$STATUS" = "error" ]; then
    echo "Transcription failed"
    exit 1
  fi
  sleep 5
done

# Get final transcript
curl -s "https://api.assemblyai.com/v2/transcript/$TRANSCRIPT_ID" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  | jq -r '.text'
```

**Features:**
- Speaker identification
- Punctuation and casing
- Paragraph detection
- Confidence scores

---

## Output Formatting

### YouTube Transcript Format
```markdown
# [Video Title]
**Source:** [YouTube URL]
**Extracted:** [Date using: `date -u +"%Y-%m-%dT%H:%M:%SZ"`]
**Method:** [transcriptapi|supadata|whisper|existing]
**Language:** [detected language]
**Duration:** [video length]

## Key Points
[Bullet list of main topics if requested]

## Transcript
[Full transcript text with timestamps if available]

[00:00] First segment text...
[00:15] Second segment text...

---
*Extracted via [method] on [date]*
```

### Podcast Transcript Format
```markdown
# [Podcast Name] - [Episode Title]
**Source:** [Podcast URL/RSS/Website]
**Extracted:** [Date]
**Method:** [existing|assemblyai]
**Episode:** [number if available]
**Duration:** [episode length]
**Speakers:** [identified speakers]

## Key Takeaways
[Bullet list if requested]

## Transcript
[Full transcript with speaker labels]

**[Speaker 1]:** Welcome to today's episode...

**[Speaker 2]:** Thanks for having me...

---
*Extracted via [method] on [date]*
```

---

## Integration with Obsidian Pipeline

### Save Location
- YouTube transcripts: `~/MyVault/04-Wiki/sources/youtube/`
- Podcast transcripts: `~/MyVault/04-Wiki/sources/podcasts/`

### File Naming
```
[YYYY-MM-DD] [Sanitized Title] Transcript.md
```

### YAML Frontmatter
```yaml
---
title: "[Original Title]"
source: "[URL]"
type: [youtube|podcast]
extracted: "[ISO date]"
method: "[extraction method]"
language: "[lang code]"
duration: "[length]"
speakers: [list if podcast]
tags: [transcript, youtube/podcast, topic-tags]
---
```

### Post-Processing
After saving transcript, run the standard Karpathy pipeline:
1. Create Source entry in `04-Wiki/sources/`
2. Generate Entry with ELI5 insights
3. Create/update Concept pages
4. Update relevant MoCs
5. Update `wiki-index` and `edges.tsv`
6. Log to `log.md`

---

## Error Handling & Logging

### API Failure Protocol
1. Log error with timestamp and endpoint
2. Implement exponential backoff (2s, 4s, 8s)
3. Maximum 3 retry attempts per service
4. Fall back to next method in chain
5. Alert user if all methods fail

### Cache Management
```bash
# Cache location
~/.hermes/cache/transcripts/

# Cache structure
├── youtube/
│   └── [VIDEO_ID].json
├── podcasts/
│   └── [PODCAST_HASH].json
└── metadata.json
```

Cache entries expire after 30 days or on explicit refresh.

### Rate Limiting
- TranscriptAPI: 300 req/min (respect Retry-After header)
- Supadata: Check documentation for limits
- AssemblyAI: 5 concurrent transcripts
- Local Whisper: No limits (CPU/GPU bound)

---

## Environment Setup

### Required Variables
```bash
# ~/.bashrc or ~/.zshrc
export TRANSCRIPT_API_KEY="sk_8QgqMvNXEAl2onmXQW-g5lVfMd9dMYoySuT6TuUigw8"
export SUPADATA_API_KEY="your_key_here"  # Add when available
export ASSEMBLYAI_API_KEY="your_key_here"  # Add when available
```

### Dependencies
```bash
# Ubuntu/Debian
sudo apt install jq ffmpeg

# yt-dlp (for Whisper fallback)
pip install yt-dlp

# OpenAI Whisper
pip install openai-whisper

# Verify installations
which curl jq yt-dlp whisper ffmpeg
```

---

## Usage Examples

### Extract YouTube transcript
```bash
# Via CLI
hermes transcript "https://youtube.com/watch?v=VIDEO_ID"

# Or direct script call
./scripts/extract-transcript.sh youtube "https://youtube.com/watch?v=VIDEO_ID"
```

### Extract podcast transcript
```bash
# With audio file
hermes transcript podcast "path/to/episode.mp3" --name "Podcast Name" --episode "Episode Title"

# With RSS feed
hermes transcript podcast --rss "https://feeds.example.com/podcast" --episode "123"
```

### Bulk extraction
```bash
# Process list of URLs
cat urls.txt | while read url; do
  hermes transcript "$url"
  sleep 2  # Respect rate limits
done
```

---

## Tips & Best Practices

1. **Always check cache first** — API calls cost money/time
2. **Use timestamps when available** — better for searching and citations
3. **Speaker labels matter** — crucial for interviews and panels
4. **Language detection** — specify language if known to improve accuracy
5. **Chunking** — for long content, split into sections with headers
6. **Metadata is valuable** — always capture title, date, speakers, source

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No captions found" | Video may have disabled captions → try Whisper |
| Rate limited | Wait for Retry-After period, or use next fallback |
| Whisper slow | Use `--model tiny` for draft, `medium` for quality |
| AssemblyAI timeout | File too large, compress audio first |
| Missing speakers | Add `speaker_labels: true` to AssemblyAI request |

---

*Last updated: 2026-04-16*  
*See also: `transcriptapi.md` for detailed API reference*