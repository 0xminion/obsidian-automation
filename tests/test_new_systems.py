"""Tests for new systems: ContentStore, DLQ, deterministic planning, review workflow."""

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from pipeline.store import ContentStore
from pipeline.models import (
    ExtractedSource, Language, Manifest, Plan, Plans, SourceType, Template, ConceptMatch,
)
from pipeline.plan import (
    detect_language, select_template,
    generate_plan_heuristic, generate_plans_deterministic,
)
from pipeline.create import (
    generate_source_content, generate_entry_content,
    create_file_templates,
)
from pipeline.review import stage_for_review, show_pending, approve_reviews, reject_reviews


# ─── Fixtures ─────────────────────────────────────────────────────────────────

@pytest.fixture
def store(tmp_path: Path) -> ContentStore:
    return ContentStore(tmp_path / "test_store.db")


@pytest.fixture
def cfg(tmp_path: Path):
    from pipeline.config import Config
    extract_dir = tmp_path / "extracted"
    extract_dir.mkdir()
    cfg = Config(vault_path=tmp_path, extract_dir=extract_dir)
    # Create vault dirs
    cfg.sources_dir.mkdir(parents=True, exist_ok=True)
    cfg.entries_dir.mkdir(parents=True, exist_ok=True)
    cfg.concepts_dir.mkdir(parents=True, exist_ok=True)
    return cfg


@pytest.fixture
def sample_entry():
    return ExtractedSource(
        url="https://example.com/article",
        title="Test Article",
        content="# Test Article\n\nThis is a test article about blockchain and cryptocurrency. " * 5,
        type=SourceType.WEB,
        author="Test Author",
    )


@pytest.fixture
def sample_plan():
    return Plan(
        hash="abc123def456",
        title="Test Article",
        language=Language.EN,
        template=Template.STANDARD,
        tags=["test", "example"],
        concept_new=["New Concept"],
        concept_updates=["Existing Concept"],
        moc_targets=["Test MoC"],
    )


# ─── ContentStore Tests ──────────────────────────────────────────────────────

