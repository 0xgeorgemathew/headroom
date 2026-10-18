#!/usr/bin/env python3
"""Reference parser for Headroom's log ingestion (parity check, PLAN §11 lane 1c).

Fully JSON-decodes every candidate line with the same normalization and dedupe rules as the
Swift ingestor, then prints token totals per provider / model / UTC day. Read-only: it never
writes into ~/.claude or ~/.codex.

Usage: reference_parser.py --cutoff <epoch-seconds> [--home DIR]
Compare with: HeadroomBench scan --cutoff <same epoch>
"""
import argparse
import collections
import datetime
import glob
import json
import os
import subprocess
import sys


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def decompress(path):
    try:
        from compression import zstd  # Python 3.14+
        with open(path, "rb") as f:
            return zstd.decompress(f.read())
    except ImportError:
        return subprocess.run(["zstd", "-dc", path], capture_output=True, check=True).stdout


def last_component(p):
    if not p:
        return None
    p = p.rstrip("/")
    return p.rsplit("/", 1)[-1] or None


class Ledger:
    """key -> (ts, path, provider, model, tokens). Same file: last wins; across files the later
    timestamp wins and the larger path breaks ties."""

    def __init__(self):
        self.entries = {}

    def add(self, key, ts, path, provider, model, tokens):
        old = self.entries.get(key)
        if old is not None and old[1] != path:
            if ts < old[0] or (ts == old[0] and path < old[1]):
                return
        self.entries[key] = (ts, path, provider, model, tokens)

    def retract(self, keys):
        for k in keys:
            self.entries.pop(k, None)


def claude_tokens(u):
    inp = u.get("input_tokens") or 0
    creation = u.get("cache_creation_input_tokens") or 0
    read = u.get("cache_read_input_tokens") or 0
    out = u.get("output_tokens") or 0
    cc = u.get("cache_creation")
    w5, w1 = creation, 0
    if isinstance(cc, dict) and ("ephemeral_5m_input_tokens" in cc or "ephemeral_1h_input_tokens" in cc):
        w1 = max(cc.get("ephemeral_1h_input_tokens") or 0, 0)
        w5 = max(cc.get("ephemeral_5m_input_tokens") or 0, 0)
        if w5 + w1 < creation:
            w5 = creation - w1
    return (max(inp, 0), max(w5, 0), w1, max(read, 0), max(out, 0))


def scan_claude(path, ledger):
    with open(path, "rb") as f:
        data = f.read()
    # Mirror the tailer: a trailing partial line is not consumed.
    end = data.rfind(b"\n") + 1
    offset = 0
    for raw in data[:end].split(b"\n"):
        line_start = offset
        offset += len(raw) + 1
        if b'"usage":{' not in raw or b'"type":"assistant"' not in raw:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "assistant":
            continue
        m = d.get("message") or {}
        u = m.get("usage")
        ts = parse_ts(d.get("timestamp"))
        if not isinstance(u, dict) or ts is None:
            continue
        tokens = claude_tokens(u)
        if sum(tokens) == 0:
            continue
        mid, rid = m.get("id"), d.get("requestId")
        if mid is not None:
            key = f"{mid}:{rid}" if rid is not None else mid
        else:
            key = f"@{path}:{line_start}"
        ledger.add(key, ts, path, "claude", m.get("model") or "unknown", tokens)


def codex_tokens(u):
    inp = u.get("input_tokens") or 0
    cached = u.get("cached_input_tokens") or 0
    write = u.get("cache_write_input_tokens") or 0
    out = u.get("output_tokens") or 0
    return (max(inp - cached - write, 0), max(write, 0), 0, max(cached, 0), max(out, 0))


def scan_codex(path, logical, ledger, final):
    data = decompress(path) if path.endswith(".zst") else open(path, "rb").read()
    if not final:
        data = data[: data.rfind(b"\n") + 1]
    model = None
    saw_record = False
    legacy_keys = []
    last_total = None
    legacy_count = 0
    for raw in data.split(b"\n"):
        head = raw[:160]
        if not any(t in head for t in (b'"type":"token_usage_record"', b'"type":"event_msg"',
                                       b'"type":"session_meta"', b'"type":"turn_context"')):
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        t = d.get("type")
        p = d.get("payload") or {}
        ts = parse_ts(d.get("timestamp"))
        if t == "turn_context":
            if p.get("model"):
                model = p["model"]
        elif t == "token_usage_record" and ts is not None:
            u = p.get("usage")
            if not isinstance(u, dict):
                continue
            rid = p.get("response_id")
            key = f"R:{rid}" if rid is not None else f"R@{logical}:{ts}"
            if not saw_record:
                saw_record = True
                ledger.retract(legacy_keys)
                legacy_keys = []
            ledger.add(key, ts, logical, "codex", model or "unknown", codex_tokens(u))
        elif t == "event_msg" and p.get("type") == "token_count" and ts is not None and not saw_record:
            info = p.get("info")
            if not isinstance(info, dict):
                continue
            total = info.get("total_token_usage")
            tkey = None
            if isinstance(total, dict):
                tkey = (total.get("input_tokens") or 0, total.get("cached_input_tokens") or 0,
                        total.get("output_tokens") or 0, total.get("total_tokens") or 0)
            last = info.get("last_token_usage")
            if tkey is not None and tkey == last_total:
                pass
            elif isinstance(last, dict):
                tokens = codex_tokens(last)
                if sum(tokens) > 0:
                    legacy_count += 1
                    key = f"L:{logical}#{legacy_count}"
                    legacy_keys.append(key)
                    ledger.add(key, ts, logical, "codex", model or "unknown", tokens)
            if tkey is not None:
                last_total = tkey


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cutoff", type=float, required=True)
    ap.add_argument("--home", default=os.path.expanduser("~"))
    args = ap.parse_args()
    ledger = Ledger()

    claude = sorted(glob.glob(os.path.join(args.home, ".claude/projects/**/*.jsonl"), recursive=True))
    for path in claude:
        if os.path.getmtime(path) >= args.cutoff:
            scan_claude(path, ledger)

    codex = []
    for root in (".codex/sessions", ".codex/archived_sessions"):
        codex += glob.glob(os.path.join(args.home, root, "**/*.jsonl"), recursive=True)
        codex += glob.glob(os.path.join(args.home, root, "**/*.jsonl.zst"), recursive=True)
    plain = {p for p in codex if not p.endswith(".zst")}
    for path in sorted(codex):
        if path.endswith(".zst") and path[:-4] in plain:
            continue
        if os.path.getmtime(path) < args.cutoff:
            continue
        logical = path[:-4] if path.endswith(".zst") else path
        scan_codex(path, logical, ledger, final=path.endswith(".zst"))

    totals = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0])
    for ts, _path, provider, model, tokens in ledger.entries.values():
        if ts < args.cutoff:
            continue
        day = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")
        row = totals[(provider, model, day)]
        for i, v in enumerate(tokens):
            row[i] += v
        row[5] += 1
    grand = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0])
    for (provider, model, day), row in sorted(totals.items()):
        print(provider, model, day, *row)
        for i, v in enumerate(row):
            grand[provider][i] += v
    for provider, row in sorted(grand.items()):
        print("TOTAL", provider, *row, file=sys.stderr)


if __name__ == "__main__":
    main()
