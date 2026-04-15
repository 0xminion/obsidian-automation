---
title: "Concise descriptive title"
source: "[[Source note name]]"
date_entry: YYYY-MM-DD
tags:
  - entry
  - topic-tag-1
  - topic-tag-2
  - topic-tag-3
  - topic-tag-4
  - topic-tag-5
status: review
reviewed: null
review_notes: null
template: standard
aliases: []
---

# Title

## Summary

3-5 sentence overview. Plain language, no fluff.

## ELI5 insights

### Core insights

1. First core insight — explained for a 12-year-old.
2. Second core insight — concrete example, no jargon.
3. Third core insight — as many as exist.

### Other takeaways

4. Continues numbering from Core insights.
5. Fourth insight — same ELI5 treatment.

## Diagrams

Mermaid diagrams if warranted, else "N/A — content is straightforward."

## Open questions

1. First question or gap from the source.
2. Second open question.

## Linked concepts

- [[Concept note 1]]
- [[Concept note 2]]
- [[Related Entry or MoC]]

---

## Template Variants

Use the `template:` frontmatter field to select a variant. The lint script
checks sections based on template type. Available templates:

### template: standard (default)
Sections: Summary, ELI5 insights, Diagrams, Open questions, Linked concepts

### template: technical
Sections: Summary, Key Findings, Data/Evidence, Methodology, Limitations, Linked concepts
Use for: research papers, data-heavy articles, technical documentation

### template: comparison
Sections: Summary, Side-by-Side Comparison, Pros/Cons, Verdict, Linked concepts
Use for: product comparisons, framework evaluations, "X vs Y" articles

### template: procedural
Sections: Summary, Prerequisites, Steps, Gotchas, Linked concepts
Use for: tutorials, how-tos, setup guides, workflows