class TestContentStore:
    def test_creates_database(self, tmp_path: Path):
        db_path = tmp_path / "store.db"
        store = ContentStore(db_path)
        assert db_path.exists()
        store.close()

    def test_url_dedup(self, store: ContentStore):
        assert not store.is_url_extracted("https://example.com")
        store.register_url("https://example.com", "web")
        assert store.is_url_extracted("https://example.com")

    def test_url_normalization(self):
        assert ContentStore.normalize_url("https://Example.COM/path/") == "https://example.com/path"
        assert ContentStore.normalize_url(
            "https://example.com/page?utm_source=twitter&id=1"
        ) == "https://example.com/page?id=1"

    def test_content_dedup(self, store: ContentStore):
        content = "This is test content for deduplication."
        assert store.get_content_duplicate(content) is None
        chash = store.register_content(content, "Test", "web", "test-file")
        assert store.get_content_duplicate(content) == "test-file"
        # Same content, different URL → still detects duplicate
        assert store.get_content_duplicate("  This   is test   content for deduplication.  ") == "test-file"

    def test_content_hash_deterministic(self):
        ch1 = ContentStore.content_hash("Hello World test")
        ch2 = ContentStore.content_hash("hello world TEST")
        assert ch1 == ch2

    def test_content_hash_differs_for_different_content(self):
        ch1 = ContentStore.content_hash("Article about blockchain")
        ch2 = ContentStore.content_hash("Recipe for chocolate cake")
        assert ch1 != ch2

    def test_stats(self, store: ContentStore):
        stats = store.get_stats()
        assert stats["urls_total"] == 0
        assert stats["content_total"] == 0
        assert stats["dlq_pending"] == 0

        store.register_url("https://a.com", "web")
        store.register_url("https://b.com", "web", status="failed")
        store.register_content("content", "Title", "web")
        stats = store.get_stats()
        assert stats["urls_total"] == 2
        assert stats["urls_ok"] == 1
        assert stats["urls_failed"] == 1
        assert stats["content_total"] == 1

    def test_dlq_add_and_get(self, store: ContentStore):
        store.dlq_add("https://fail.com", "cloudflare", "Got challenge page")
        pending = store.dlq_get_pending()
        assert len(pending) == 1
        assert pending[0]["url"] == "https://fail.com"
        assert pending[0]["reason"] == "cloudflare"
        assert pending[0]["attempts"] == 1

    def test_dlq_increment_attempts(self, store: ContentStore):
        store.dlq_add("https://fail.com", "timeout", "First failure")
        store.dlq_add("https://fail.com", "timeout", "Second failure")
        pending = store.dlq_get_pending()
        assert len(pending) == 1
        assert pending[0]["attempts"] == 2

    def test_dlq_resolve(self, store: ContentStore):
        item_id = store.dlq_add("https://fail.com", "unknown", "Error")
        store.dlq_resolve(item_id)
        assert len(store.dlq_get_pending()) == 0

    def test_dlq_clear(self, store: ContentStore):
        store.dlq_add("https://a.com", "cloudflare", "")
        store.dlq_add("https://b.com", "timeout", "")
        cleared = store.dlq_clear()
        assert cleared == 2
        assert len(store.dlq_get_pending()) == 0

    def test_dlq_clear_by_reason(self, store: ContentStore):
        store.dlq_add("https://a.com", "cloudflare", "")
        store.dlq_add("https://b.com", "timeout", "")
        cleared = store.dlq_clear(reason="cloudflare")
        assert cleared == 1
        remaining = store.dlq_get_pending()
        assert len(remaining) == 1
        assert remaining[0]["reason"] == "timeout"

    def test_review_add_and_get(self, store: ContentStore):
        rid = store.review_add(
            plan_hash="abc123",
            plan_data={"title": "Test"},
            file_type="source",
            file_path="/tmp/test.md",
            file_content="# Test",
        )
        pending = store.review_get_pending()
        assert len(pending) == 1
        assert pending[0]["file_type"] == "source"
        assert pending[0]["plan_data"]["title"] == "Test"

    def test_review_approve(self, store: ContentStore):
        rid = store.review_add("abc", {}, "source", "/tmp/test.md", "content")
        store.review_approve(rid)
        assert len(store.review_get_pending()) == 0

    def test_review_reject(self, store: ContentStore):
        rid = store.review_add("abc", {}, "entry", "/tmp/test.md", "content")
        store.review_reject(rid)
        assert len(store.review_get_pending()) == 0

    def test_review_clear(self, store: ContentStore):
        store.review_add("a", {}, "source", "/tmp/a.md", "a")
        store.review_add("b", {}, "entry", "/tmp/b.md", "b")
        cleared = store.review_clear()
        assert cleared == 2


# ─── Deterministic Planning Tests ────────────────────────────────────────────

class TestDetectLanguage:
    def test_english(self):
        assert detect_language("This is an English article about technology.") == Language.EN

    def test_chinese(self):
        assert detect_language("这是一篇中文文章，讨论区块链技术的发展。") == Language.ZH

    def test_mixed_mostly_english(self):
        assert detect_language("This article mentions 区块链 briefly.") == Language.EN

    def test_mixed_mostly_chinese(self):
        assert detect_language("这篇文章讨论了blockchain技术在crypto领域的应用和发展趋势。") == Language.ZH

    def test_empty(self):
        assert detect_language("") == Language.EN


class TestSelectTemplate:
    def test_podcast_is_standard(self):
        assert select_template(SourceType.PODCAST, "content") == Template.STANDARD

    def test_youtube_is_standard(self):
        assert select_template(SourceType.YOUTUBE, "content") == Template.STANDARD

    def test_technical_content(self):
        content = "Our methodology involved data analysis with statistical regression and p-value testing."
        assert select_template(SourceType.WEB, content) == Template.TECHNICAL

    def test_general_content(self):
        content = "This is a blog post about personal experiences and opinions on life."
        assert select_template(SourceType.WEB, content) == Template.STANDARD


