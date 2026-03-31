---
title: Vault dashboard
tags:
  - meta
  - dashboard
---

# Vault dashboard

## Inbox — waiting to be processed

```dataview
TABLE file.name AS "File", file.ctime AS "Added"
FROM "00-Inbox/raw" OR "00-Inbox/clippings"
SORT file.ctime DESC
```

## Failed items (needs manual review)

```dataview
TABLE file.name AS "File", file.ctime AS "Added"
FROM "00-Inbox/failed"
SORT file.ctime DESC
```

## Quick notes (never auto-processed)

```dataview
TABLE file.name AS "Note", file.mtime AS "Modified"
FROM "00-Inbox/quick notes"
SORT file.mtime DESC
```

## Recently distilled

```dataview
TABLE source AS "From", date_distilled AS "Distilled", length(file.tags) AS "Tags"
FROM "02-Distilled"
SORT date_distilled DESC
LIMIT 20
```

## Recent atomic notes

```dataview
TABLE source AS "Source", date_created AS "Created"
FROM "03-Atomic"
SORT date_created DESC
LIMIT 20
```

## Maps of content

```dataview
TABLE date_updated AS "Last updated", length(file.inlinks) AS "Inlinks"
FROM "04-MoCs"
SORT date_updated DESC
```

## Work in progress

```dataview
TABLE status AS "Status", file.mtime AS "Modified"
FROM "05-WIP"
SORT file.mtime DESC
```

## Tag frequency (top 30)

```dataview
TABLE length(rows) AS "Count"
FROM "03-Atomic" OR "02-Distilled"
FLATTEN file.tags AS tag
WHERE !contains(tag, "atomic") AND !contains(tag, "distilled")
GROUP BY tag
SORT length(rows) DESC
LIMIT 30
```
