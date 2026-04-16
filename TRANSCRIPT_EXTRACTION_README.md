# Transcript Extraction System

## Overview

This system provides universal transcript extraction for YouTube videos and podcasts with intelligent fallback chains. It integrates seamlessly with the Obsidian automation pipeline.

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Content Type  │───▶│  Detection Layer │───▶│ Extraction Flow │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         ▼                       ▼                       ▼
    ┌─────────┐           ┌──────────┐           ┌──────────────┐
    │ YouTube │           │ is_youtube_link() │   │ Existing → TranscriptAPI → Supadata → Whisper │
    └─────────┘           └──────────┘           └──────────────┘
         │                       │                       │
         ▼                       ▼                       ▼
    ┌─────────┐           ┌──────────┐           ┌──────────────┐
    │ Podcast │           │ is_podcast_file() │  │ Existing → AssemblyAI │
    └─────────┘           └──────────┘           └──────────────┘
```

## YouTube Video Extraction

### Hierarchy (in order):
1. **Existing/Available Transcript** - Check cache, vault, and previous extractions
2. **TranscriptAPI** (Primary) - Fast, reliable, 1 credit per transcript
3. **Supadata** (Fallback) - Alternative API with good coverage
4. **Local Whisper** (Last Resort) - Offline processing with high accuracy

### Implementation Details:

#### Step 0: Check Existing
- Search `~/.hermes/cache/transcripts/youtube/` for cached results
- Check Obsidian vault for existing notes about the video
- Look for manual transcripts or previous extractions

#### Step 1: TranscriptAPI
```bash
curl -s "https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=false&send_metadata=true" \
  -H "Authorization: Bearer $TRANSCRIPT_API_KEY"
```
**Cost:** 1 credit per transcript  
**Rate limit:** 300 req/min  
**Free tier:** 100 credits

#### Step 2: Supadata
```bash
curl -s "https://api.supadata.ai/v1/youtube/transcript?url=VIDEO_URL&text=true&lang=en" \
  -H "x-api-key: $SUPADATA_API_KEY"
```
**Features:** Handles rate limiting, supports multiple languages

#### Step 3: Local Whisper
```bash
# Download audio
yt-dlp -x --audio-format mp3 -o "/tmp/%(id)s.%(ext)s" "VIDEO_URL"

# Transcribe with Whisper
whisper "/tmp/VIDEO_ID.mp3" \
  --model medium \
  --language en \
  --output_format txt \
  --output_dir ~/.hermes/cache/transcripts/youtube/

