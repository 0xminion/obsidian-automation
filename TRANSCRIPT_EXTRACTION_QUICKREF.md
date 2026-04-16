# Transcript Extraction Quick Reference

## YouTube Flow
```
existing → transcriptapi → supadata → whisper
```

## Podcast Flow  
```
existing → assemblyai
```

## Commands

### Check for Existing
```bash
# Search cache
ls ~/.hermes/cache/transcripts/youtube/ | grep VIDEO_ID
ls ~/.hermes/cache/transcripts/podcasts/ | grep PODCAST_HASH

# Search vault
find ~/MyVault -name "*.md" -exec grep -l "VIDEO_ID\|PODCAST_NAME" {} \;
```

### Extract YouTube
```bash
# Via script
./scripts/extract-transcript.sh youtube "VIDEO_URL"

# Via API (TranscriptAPI)
curl -s "https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text" \
  -H "Authorization: Bearer $TRANSCRIPT_API_KEY"

# Via API (Supadata)
curl -s "https://api.supadata.ai/v1/youtube/transcript?url=VIDEO_URL&text=true" \
  -H "x-api-key: $SUPADATA_API_KEY"

# Via Whisper
yt-dlp -x --audio-format mp3 -o "/tmp/%(id)s.%(ext)s" "VIDEO_URL"
whisper "/tmp/VIDEO_ID.mp3" --model medium --language en
```

### Extract Podcast
```bash
# Via script
./scripts/extract-transcript.sh podcast "AUDIO_FILE" --name "Podcast" --episode "Episode"

# Via AssemblyAI
UPLOAD_URL=$(curl -s -X POST "https://api.assemblyai.com/v2/upload" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  --data-binary "@audio.mp3" | jq -r '.upload_url')

TRANSCRIPT_ID=$(curl -s -X POST "https://api.assemblyai.com/v2/transcript" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" \
  -d "{\"audio_url\": \"$UPLOAD_URL\", \"speaker_labels\": true}" | jq -r '.id')

# Poll status
curl -s "https://api.assemblyai.com/v2/transcript/$TRANSCRIPT_ID" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" | jq '.status'

# Get result
curl -s "https://api.assemblyai.com/v2/transcript/$TRANSCRIPT_ID" \
  -H "Authorization: $ASSEMBLYAI_API_KEY" | jq -r '.text'
```

## Environment
```bash
export TRANSCRIPT_API_KEY="sk_8QgqMvNXEAl2onmXQW-g5lVfMd9dMYoySuT6TuUigw8"
export SUPADATA_API_KEY="your_key"
export ASSEMBLYAI_API_KEY="your_key"
```

## Cache Locations
- YouTube: `~/.hermes/cache/transcripts/youtube/`
- Podcasts: `~/.hermes/cache/transcripts/podcasts/`
- Logs: `~/.hermes/cache/transcripts/extraction.log`

## Output Format
Both YouTube and podcasts output markdown with:
- Title and source metadata
- Extraction method and timestamp
- Full transcript text
- Speaker labels (if available)
- Proper frontmatter for Obsidian integration