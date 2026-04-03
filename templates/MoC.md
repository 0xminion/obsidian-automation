---
title: "Map of Content — <Topic>"
type: moc
date_created: {{date}}
date_updated: {{date}}
status: active
tags:
  - <topic-tag>
  - map-of-content
---

# <Topic Name> — Map of Content

## Overview
> <2-3 sentence synthesized summary of this topic. Pull understanding
> from the linked notes. What does this topic cover? Why does it matter?>

## Core Concepts
- [[<Atomic note 1>]] — <1-sentence summary>
- [[<Atomic note 2>]] — <1-sentence summary>

## Related Research
- [[<Distilled note 1>]] — <1-sentence summary>
- [[<Distilled note 2>]] — <1-sentence summary>

## Open Threads
- <Question or gap for future exploration>
- <Another open question>

```dataview
TABLE status, source
FROM "02-Distilled"
WHERE contains(tags, "<topic-tag>")
SORT date_distilled DESC
```

```dataview
TABLE tags
FROM "03-Atomic"
WHERE contains(tags, "<topic-tag>")
SORT file.name
```
