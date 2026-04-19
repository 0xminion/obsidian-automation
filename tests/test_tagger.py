"""Tests for pipeline.tagger — heuristic tag extraction."""

from pipeline.tagger import extract_tags, extract_tags_debug, _extract_url_signals


class TestExtractTags:
    """Core tag extraction."""

    def test_crypto_content(self):
        content = """
        Bitcoin surged past $100,000 as institutional adoption accelerated.
        Ethereum's smart contracts continue to dominate DeFi with Uniswap and Aave
        leading the charge. The Solana ecosystem is growing rapidly with new
        token launches and NFT marketplace activity on Magic Eden.
        Staking yields remain attractive for long-term holders.
        """
        tags = extract_tags(content, title="Bitcoin Surges Past $100K", url="https://x.com/cryptotrader/status/123")
        assert "bitcoin" in tags
        assert "ethereum" in tags or "defi" in tags
        assert "crypto" in tags
        # Should NOT contain banned tags
        for t in tags:
            assert t not in ("source", "url", "content", "video")

    def test_geopolitics_content(self):
        content = """
        NATO allies convened an emergency summit following escalated tensions
        in Eastern Europe. The alliance discussed deterrence strategies and
        sanctions against Russia. Diplomacy efforts continue through the UN
        Security Council. Military analysts warn of proxy war expansion.
        The geopolitical implications extend to energy markets and global supply chains.
        Iran believes it has the upper hand in negotiations.
        """
        tags = extract_tags(content, title="NATO Emergency Summit on Ukraine")
        assert "geopolitics" in tags
        assert "nato" in tags

    def test_ai_content(self):
        content = """
        OpenAI released GPT-4o with multimodal capabilities. The model uses
        a transformer architecture with improved reasoning and reduced
        hallucinations. Fine-tuning with RLHF has become standard practice.
        Anthropic's Claude competes on safety. Vector databases and RAG
        pipelines are now essential for enterprise AI deployments.
        Machine learning engineers focus on inference optimization.
        """
        tags = extract_tags(content, title="GPT-4o Multimodal Release")
        assert "ai-ml" in tags
        # Should detect specific entities
        assert any(t in tags for t in ("gpt", "openai", "claude"))

    def test_banned_tags_excluded(self):
        content = "This is a video about a podcast article on a blog post. URL source content."
        tags = extract_tags(content)
        for t in tags:
            assert t not in ("video", "podcast", "article", "blog", "source", "url", "content")

    def test_title_weighting(self):
        """Title entities should score higher than body-only entities."""
        content = """
        The article discusses various topics. There is a mention of Bitcoin
        somewhere in the text. But the real focus is on monetary policy
        and interest rates set by the Federal Reserve.
        """
        tags = extract_tags(content, title="Federal Reserve Raises Interest Rates")
        # Fed should be in tags since it's in the title
        assert any("federal-reserve" in t or "finance" in t for t in tags)

    def test_phrase_detection(self):
        content = """
        The protocol uses smart contracts for yield farming in liquidity pools.
        Proof of stake consensus mechanisms are replacing proof of work.
        Layer 2 rollups provide scalability through zero knowledge proofs.
        """
        tags = extract_tags(content, title="DeFi Yield Farming Guide")
        assert any("yield" in t or "smart-contract" in t for t in tags)

    def test_max_tags_respected(self):
        content = "Bitcoin Ethereum Solana DeFi NFT blockchain cryptocurrency token web3 smart contract staking"
        tags = extract_tags(content, max_tags=3)
        assert len(tags) <= 3

    def test_empty_content(self):
        assert extract_tags("") == []
        assert extract_tags("", title="") == []

    def test_url_signals_twitter(self):
        tags = extract_tags("some content", url="https://x.com/thecryptoskanda/status/123")
        assert "@thecryptoskanda" in tags

    def test_url_signals_youtube(self):
        tags = extract_tags("some content", url="https://youtube.com/watch?v=abc")
        assert "youtube" in tags

    def test_url_signals_medium(self):
        tags = extract_tags("some content", url="https://medium.com/@user/article")
        assert "medium" in tags


class TestExtractUrlSignals:
    """URL-based tag extraction."""

    def test_twitter_handle(self):
        signals = _extract_url_signals("https://x.com/elonmusk/status/123456")
        assert "@elonmusk" in signals

    def test_twitter_excludes_generic(self):
        signals = _extract_url_signals("https://x.com/i/status/123")
        assert "@i" not in signals

    def test_youtube(self):
        signals = _extract_url_signals("https://youtu.be/abc123")
        assert "youtube" in signals

    def test_apple_podcasts(self):
        signals = _extract_url_signals("https://podcasts.apple.com/us/podcast/test/id123")
        assert "apple-podcasts" in signals

    def test_arxiv(self):
        signals = _extract_url_signals("https://arxiv.org/abs/2401.12345")
        assert "arxiv" in signals


class TestExtractTagsDebug:
    """Debug mode returns scoring details."""

    def test_debug_returns_details(self):
        content = "Bitcoin is a cryptocurrency. Bitcoin mining uses proof of work."
        result = extract_tags_debug(content, title="Bitcoin Basics")
        assert len(result) > 0
        for item in result:
            assert "tag" in item
            assert "score" in item
            assert "sources" in item
            assert isinstance(item["sources"], list)

    def test_debug_score_ordering(self):
        content = """
        Bitcoin Bitcoin Bitcoin Bitcoin Bitcoin. Cryptocurrency blockchain.
        The economy inflation GDP recession monetary fiscal policy.
        """
        result = extract_tags_debug(content, title="Bitcoin Analysis")
        scores = [item["score"] for item in result]
        assert scores == sorted(scores, reverse=True)
