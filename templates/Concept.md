---
title: "Concept name as concise phrase"
date_created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - concept
  - topic-tag-1
  - topic-tag-2
entry_refs:
  - "[[Entry 1]]"
  - "[[Entry 2]]"
status: evergreen
aliases: []
---

# Concept Name

2-5 sentences explaining the idea standalone.

## References
- Entries: [[Entry1]], [[Entry2]]
- Related Concepts: [[Concept1]], [[Concept2]]

---

## Language variants

### English (default)
Sections: Core idea, How it works, Why it matters, In practice, Connections, Open questions

### Chinese (language: zh in frontmatter)
Frontmatter: add `language: zh`, tags stay English.
Sections (Chinese body text):
  核心概念 (2-3句中文定义)
  运作机制 (编号或破折号列表)
  为什么重要 (破折号列表)
  实际案例 (破折号列表)
  关联 (破折号列表, wikilinks)
  开放问题 (编号列表)

### Bilingual (template: bilingual)
Use when an English and Chinese concept converge on the same idea.
Frontmatter: add `languages: [en, zh]`, `template: bilingual`.
Title: `English Name / 中文名称` format.
aliases: include the non-canonical title (e.g., Chinese if English is primary).
Body structure — both languages in one note, each complete:

## Overview / 概述
(2-3 sentences in English, then 2-3 sentences in Chinese)

## Core Idea / 核心概念
### English
(English explanation)
### 中文
(Chinese explanation)

## How It Works / 运作机制
### English
(Bullet list)
### 中文
(编号或破折号列表)

## Why It Matters / 为什么重要
### English
(Bullet list)
### 中文
(破折号列表)

## In Practice / 实际案例
### English
(Bullet list with entry refs)
### 中文
(破折号列表, 含entry refs)

## Connections / 关联
(Wikilinks to related concepts — shared section, no language split)

## Open Questions / 开放问题
(Numbered list — shared section, no language split)

## References
- English Entries: [[Entry1]], [[Entry2]]
- 中文来源: [[中文Entry1]], [[中文Entry2]]
- Related Concepts: [[Concept1]]