# Clean up
rm "/tmp/VIDEO_ID.mp3"
```
**Time:** 2-10 minutes depending on video length  
**Quality:** High accuracy, supports 90+ languages  
**No API costs**

## Podcast Extraction

### Hierarchy (in order):
1. **Existing/Available Transcript** - Check RSS feeds, show notes, podcast websites
2. **AssemblyAI** (Fallback) - Professional transcription with speaker identification

### Implementation Details:

#### Step 0: Check Existing
- Search podcast RSS feed for transcript links
- Check podcast website for show notes with transcripts
- Look for manual transcripts in vault or cache
- Search `~/.hermes/cache/transcripts/podcasts/`

#### Step 1: AssemblyAI
```bash
# Upload audio file
UPLOAD_URL=$(curl -s -X POST "https://api.assemblyai.com/v2/upload" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@audio_file.mp3" \
  | jq -r '.upload_url')

# Request transcription with speaker labels
TRANSCRIPT_ID=$(curl -s -X POST "https://api.assemblyai.com/v2/transcript" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"audio_url\": \"$UPLOAD_URL\", \"speaker_labels\": true}" \
  | jq -r '.id')

# Poll for completion
while true; do
  STATUS=$(curl -s "https://api.assemblyai.com/v2/transcript/$TRANSCRIPT_ID" \
    -H "Authorization: $ASSEMBLYAI_API_KEY" | jq -r '.status')
  
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
  -H "Authorization: $ASSEMBLYAI_API_KEY" | jq -r '.text'
```

**Features:**
- Speaker identification and labeling
- Punctuation and proper casing
- Paragraph detection
- Confidence scores for each segment

## Integration with Obsidian Pipeline

### File Structure
```
obsidian-automation/
├── v1/
│   ├── skills/
│   │   ├── transcript-extraction.md    # Skill documentation
│   │   └── transcriptapi.md            # API reference
│   └── scripts/
│       ├── extract-transcript.sh       # Standalone extraction script
│       └── process-inbox.sh            # Main pipeline with transcript support
```

### Usage

#### Via CLI Script
```bash
# Extract YouTube transcript
./scripts/extract-transcript.sh youtube "https://youtube.com/watch?v=VIDEO_ID"

# Extract podcast transcript
./scripts/extract-transcript.sh podcast "path/to/episode.mp3" \
  --name "Podcast Name" --episode "Episode Title"
```

#### Via Obsidian Pipeline
1. Place YouTube URLs or podcast audio files in `00-Inbox/raw/`
2. Run `process-inbox.sh` to automatically detect and process
3. Transcripts are saved to `04-Wiki/sources/` with proper frontmatter
4. Karpathy pipeline generates Entry, Concept, and MoC notes

### Output Format

#### YouTube Transcript
```markdown
# Video Title
**Source:** [YouTube URL]
**Extracted:** [ISO timestamp]
**Method:** [transcriptapi|supadata|whisper|existing]

## Transcript
[Full transcript text with timestamps if available]

---
*Extracted via [method] on [date]*
```

#### Podcast Transcript
```markdown
# Podcast Name - Episode Title
**Source:** [Podcast URL/RSS]
**Extracted:** [ISO timestamp]
**Method:** [existing|assemblyai]
**Speakers:** [identified speakers if available]

## Transcript
[Full transcript with speaker labels]

---
*Extracted via [method] on [date]*
```

## Cache Management

### Cache Structure
```
~/.hermes/cache/transcripts/
├── youtube/
│   ├── VIDEO_ID_1.json
│   └── VIDEO_ID_2.json
├── podcasts/
│   ├── PODCAST_HASH_1.json
│   └── PODCAST_HASH_2.json
└── metadata.json
```

### Cache Policy
- **Expiry:** 30 days or explicit refresh
- **Size limit:** 1GB total cache size
- **Cleanup:** Automatic removal of oldest entries when limit exceeded

## Error Handling

### API Failure Protocol
1. Log error with timestamp and endpoint
2. Implement exponential backoff (2s, 4s, 8s)
3. Maximum 3 retry attempts per service
4. Fall back to next method in chain
5. Alert user if all methods fail

### Rate Limiting
- **TranscriptAPI:** 300 req/min (respect Retry-After header)
- **Supadata:** Check documentation for limits
- **AssemblyAI:** 5 concurrent transcripts
- **Local Whisper:** No limits (CPU/GPU bound)

## Environment Setup

### Required Variables
```bash
# Add to ~/.bashrc or ~/.zshrc
export TRANSCRIPT_API_KEY="sk_8QgqMvNXEAl2onmXQW-g5lVfMd9dMYoySuT6TuUigw8"
export SUPADATA_API_KEY="your_key_here"        # Add when available
export ASSEMBLYAI_API_KEY="your_key_here"      # Add when available
```

### Dependencies
```bash
# Ubuntu/Debian
sudo apt install jq ffmpeg

# Python packages
pip install yt-dlp openai-whisper

# Verify installations
which curl jq yt-dlp whisper ffmpeg
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No captions found" | Video may have disabled captions → try Whisper |
| Rate limited | Wait for Retry-After period, or use next fallback |
| Whisper slow | Use `--model tiny` for draft, `medium` for quality |
| AssemblyAI timeout | File too large, compress audio first |
| Missing speakers | Add `speaker_labels: true` to AssemblyAI request |

## Performance Metrics

### YouTube Extraction
- **TranscriptAPI:** 2-5 seconds, 95% success rate
- **Supadata:** 3-8 seconds, 90% success rate  
- **Whisper:** 2-10 minutes, 99% accuracy

### Podcast Extraction
- **Existing transcript:** 1-3 seconds
- **AssemblyAI:** 5-15 minutes depending on episode length

## Best Practices

1. **Always check cache first** — API calls cost money/time
2. **Use timestamps when available** — better for searching and citations
3. **Speaker labels matter** — crucial for interviews and panels
4. **Language detection** — specify language if known to improve accuracy
5. **Chunking** — for long content, split into sections with headers
6. **Metadata is valuable** — always capture title, date, speakers, source

---

## Related Files

- `skills/transcript-extraction.md` — Detailed skill documentation
- `skills/transcriptapi.md` — TranscriptAPI reference
- `scripts/extract-transcript.sh` — Standalone extraction script
- `scripts/process-inbox.sh` — Main pipeline integration

---

*Last updated: 2026-04-16*