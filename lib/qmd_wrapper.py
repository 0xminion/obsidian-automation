#!/usr/bin/env python3
"""QMD wrapper — daemon-first with CLI fallback.

Usage:
  qmd-search query "search text" [--collection concepts] [--limit 8] [--min-score 0.3] [--no-rerank]
  qmd-search status
  qmd-search health

Daemon: http://localhost:8181/mcp (systemd qmd-daemon.service)
Fallback: CLI subprocess (qmd query ...)
"""

import sys
import json
import os
import subprocess
import time
import argparse

DAEMON_URL = "http://localhost:8181/mcp"
TIMEOUT = int(os.environ.get("QMD_TIMEOUT", "120"))
QMD_CMD = os.environ.get("QMD_CMD", "qmd")


def strip_qmd_noise(raw_output: str) -> str:
    """Strip cmake/Vulkan build noise from qmd CLI stdout.

    qmd's underlying node-llama-cpp writes cmake errors and Vulkan warnings
    to stdout (not stderr) before the actual JSON output. This function
    finds the real JSON array start and returns clean JSON.

    Args:
        raw_output: Raw stdout from a qmd CLI command.

    Returns:
        Clean JSON string (array or empty array '[]').
    """
    for marker in ['[\n  {', '[\n{']:
        idx = raw_output.find(marker)
        if idx >= 0:
            try:
                parsed = json.loads(raw_output[idx:].rstrip())
                return json.dumps(parsed)
            except json.JSONDecodeError:
                continue
    # Fallback: try parsing entire output as-is (no noise present)
    try:
        json.loads(raw_output.strip())
        return raw_output.strip()
    except Exception:
        pass
    return '[]'


def _curl_request(payload: dict, session_id: str = "", timeout: int = TIMEOUT) -> dict:
    """Use curl for reliable MCP HTTP communication. Python urllib hangs on SSE responses."""
    import tempfile

    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(payload, f)
        payload_file = f.name

    headers = [
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json, text/event-stream",
    ]
    if session_id:
        headers.extend(["-H", f"Mcp-Session-Id: {session_id}"])

    try:
        result = subprocess.run(
            ["curl", "-s", *headers, "-d", f"@{payload_file}", DAEMON_URL],
            capture_output=True, text=True, timeout=timeout,
        )
        os.unlink(payload_file)
        if result.returncode != 0 or not result.stdout.strip():
            return {"error": {"code": -1, "message": f"curl failed: {result.stderr}"}}
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception) as e:
        try:
            os.unlink(payload_file)
        except:
            pass
        return {"error": {"code": -1, "message": str(e)}}


def _curl_init(timeout: int = 10) -> str:
    """Initialize MCP session via curl and return session ID."""
    import tempfile

    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "qmd-wrapper", "version": "2.1.0"},
        },
    })

    try:
        result = subprocess.run(
            ["curl", "-s", "-D", "-", "-H", "Content-Type: application/json",
             "-H", "Accept: application/json, text/event-stream",
             "-d", payload, DAEMON_URL],
            capture_output=True, text=True, timeout=timeout,
        )
        # Extract session ID from headers
        for line in result.stdout.split('\n'):
            if 'mcp-session-id' in line.lower():
                session_id = line.split(':', 1)[1].strip().rstrip('\r')
                if session_id and len(session_id) > 10:
                    return session_id
        return ""
    except Exception:
        return ""


def daemon_health() -> bool:
    """Check if daemon is responsive."""
    try:
        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", DAEMON_URL],
            capture_output=True, text=True, timeout=3,
        )
        return result.stdout.strip() in ("200", "400", "405")
    except Exception:
        return False


def daemon_query(query_text: str, collection: str = "concepts", limit: int = 8,
                 min_score: float = 0.3, no_rerank: bool = True) -> list:
    """Query via daemon MCP. Returns list of {file, score, snippet}.
    
    Uses vec (semantic) search — slower than lex (~95s on CPU) but provides
    semantic understanding beyond keyword matching.
    """
    session_id = _curl_init()
    if not session_id:
        return []

    # Send initialized notification
    _curl_request({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, session_id)

    # Vec search for semantic understanding
    searches = [{"type": "vec", "query": query_text}]

    result = _curl_request({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "query",
            "arguments": {
                "searches": searches,
                "collection": collection,
                "limit": limit,
                "intent": query_text[:200],
            },
        },
    }, session_id, timeout=150)

    if "error" in result:
        return []

    matches = []
    structured = result.get("result", {}).get("structuredContent", {})
    for r in structured.get("results", []):
        if r.get("score", 0) >= min_score:
            matches.append({
                "name": os.path.basename(r.get("file", "")).replace(".md", ""),
                "file": r.get("file", ""),
                "score": round(r.get("score", 0), 3),
                "snippet": r.get("snippet", "")[:200],
            })

    return matches


