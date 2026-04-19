"""Heuristic tag extraction — no LLM, pure pattern + frequency analysis.

Multi-signal approach:
  1. Named entities (case-sensitive patterns) → specific tags like "bitcoin", "gpt-4"
  2. Topic domains (keyword clusters) → category tags like "crypto", "geopolitics"
  3. Bigram/trigram phrases → compound concepts like "smart contracts", "yield farming"
  4. URL metadata → source-specific signals (twitter handles, youtube channels)
  5. Title boosting → title words weighted 3x
  6. Positional weight → first/last 500 chars weighted 2x

Tags are deduplicated, scored, and top-N returned.
Generic tags like "source", "url", "content" are banned.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field


# ─── Banned tags ───────────────────────────────────────────────────────────────

_BANNED = {
    "source", "url", "content", "http", "https", "www", "com", "html",
    "video", "podcast", "article", "blog", "tweet", "post", "episode",
    "page", "site", "link", "click", "read", "watch", "listen",
    "subscribe", "follow", "share", "like", "comment", "reply",
    "newsletter", "xcom",
}


# ─── Named entity patterns (case-sensitive) ───────────────────────────────────

_ENTITY_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Crypto protocols & tokens
    (re.compile(r"\b(Bitcoin|BTC)\b"), "bitcoin"),
    (re.compile(r"\b(Ethereum|ETH)\b"), "ethereum"),
    (re.compile(r"\b(Solana|SOL)\b"), "solana"),
    (re.compile(r"\b(USDC|USDT|DAI|UST)\b"), "stablecoin"),
    (re.compile(r"\b(Uniswap|Aave|Compound|MakerDAO|Lido|Curve)\b"), "defi"),
    (re.compile(r"\b(Opensea|Blur|Magic Eden)\b"), "nft-marketplace"),
    (re.compile(r"\b(Arbitrum|Optimism|Base|zkSync|StarkNet|Polygon)\b"), "l2-scaling"),
    (re.compile(r"\b(Cosmos|Polkadot|Avalanche|Near|Aptos|Sui)\b"), "alt-l1"),
    (re.compile(r"\b(Binance|Coinbase|Kraken|OKX|Bybit)\b"), "exchange"),
    (re.compile(r"\b(Tether|Circle|Paxos)\b"), "stablecoin-issuer"),
    (re.compile(r"\b(BlackRock|Fidelity|Grayscale|ARK)\b"), "institutional"),

    # AI/ML models & companies
    (re.compile(r"\b(GPT-4|GPT-3|GPT-4o|o1|o3)\b"), "gpt"),
    (re.compile(r"\b(Claude|Anthropic)\b"), "claude"),
    (re.compile(r"\b(Gemini|Bard|DeepMind)\b"), "google-ai"),
    (re.compile(r"\b(Llama|Meta AI)\b"), "meta-ai"),
    (re.compile(r"\b(Mistral|Mixtral)\b"), "mistral"),
    (re.compile(r"\b(Stable Diffusion|Midjourney|DALL-E|Sora)\b"), "image-gen"),
    (re.compile(r"\b(Whisper|ElevenLabs)\b"), "audio-ai"),
    (re.compile(r"\b(Hugging ?Face)\b"), "huggingface"),
    (re.compile(r"\b(OpenAI)\b"), "openai"),

    # Geopolitical entities
    (re.compile(r"\b(NATO|OTAN)\b"), "nato"),
    (re.compile(r"\b(UN|United Nations)\b"), "un"),
    (re.compile(r"\b(WHO|WTO|IMF|World Bank)\b"), "intl-org"),
    (re.compile(r"\b(G7|G20|BRICS)\b"), "economic-bloc"),
    (re.compile(r"\b(EU|European Union)\b"), "eu"),
    (re.compile(r"\b(Taiwan|Ukraine|Russia|China|Iran|Israel|Palestine)\b"), "geopolitics"),

    # Finance entities
    (re.compile(r"\b(Fed|Federal Reserve)\b"), "federal-reserve"),
    (re.compile(r"\b(SEC|CFTC|FinCEN)\b"), "us-regulator"),
    (re.compile(r"\b(ECB|BOJ|BOE)\b"), "central-bank"),
    (re.compile(r"\b(S&P 500|NASDAQ|NYSE|Dow Jones)\b"), "equities"),
    (re.compile(r"\b(Tesla|Apple|Microsoft|Nvidia|Amazon|Meta|Google)\b"), "big-tech"),

    # Infra/DevOps
    (re.compile(r"\b(Docker|Kubernetes|K8s)\b"), "containers"),
    (re.compile(r"\b(PostgreSQL|MySQL|MongoDB|Redis)\b"), "database"),
    (re.compile(r"\b(AWS|GCP|Azure)\b"), "cloud"),
    (re.compile(r"\b(Linux|Ubuntu|Debian)\b"), "linux"),
    (re.compile(r"\b(Terraform|Ansible)\b"), "infra-as-code"),
]


# ─── Topic keyword clusters ───────────────────────────────────────────────────

_TOPIC_CLUSTERS: dict[str, list[str]] = {
    "crypto": [
        "cryptocurrency", "blockchain", "defi", "token", "web3", "dao",
        "smart contract", "consensus", "mining", "staking", "airdrop",
        "memecoin", "stablecoin", "dex", "amm", "liquidity pool",
        "yield farming", "tvl", "bridge", "rollup", "zk-proof",
        "pump.fun", "bonding curve", "mev", "front-running",
    ],
    "geopolitics": [
        "geopolitical", "sanctions", "diplomacy", "military", "war",
        "conflict", "alliance", "deterrence", "hegemony", "sovereignty",
        "nuclear", "treaty", "embargo", "proxy war", "escalation",
        "intelligence", "espionage", "coup", "regime",
    ],
    "ai-ml": [
        "artificial intelligence", "machine learning", "neural network",
        "llm", "transformer", "deep learning", "fine-tuning", "rlhf",
        "reinforcement learning", "computer vision", "nlp", "rag",
        "embedding", "vector database", "inference", "training",
        "multimodal", "agent", "prompt engineering", "reasoning",
    ],
    "finance": [
        "trading", "portfolio", "yield", "interest rate", "bond",
        "equity", "derivatives", "hedge", "arbitrage", "alpha",
        "beta", "sharpe", "volatility", "liquidity", "leverage",
        "margin", "futures", "options", "swap", "credit",
        "inflation", "monetary policy", "fiscal policy", "quantitative easing",
    ],
    "philosophy": [
        "epistemology", "ontology", "metaphysics", "ethics", "rationality",
        "consciousness", "phenomenology", "hermeneutics", "dialectic",
        "existentialism", "pragmatism", "utilitarianism", "deontology",
    ],
    "security": [
        "cybersecurity", "vulnerability", "exploit", "encryption",
        "authentication", "zero-day", "malware", "ransomware", "phishing",
        "firewall", "intrusion", "attack surface", "threat model",
        "smart contract audit", "rug pull", "flash loan attack",
    ],
    "economics": [
        "inflation", "monetary", "fiscal", "gdp", "recession",
        "macroeconomics", "microeconomics", "elasticity", "externality",
        "market structure", "oligopoly", "monopoly", "supply demand",
    ],
    "software-engineering": [
        "software", "programming", "api", "infrastructure", "cloud",
        "database", "microservices", "architecture", "devops", "ci/cd",
        "testing", "deployment", "scalability", "latency", "throughput",
    ],
    "energy": [
        "solar", "nuclear", "oil", "renewable", "battery", "grid",
        "carbon", "climate", "emissions", "hydrogen", "wind power",
        "energy transition", "fossil fuel",
    ],
    "biology": [
        "genetics", "evolution", "cell", "organism", "protein",
        "genome", "neuroscience", "crispr", "mrna", "vaccine",
        "epidemiology", "pandemic",
    ],
    "urbanism": [
        "housing", "zoning", "transit", "density", "suburb",
        "urban planning", "gentrification", "walkability", "sprawl",
    ],
    "healthcare": [
        "clinical", "patient", "treatment", "diagnosis",
        "pharmaceutical", "medical", "drug", "therapy", "trial",
    ],
    "history": [
        "historical", "century", "civilization", "empire", "revolution",
        "dynasty", "ancient", "medieval", "renaissance", "colonial",
    ],
    "psychology": [
        "cognitive", "behavioral", "bias", "heuristic", "mental model",
        "decision making", "neuroscience", "therapy", "trauma",
    ],
    "regulation": [
        "regulation", "compliance", "legislation", "policy", "law",
        "enforcement", "oversight", "framework", "guidance", "ruling",
    ],
}


# ─── Phrase patterns (bigrams/trigrams that should be single tags) ────────────

_PHRASE_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\b(smart contract[s]?)\b", re.I), "smart-contracts"),
    (re.compile(r"\b(yield farming)\b", re.I), "yield-farming"),
    (re.compile(r"\b(liquidity pool[s]?)\b", re.I), "liquidity-pools"),
    (re.compile(r"\b(machine learning)\b", re.I), "machine-learning"),
    (re.compile(r"\b(deep learning)\b", re.I), "deep-learning"),
    (re.compile(r"\b(neural network[s]?)\b", re.I), "neural-networks"),
    (re.compile(r"\b(prompt engineering)\b", re.I), "prompt-engineering"),
    (re.compile(r"\b(vector database[s]?)\b", re.I), "vector-databases"),
    (re.compile(r"\b(monetary policy)\b", re.I), "monetary-policy"),
    (re.compile(r"\b(fiscal policy)\b", re.I), "fiscal-policy"),
    (re.compile(r"\b(interest rate[s]?)\b", re.I), "interest-rates"),
    (re.compile(r"\b(bonding curve[s]?)\b", re.I), "bonding-curves"),
    (re.compile(r"\b(consensus mechanism[s]?)\b", re.I), "consensus-mechanisms"),
    (re.compile(r"\b(proof.of.stake)\b", re.I), "proof-of-stake"),
    (re.compile(r"\b(proof.of.work)\b", re.I), "proof-of-work"),
    (re.compile(r"\b(layer.2|l2)\b", re.I), "layer-2"),
    (re.compile(r"\b(layer.1|l1)\b", re.I), "layer-1"),
    (re.compile(r"\b(rollup[s]?)\b", re.I), "rollups"),
    (re.compile(r"\b(zero.knowledge|zk.)\b", re.I), "zero-knowledge"),
    (re.compile(r"\b(total value locked|TVL)\b"), "tvl"),
    (re.compile(r"\b(flash loan[s]?)\b", re.I), "flash-loans"),
    (re.compile(r"\b(artificial intelligence)\b", re.I), "artificial-intelligence"),
    (re.compile(r"\b(central bank[s]?)\b", re.I), "central-banks"),
    (re.compile(r"\b(central bank digital currenc[yi]es?|CBDC)\b", re.I), "cbdc"),
    (re.compile(r"\b(financial inclusion)\b", re.I), "financial-inclusion"),
    (re.compile(r"\b(energy transition)\b", re.I), "energy-transition"),
    (re.compile(r"\b(climate change)\b", re.I), "climate-change"),
    (re.compile(r"\b(nuclear proliferation)\b", re.I), "nuclear-proliferation"),
    (re.compile(r"\b(proxy war[s]?)\b", re.I), "proxy-wars"),
]


# ─── Stop words ────────────────────────────────────────────────────────────────

_STOP_WORDS = frozenset(
    "this that with from they been have their which about would these "
    "other into more also some than very just over such after before "
    "between under again there where being does will should could "
    "through during each every both few most then once here when what "
    "your make like time know take come good many them say year way may "
    "new first last long great little own same right still today must "
    "used using based using used however according according also "
    "been being much even well back down now since still too how its "
    "our out up get got has had him his her she him who did does done "
    "don can will not nor but and for are was were not all per its "
    "one two three four five six seven eight nine ten".split()
)


# ─── URL-derived signals ──────────────────────────────────────────────────────

def _extract_url_signals(url: str) -> list[str]:
    """Extract tags from URL structure."""
    tags = []

    # Twitter/X handles
    handle_match = re.search(r"x\.com/(\w+)/status", url)
    if handle_match:
        handle = handle_match.group(1).lower()
        if handle not in ("i", "home", "search", "explore", "notifications"):
            tags.append(f"@{handle}")

    # YouTube channel hints (from common patterns)
    if "youtu" in url:
        tags.append("youtube")

    # Podcast platform detection
    if "podcasts.apple.com" in url:
        tags.append("apple-podcasts")
    elif "spotify.com" in url:
        tags.append("spotify")
    elif "overcast" in url:
        tags.append("overcast")

    # Medium/Substack
    if "medium.com" in url:
        tags.append("medium")
    elif "substack.com" in url:
        tags.append("substack")

    # Academic
    if "arxiv.org" in url:
        tags.append("arxiv")
    elif "scholar.google" in url:
        tags.append("academic")

    return tags


# ─── Core tag extraction ──────────────────────────────────────────────────────

@dataclass
class _TagCandidate:
    tag: str
    score: float
    sources: list[str] = field(default_factory=list)  # where it was found


def extract_tags(
    content: str,
    title: str = "",
    url: str = "",
    max_tags: int = 8,
    existing_tags: set[str] | None = None,
) -> list[str]:
    """Extract meaningful tags using multi-signal heuristic analysis.

    Signals (highest to lowest weight):
      1. Named entities in title → 10.0
      2. Named entities in body → 5.0
      3. Phrase patterns (bigrams/trigrams) → 4.0
      4. Topic cluster matches (≥2 keywords) → 3.0
      5. Title word boosting → 3.0 per word
      6. Positional weight (first/last 500 chars) → 2.0
      7. URL signals → 2.0
      8. Repeated significant words (freq ≥ 3) → 1.0

    Returns specific, meaningful tags — never banned generics.
    """
    if not content and not title:
        return []

    candidates: dict[str, _TagCandidate] = {}

    def _add(tag: str, score: float, source: str = ""):
        tag = tag.lower().strip().replace(" ", "-")
        # Clean up tag
        tag = re.sub(r"[^a-z0-9@._-]", "", tag)
        tag = re.sub(r"-+", "-", tag).strip("-")
        if not tag or len(tag) < 2 or tag in _BANNED:
            return
        if tag in candidates:
            candidates[tag].score += score
            if source:
                candidates[tag].sources.append(source)
        else:
            candidates[tag] = _TagCandidate(tag=tag, score=score, sources=[source] if source else [])

    content_upper = content[:10000] if content else ""
    content_lower = content_upper.lower()
    title_lower = title.lower() if title else ""

    # 1. Named entities in TITLE (highest weight)
    if title:
        for pattern, category in _ENTITY_PATTERNS:
            if pattern.search(title):
                _add(category, 10.0, "entity-title")
                for entity in set(pattern.findall(title)):
                    _add(entity, 10.0, "entity-title")

    # 2. Named entities in BODY
    for pattern, category in _ENTITY_PATTERNS:
        matches = pattern.findall(content_upper)
        if matches:
            _add(category, 5.0 * min(len(matches), 5), "entity-body")
            for entity in set(matches):
                _add(entity, 5.0, "entity-body")

    # 3. Phrase patterns (bigrams/trigrams)
    full_text = f"{title} {content}"[:12000]
    for pattern, tag in _PHRASE_PATTERNS:
        if pattern.search(full_text):
            _add(tag, 4.0, "phrase")

    # 4. Topic cluster matching
    for topic, keywords in _TOPIC_CLUSTERS.items():
        # Check title first (weighted)
        title_hits = sum(1 for kw in keywords if kw in title_lower)
        body_hits = sum(1 for kw in keywords if kw in content_lower)
        total_hits = title_hits * 3 + body_hits
        if total_hits >= 2:
            _add(topic, 3.0 * min(total_hits, 8), "cluster")

    # 5. Title word boosting
    if title:
        words = re.findall(r"\b[a-zA-Z]{3,}\b", title_lower)
        for w in words:
            if w not in _STOP_WORDS and len(w) >= 3:
                _add(w, 3.0, "title")

    # 6. Positional weight — first/last 500 chars
    if len(content) > 1000:
        intro = content_lower[:500]
        outro = content_lower[-500:]
        for section in [intro, outro]:
            words = re.findall(r"\b[a-z]{4,}\b", section)
            for w in words:
                if w not in _STOP_WORDS:
                    _add(w, 2.0, "positional")

    # 7. URL signals
    if url:
        for tag in _extract_url_signals(url):
            _add(tag, 2.0, "url")

    # 8. Repeated significant words
    words = re.findall(r"\b[a-z]{4,}\b", content_lower)
    word_freq = Counter(w for w in words if w not in _STOP_WORDS)
    for word, count in word_freq.most_common(30):
        if count >= 3 and len(word) >= 5:
            _add(word, 1.0 * min(count, 10), "frequency")

    # Score boost for tags that appear in existing vault (normalization)
    if existing_tags:
        for tag in list(candidates.keys()):
            if tag in existing_tags:
                candidates[tag].score *= 1.5  # 50% boost for existing tags

    # Sort by score, return top N
    sorted_tags = sorted(candidates.values(), key=lambda c: -c.score)
    result = []
    for c in sorted_tags:
        if c.tag not in result:
            result.append(c.tag)
        if len(result) >= max_tags:
            break

    return result


def extract_tags_debug(
    content: str,
    title: str = "",
    url: str = "",
    max_tags: int = 8,
) -> list[dict]:
    """Extract tags with scoring details for debugging."""
    if not content and not title:
        return []

    candidates: dict[str, _TagCandidate] = {}

    def _add(tag: str, score: float, source: str = ""):
        tag = tag.lower().strip().replace(" ", "-")
        tag = re.sub(r"[^a-z0-9@._-]", "", tag)
        tag = re.sub(r"-+", "-", tag).strip("-")
        if not tag or len(tag) < 2 or tag in _BANNED:
            return
        if tag in candidates:
            candidates[tag].score += score
            if source:
                candidates[tag].sources.append(source)
        else:
            candidates[tag] = _TagCandidate(tag=tag, score=score, sources=[source] if source else [])

    content_upper = content[:10000] if content else ""
    content_lower = content_upper.lower()
    title_lower = title.lower() if title else ""

    if title:
        for pattern, category in _ENTITY_PATTERNS:
            if pattern.search(title):
                _add(category, 10.0, "entity-title")
                for entity in set(pattern.findall(title)):
                    _add(entity, 10.0, "entity-title")

    for pattern, category in _ENTITY_PATTERNS:
        matches = pattern.findall(content_upper)
        if matches:
            _add(category, 5.0 * min(len(matches), 5), "entity-body")
            for entity in set(matches):
                _add(entity, 5.0, "entity-body")

    full_text = f"{title} {content}"[:12000]
    for pattern, tag in _PHRASE_PATTERNS:
        if pattern.search(full_text):
            _add(tag, 4.0, "phrase")

    for topic, keywords in _TOPIC_CLUSTERS.items():
        title_hits = sum(1 for kw in keywords if kw in title_lower)
        body_hits = sum(1 for kw in keywords if kw in content_lower)
        total_hits = title_hits * 3 + body_hits
        if total_hits >= 2:
            _add(topic, 3.0 * min(total_hits, 8), "cluster")

    if title:
        words = re.findall(r"\b[a-zA-Z]{3,}\b", title_lower)
        for w in words:
            if w not in _STOP_WORDS and len(w) >= 3:
                _add(w, 3.0, "title")

    if len(content) > 1000:
        intro = content_lower[:500]
        outro = content_lower[-500:]
        for section in [intro, outro]:
            words = re.findall(r"\b[a-z]{4,}\b", section)
            for w in words:
                if w not in _STOP_WORDS:
                    _add(w, 2.0, "positional")

    if url:
        for tag in _extract_url_signals(url):
            _add(tag, 2.0, "url")

    words = re.findall(r"\b[a-z]{4,}\b", content_lower)
    word_freq = Counter(w for w in words if w not in _STOP_WORDS)
    for word, count in word_freq.most_common(30):
        if count >= 3 and len(word) >= 5:
            _add(word, 1.0 * min(count, 10), "frequency")

    sorted_tags = sorted(candidates.values(), key=lambda c: -c.score)
    return [
        {"tag": c.tag, "score": round(c.score, 1), "sources": list(set(c.sources))}
        for c in sorted_tags[:max_tags]
    ]