class TestGeneratePlanHeuristic:
    def test_basic_plan(self, sample_entry: ExtractedSource):
        plan = generate_plan_heuristic(sample_entry, [])
        assert plan.title == "Test Article"
        assert plan.language == Language.EN
        assert plan.template == Template.STANDARD

    def test_concept_from_matches(self, sample_entry: ExtractedSource):
        matches = [ConceptMatch(concept="Blockchain", score=0.7)]
        plan = generate_plan_heuristic(sample_entry, matches)
        assert "Blockchain" in plan.concept_updates

    def test_weak_match_creates_new(self, sample_entry: ExtractedSource):
        matches = [ConceptMatch(concept="Weak", score=0.1)]
        plan = generate_plan_heuristic(sample_entry, matches)
        assert len(plan.concept_new) > 0


class TestGeneratePlansDeterministic:
    def test_returns_plans_and_uncertain(self):
        entries = [
            ExtractedSource(
                url="https://example.com/good",
                title="Good Article",
                content="# Good Article\n\nThis is a well-formed article with enough content. " * 5,
                type=SourceType.WEB,
            ),
            ExtractedSource(
                url="https://example.com/short",
                title="",
                content="short",
                type=SourceType.WEB,
            ),
        ]
        manifest = Manifest(entries=entries)
        cm = {e.hash: [] for e in entries}
        plans, uncertain = generate_plans_deterministic(manifest, cm)
        assert len(plans.plans) >= 1
        assert len(uncertain) >= 1


# ─── Template Creation Tests ─────────────────────────────────────────────────

class TestGenerateSourceContent:
    def test_generates_frontmatter(self, sample_plan: Plan):
        extracted = {
            "url": "https://example.com/article",
            "type": "web",
            "author": "Test Author",
            "content": "Article content here.",
        }
        content = generate_source_content(sample_plan, extracted)
        assert 'title: "Test Article"' in content
        assert 'source_url: "https://example.com/article"' in content
        assert "## Original Content" in content

    def test_tags_in_yaml(self, sample_plan: Plan):
        extracted = {"url": "https://example.com", "type": "web", "author": "", "content": "Content."}
        content = generate_source_content(sample_plan, extracted)
        assert "- test" in content
        assert "- example" in content


class TestGenerateEntryContent:
    def test_generates_sections(self, sample_plan: Plan):
        extracted = {
            "url": "https://example.com/article",
            "type": "web",
            "author": "Test Author",
            "content": "# Test Article\n\nThis is a summary paragraph.\n\nMore content here.",
        }
        content = generate_entry_content(sample_plan, extracted, "test-article")
        assert "## Summary" in content
        assert "## Core insights" in content
        assert "## Linked concepts" in content
        assert "[[test-article]]" in content

    def test_uses_insights(self, sample_plan: Plan):
        extracted = {
            "url": "https://example.com/article",
            "type": "web",
            "author": "",
            "content": "# Title\n\nBody.",
        }
        insights = "## Summary\nThis is a great summary.\n\n## Core insights\n1. First insight\n2. Second insight"
        content = generate_entry_content(sample_plan, extracted, "test", insights)
        assert "This is a great summary." in content
        assert "First insight" in content

    def test_fallback_summary(self, sample_plan: Plan):
        extracted = {
            "url": "https://example.com/article",
            "type": "web",
            "author": "",
            "content": "# Title\n\nThis is the first paragraph of content.",
        }
        content = generate_entry_content(sample_plan, extracted, "test")
        assert "first paragraph" in content


# ─── Review Workflow Tests ────────────────────────────────────────────────────

class TestReviewWorkflow:
    def test_show_pending_empty(self, cfg):
        pending = show_pending(cfg)
        assert pending == []

    def test_approve_empty(self, cfg):
        from pipeline.review import approve_reviews
        stats = approve_reviews(cfg)
        assert stats["approved"] == 0

    def test_reject_returns_count(self, cfg):
        count = reject_reviews(cfg)
        assert count == 0