def cli_query(query_text: str, collection: str = "concepts", limit: int = 8,
              min_score: float = 0.3, no_rerank: bool = True) -> list:
    """Query via CLI subprocess (vec search). Returns same format as daemon_query."""
    cmd = [
        QMD_CMD, "query", query_text,
        "--json", "-n", str(limit),
        "--min-score", str(min_score),
        "-c", collection,
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)

        # Strip cmake/Vulkan noise from stdout
        stdout_clean = strip_qmd_noise(result.stdout)

        data = json.loads(stdout_clean)
        matches = []
        for r in data:
            if isinstance(r, dict) and r.get("score", 0) >= min_score:
                matches.append({
                    "name": os.path.basename(r.get("file", r.get("path", ""))).replace(".md", ""),
                    "file": r.get("file", r.get("path", "")),
                    "score": round(r.get("score", 0), 3),
                    "snippet": str(r.get("snippet", ""))[:200],
                })
        return matches
    except Exception as e:
        print(f"CLI vec query failed: {e}", file=sys.stderr)
        return []


def cli_lex_query(query_text: str, collection: str = "concepts", limit: int = 8,
                  min_score: float = 0.3) -> list:
    """Last resort: BM25 keyword search via CLI (no model inference)."""
    cmd = [
        QMD_CMD, "query", query_text,
        "--json", "-n", str(limit),
        "--min-score", str(min_score),
        "-c", collection,
        "--no-rerank",
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        stdout_clean = strip_qmd_noise(result.stdout)

        data = json.loads(stdout_clean)
        matches = []
        for r in data:
            if isinstance(r, dict) and r.get("score", 0) >= min_score:
                matches.append({
                    "name": os.path.basename(r.get("file", r.get("path", ""))).replace(".md", ""),
                    "file": r.get("file", r.get("path", "")),
                    "score": round(r.get("score", 0), 3),
                    "snippet": str(r.get("snippet", ""))[:200],
                })
        return matches
    except Exception as e:
        print(f"CLI lex query failed: {e}", file=sys.stderr)
        return []


def smart_query(query_text: str, **kwargs) -> list:
    """Priority: daemon vec → CLI vec → CLI lex (BM25 last resort)."""
    # 1. Daemon vec (semantic, ~95s, model in memory)
    if daemon_health():
        result = daemon_query(query_text, **kwargs)
        if result:
            return result

    # 2. CLI vec (semantic, ~95s, cold model load)
    result = cli_query(query_text, **kwargs)
    if result:
        return result

    # 3. CLI lex (BM25 keyword, ~46s, last resort)
    return cli_lex_query(query_text, **kwargs)


def batch_query(queries: list, **kwargs) -> dict:
    """Batch query: one daemon init, N queries. Returns {query: results}."""
    results = {}

    if daemon_health():
        session_id = _curl_init()
        if session_id:
            for q in queries:
                result = daemon_query(q, **kwargs)
                if not result:
                    result = cli_query(q, **kwargs)
                results[q] = result
            return results

    # No daemon — fall back to CLI for all
    for q in queries:
        results[q] = cli_query(q, **kwargs)
    return results


def main():
    parser = argparse.ArgumentParser(description="QMD wrapper — daemon-first with CLI fallback")
    sub = parser.add_subparsers(dest="command")

    q = sub.add_parser("query")
    q.add_argument("query_text")
    q.add_argument("--collection", "-c", default="concepts")
    q.add_argument("--limit", "-n", type=int, default=8)
    q.add_argument("--min-score", type=float, default=0.3)
    q.add_argument("--no-rerank", action="store_true", default=True)
    q.add_argument("--json", action="store_true", dest="as_json")

    sub.add_parser("status")
    sub.add_parser("health")

    args = parser.parse_args()

    if args.command == "health":
        if daemon_health():
            print("daemon:ok")
        else:
            print("daemon:down")
        sys.exit(0)

    if args.command == "status":
        r = subprocess.run([QMD_CMD, "status"], capture_output=True, text=True)
        print(r.stdout)
        sys.exit(r.returncode)

    if args.command == "query":
        result = smart_query(
            args.query_text,
            collection=args.collection,
            limit=args.limit,
            min_score=args.min_score,
            no_rerank=args.no_rerank,
        )
        if args.as_json:
            print(json.dumps(result))
        else:
            for m in result:
                print(f"{m['score']:.0%} {m['name']}")
        sys.exit(0 if result else 1)

    parser.print_help()


if __name__ == "__main__":
    main()
