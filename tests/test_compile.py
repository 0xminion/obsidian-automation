"""Tests for pipeline.compile module."""

from pathlib import Path
from unittest.mock import patch

import pytest

from pipeline.compile import _load_prompt, _count_md, run_compile
from pipeline.config import Config


@pytest.fixture
def cfg(tmp_path):
    for d in ["04-Wiki/entries", "04-Wiki/concepts", "04-Wiki/mocs", "04-Wiki/sources", "06-Config"]:
        (tmp_path / d).mkdir(parents=True, exist_ok=True)
    return Config(vault_path=tmp_path)


@pytest.fixture
def prompts_dir(tmp_path):
    d = tmp_path / "prompts"
    d.mkdir()
    (d / "compile-pass.prompt").write_text(
        "Compile vault at {VAULT_PATH}. {ENTRY_COUNT} entries, {CONCEPT_COUNT} concepts, {MOC_COUNT} MoCs."
    )
    return d


class TestLoadPrompt:
    def test_loads_existing_prompt(self, prompts_dir):
        content = _load_prompt("compile-pass", prompts_dir)
        assert "{VAULT_PATH}" in content

    def test_returns_empty_for_missing(self, prompts_dir):
        content = _load_prompt("nonexistent", prompts_dir)
        assert content == ""


class TestCountMd:
    def test_empty_dir(self, tmp_path):
        d = tmp_path / "empty"
        d.mkdir()
        assert _count_md(d) == 0

    def test_counts_md_files(self, tmp_path):
        d = tmp_path / "notes"
        d.mkdir()
        (d / "a.md").write_text("# A\n")
        (d / "b.md").write_text("# B\n")
        (d / "c.txt").write_text("not md\n")
        assert _count_md(d) == 2

    def test_nonexistent_dir(self, tmp_path):
        assert _count_md(tmp_path / "nope") == 0


class TestRunCompile:
    @patch("pipeline.compile._run_agent", return_value=True)
    def test_success(self, mock_agent, cfg, prompts_dir, monkeypatch):
        # Patch the prompts dir lookup
        import pipeline.compile as compile_mod
        monkeypatch.setattr(compile_mod, "_load_prompt", lambda name, d: "Test prompt {VAULT_PATH}")
        result = run_compile(cfg)
        assert result["success"] is True
        assert result["entries"] == 0
        assert result["concepts"] == 0

    @patch("pipeline.compile._run_agent", return_value=False)
    def test_failure(self, mock_agent, cfg, monkeypatch):
        import pipeline.compile as compile_mod
        monkeypatch.setattr(compile_mod, "_load_prompt", lambda name, d: "Test prompt")
        result = run_compile(cfg)
        assert result["success"] is False

    def test_missing_prompt(self, cfg, monkeypatch):
        import pipeline.compile as compile_mod
        monkeypatch.setattr(compile_mod, "_load_prompt", lambda name, d: "")
        result = run_compile(cfg)
        assert result["success"] is False
        assert "not found" in result["error"]
