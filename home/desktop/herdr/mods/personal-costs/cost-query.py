#!/usr/bin/env python3
"""Compute live token & estimated USD costs for Herdr terminals and spaces."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

# USD per 1M tokens: (input, cache_read, cache_write, output)
# Thinking/reasoning tokens bill at the output rate unless separated by provider.
PRICING = {
    "gpt-6-astra": (10.0, 1.0, 0.0, 50.0),
    "gpt-6.1-sol": (2.0, 0.10, 0.0, 10.0),
    "gpt-6-sol": (2.0, 0.10, 0.0, 10.0),
    "gpt-6.1-terra": (1.0, 0.05, 0.0, 5.0),
    "gpt-5.6-terra": (1.0, 0.05, 0.0, 5.0),
    "gpt-6-luna": (0.10, 0.01, 0.0, 0.50),
    "gpt-4o": (2.50, 1.25, 0.0, 10.0),
    "gemini-4-carbon": (2.0, 0.10, 0.0, 10.0),
    "gemini-4-argon": (2.0, 0.10, 0.0, 10.0),
    "gemini-4-hydrogen": (1.50, 0.075, 0.0, 7.50),
    "gemini-3.8-flash": (0.75, 0.075, 0.0, 3.75),
    "gemini-3.6-flash": (0.75, 0.075, 0.0, 3.75),
    "gemini-3.5-flash": (0.75, 0.075, 0.0, 3.75),
    "gemini-3.5-flash-lite": (0.30, 0.03, 0.0, 2.50),
    "gemini-3.1-pro": (2.0, 0.20, 0.0, 12.0),
    "claude-fable-5-2": (8.0, 0.20, 10.0, 40.0),
    "claude-opus-5-5": (4.0, 0.20, 5.0, 20.0),
    "claude-opus-4-8": (4.0, 0.20, 5.0, 20.0),
    "claude-sonnet-5-5": (2.0, 0.10, 2.50, 10.0),
    "claude-haiku-5-5": (0.10, 0.01, 0.125, 0.50),
    "grok-4.7": (2.20, 0.55, 0.0, 6.60),
    "grok-4.6": (2.20, 0.55, 0.0, 6.60),
}


def normalize_model(model: str | None) -> str:
    if not model:
        return ""
    m = model.strip().lower()
    if "/" in m:
        m = m.split("/")[-1]
    if m.startswith("webai-"):
        m = m[len("webai-") :]
    for suffix in ("-xhigh", "-high", "-medium", "-low", "-max"):
        if m.endswith(suffix) and m[: -len(suffix)] in PRICING:
            m = m[: -len(suffix)]
            break
    return m


def lookup_rate(model: str | None):
    m = normalize_model(model)
    if not m:
        return None
    if m.endswith("-free") or m.endswith("-local") or m.startswith("gemma-"):
        return (0.0, 0.0, 0.0, 0.0)
    if m in PRICING:
        return PRICING[m]
    for key, rate in PRICING.items():
        if m.startswith(key):
            return rate
    return None


def compute_bucket_cost(tokens: dict, rate: tuple[float, float, float, float] | None) -> float | None:
    if rate is None:
        return None
    r_in, r_cr, r_cw, r_out = rate
    return (
        tokens.get("input", 0) * r_in
        + tokens.get("cache_read", 0) * r_cr
        + tokens.get("cache_write", 0) * r_cw
        + (tokens.get("output", 0) + tokens.get("reasoning", 0)) * r_out
    ) / 1_000_000.0


def empty_tokens() -> dict[str, int]:
    return {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0, "reasoning": 0}


def add_tokens(dst: dict[str, int], src: dict[str, int]):
    for k in ("input", "cache_read", "cache_write", "output", "reasoning"):
        dst[k] += int(src.get(k, 0) or 0)


def proc_open_files(pid: int | None) -> list[str]:
    if not pid or pid <= 0:
        return []
    pids = [pid]
    # Include direct children (e.g. wrapper scripts)
    try:
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            stat_path = f"/proc/{entry}/stat"
            try:
                with open(stat_path, "r", errors="ignore") as f:
                    s = f.read()
                rparen = s.rfind(")")
                if rparen != -1:
                    ppid = int(s[rparen + 2 :].split()[1])
                    if ppid == pid:
                        pids.append(int(entry))
            except OSError:
                pass
    except OSError:
        pass

    out = []
    seen = set()
    for p in pids:
        fd_dir = f"/proc/{p}/fd"
        try:
            for fd in os.listdir(fd_dir):
                try:
                    tgt = os.readlink(f"{fd_dir}/{fd}")
                    if tgt not in seen:
                        seen.add(tgt)
                        out.append(tgt)
                except OSError:
                    pass
        except OSError:
            pass
    return out


def parse_codex_rollout(path: str) -> dict | None:
    if not os.path.isfile(path):
        return None
    current_model = ""
    session_id = ""
    prev_total = 0
    by_model: dict[str, dict[str, int]] = {}
    last_total_usage = None
    last_includes_reasoning = True

    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if '"session_meta"' in line and not session_id:
                    try:
                        rec = json.loads(line)
                        if rec.get("type") == "session_meta":
                            session_id = rec.get("payload", {}).get("id", "")
                    except Exception:
                        pass
                elif '"turn_context"' in line:
                    try:
                        rec = json.loads(line)
                        if rec.get("type") == "turn_context":
                            m = rec.get("payload", {}).get("model")
                            if m:
                                current_model = m
                    except Exception:
                        pass
                elif '"token_count"' in line:
                    try:
                        rec = json.loads(line)
                        if rec.get("type") != "event_msg":
                            continue
                        payload = rec.get("payload") or {}
                        if payload.get("type") != "token_count":
                            continue
                        info = payload.get("info") or {}
                        tot = info.get("total_token_usage") or {}
                        last = info.get("last_token_usage") or {}
                        last_includes_reasoning = bool(info.get("last_usage_includes_reasoning", True))
                        tot_tokens = int(tot.get("total_tokens", 0) or 0)
                        if tot_tokens > prev_total and last:
                            prev_total = tot_tokens
                            m = current_model or "unknown"
                            bucket = by_model.setdefault(m, empty_tokens())
                            raw_in = int(last.get("input_tokens", 0) or 0)
                            cached = int(last.get("cached_input_tokens", 0) or 0)
                            cwrite = int(last.get("cache_write_input_tokens", 0) or 0)
                            raw_out = int(last.get("output_tokens", 0) or 0)
                            reas = int(last.get("reasoning_output_tokens", 0) or 0)
                            # Codex output_tokens already includes reasoning_output_tokens when last_usage_includes_reasoning=True
                            pure_out = max(0, raw_out - reas) if last_includes_reasoning else raw_out
                            add_tokens(
                                bucket,
                                {
                                    "input": max(0, raw_in - cached),
                                    "cache_read": cached,
                                    "cache_write": cwrite,
                                    "output": pure_out,
                                    "reasoning": reas,
                                },
                            )
                        if tot:
                            last_total_usage = tot
                    except Exception:
                        pass
    except OSError:
        return None

    # Fallback if total_token_usage existed without last_token_usage deltas
    if not by_model and last_total_usage:
        m = current_model or "unknown"
        raw_in = int(last_total_usage.get("input_tokens", 0) or 0)
        cached = int(last_total_usage.get("cached_input_tokens", 0) or 0)
        cwrite = int(last_total_usage.get("cache_write_input_tokens", 0) or 0)
        raw_out = int(last_total_usage.get("output_tokens", 0) or 0)
        reas = int(last_total_usage.get("reasoning_output_tokens", 0) or 0)
        pure_out = max(0, raw_out - reas) if last_includes_reasoning else raw_out
        by_model[m] = {
            "input": max(0, raw_in - cached),
            "cache_read": cached,
            "cache_write": cwrite,
            "output": pure_out,
            "reasoning": reas,
        }

    return finalize_models("codex", session_id or Path(path).stem, current_model, by_model)


def parse_pi_session(path: str) -> dict | None:
    if not os.path.isfile(path):
        return None
    session_id = ""
    current_model = ""
    by_model: dict[str, dict[str, int]] = {}
    native_cost = 0.0
    has_native_cost = True

    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                rtype = rec.get("type")
                if rtype == "session" and not session_id:
                    session_id = rec.get("id", "")
                elif rtype == "model_change":
                    m = rec.get("modelId")
                    p = rec.get("provider")
                    if m:
                        current_model = f"{p}/{m}" if p else m
                elif rtype == "message":
                    msg = rec.get("message") or {}
                    usage = msg.get("usage")
                    if not usage:
                        continue
                    m = msg.get("model") or current_model or "unknown"
                    p = msg.get("provider")
                    full_m = f"{p}/{m}" if p and "/" not in m else m
                    current_model = full_m
                    bucket = by_model.setdefault(full_m, empty_tokens())
                    add_tokens(
                        bucket,
                        {
                            "input": int(usage.get("input", 0) or 0),
                            "cache_read": int(usage.get("cacheRead", 0) or 0),
                            "cache_write": int(usage.get("cacheWrite", 0) or 0),
                            "output": int(usage.get("output", 0) or 0),
                            "reasoning": int(usage.get("reasoning", 0) or 0),
                        },
                    )
                    cobj = usage.get("cost") or {}
                    ctot = float(cobj.get("total", 0) or 0)
                    if cobj.get("totalFromProvider") and ctot > 0:
                        native_cost += ctot
                    else:
                        has_native_cost = False
    except OSError:
        return None

    res = finalize_models("pi", session_id or Path(path).stem, current_model, by_model)
    if has_native_cost and native_cost > 0:
        res["cost"] = native_cost
        res["rateSource"] = "provider"
    return res


def find_pi_session_file(term: dict) -> str | None:
    labels = term.get("labels") or {}
    snap_raw = labels.get("herdr-preview.session")
    session_id = None
    if snap_raw:
        try:
            snap = json.loads(snap_raw)
            snap_file = snap.get("file")
            if snap_file and os.path.isfile(snap_file):
                with open(snap_file, "r", encoding="utf-8", errors="ignore") as f:
                    sdata = json.load(f)
                session_id = sdata.get("session")
        except Exception:
            pass

    pi_root = Path.home() / ".pi/agent/sessions"
    if not pi_root.is_dir():
        return None

    if session_id:
        matches = list(pi_root.glob(f"*/*_{session_id}.jsonl"))
        if matches:
            return str(matches[0])

    cwd = ((term.get("foreground") or {}).get("cwd") or term.get("cwd") or "").strip()
    if cwd:
        encoded = "--" + cwd.strip("/").replace("/", "-") + "--"
        folder = pi_root / encoded
        if folder.is_dir():
            files = sorted(folder.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
            if files:
                return str(files[0])
    return None


def open_opencode_db():
    db = Path.home() / ".local/share/opencode/opencode.db"
    if not db.is_file():
        return None
    try:
        return sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=0.5)
    except Exception:
        return None


def resolve_opencode_session(con, term: dict, claimed_ids: set[str]) -> str | None:
    labels = term.get("labels") or {}
    snap_raw = labels.get("herdr-preview.session")
    if snap_raw:
        try:
            snap = json.loads(snap_raw)
            snap_file = snap.get("file")
            if snap_file and os.path.isfile(snap_file):
                with open(snap_file, "r", encoding="utf-8", errors="ignore") as f:
                    sid = json.load(f).get("session")
                if sid:
                    return sid
        except Exception:
            pass

    title = (term.get("title") or "").strip()
    if title.startswith("OC | "):
        title = title[5:].strip()
    cwd = ((term.get("foreground") or {}).get("cwd") or term.get("cwd") or "").strip()
    created_ms = int(term.get("created_ms") or 0)

    if title and title.lower() not in ("opencode", "oc"):
        if cwd:
            rows = con.execute(
                "SELECT id FROM session_v2 WHERE directory = ? AND title = ? ORDER BY time_updated DESC LIMIT 5",
                (cwd, title),
            ).fetchall()
            for (sid,) in rows:
                if sid not in claimed_ids:
                    return sid
        rows = con.execute(
            "SELECT id FROM session_v2 WHERE title = ? ORDER BY time_updated DESC LIMIT 5",
            (title,),
        ).fetchall()
        for (sid,) in rows:
            if sid not in claimed_ids:
                return sid

    if cwd:
        rows = con.execute(
            "SELECT id FROM session_v2 WHERE directory = ? AND time_updated >= ? ORDER BY time_updated DESC LIMIT 10",
            (cwd, max(0, created_ms - 5000)),
        ).fetchall()
        for (sid,) in rows:
            if sid not in claimed_ids:
                return sid
    return None


def parse_opencode_session(con, sid: str) -> dict | None:
    row = con.execute(
        """
        SELECT id, title, cost, tokens_input, tokens_output, tokens_reasoning,
               tokens_cache_read, tokens_cache_write, model
        FROM session_v2 WHERE id = ?
        """,
        (sid,),
    ).fetchone()
    if not row:
        return None

    _, _, native_cost, s_in, s_out, s_reas, s_cr, s_cw, s_model_raw = row
    default_model = ""
    if s_model_raw:
        try:
            mobj = json.loads(s_model_raw)
            pid = mobj.get("providerID", "")
            mid = mobj.get("id", "")
            default_model = f"{pid}/{mid}" if pid and mid else mid
        except Exception:
            pass

    by_model: dict[str, dict[str, int]] = {}
    msgs = con.execute("SELECT data FROM session_message WHERE session_id = ? ORDER BY seq", (sid,)).fetchall()
    for (raw,) in msgs:
        try:
            d = json.loads(raw)
        except Exception:
            continue
        toks = d.get("tokens")
        if not toks:
            continue
        mobj = d.get("model") or {}
        pid = mobj.get("providerID", "")
        mid = mobj.get("id", "")
        model = f"{pid}/{mid}" if pid and mid else (mid or default_model or "unknown")
        bucket = by_model.setdefault(model, empty_tokens())
        cache = toks.get("cache") or {}
        add_tokens(
            bucket,
            {
                "input": int(toks.get("input", 0) or 0),
                "cache_read": int(cache.get("read", 0) or 0),
                "cache_write": int(cache.get("write", 0) or 0),
                "output": int(toks.get("output", 0) or 0),
                "reasoning": int(toks.get("reasoning", 0) or 0),
            },
        )

    if not by_model and any((s_in, s_out, s_reas, s_cr, s_cw)):
        by_model[default_model or "unknown"] = {
            "input": int(s_in or 0),
            "cache_read": int(s_cr or 0),
            "cache_write": int(s_cw or 0),
            "output": int(s_out or 0),
            "reasoning": int(s_reas or 0),
        }

    res = finalize_models("opencode", sid, default_model, by_model)
    if native_cost and float(native_cost) > 0:
        res["cost"] = float(native_cost)
        res["rateSource"] = "opencode"
    return res


def finalize_models(harness: str, session_id: str, primary_model: str, by_model: dict[str, dict[str, int]]) -> dict:
    totals = empty_tokens()
    total_cost = 0.0
    all_priced = bool(by_model)
    last_model = primary_model
    for model, toks in by_model.items():
        add_tokens(totals, toks)
        last_model = model
        rate = lookup_rate(model)
        c = compute_bucket_cost(toks, rate)
        if c is None:
            all_priced = False
        else:
            total_cost += c

    if not by_model:
        all_priced = False

    return {
        "harness": harness,
        "sessionId": session_id,
        "model": normalize_model(last_model) or last_model or "unknown",
        "tokens": totals,
        "totalTokens": sum(totals.values()),
        "cost": round(total_cost, 6) if all_priced else None,
        "billing": "api" if all_priced else ("unpriced" if by_model else "empty"),
        "rateSource": "estimated" if all_priced else None,
    }


CACHE_PATH = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "herdr-costs-cache.json"


def load_cache() -> dict:
    try:
        if CACHE_PATH.is_file():
            with open(CACHE_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data if isinstance(data, dict) else {}
    except Exception:
        pass
    return {}


def save_cache(cache: dict):
    try:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        # Keep cache bounded to recent 200 files
        if len(cache) > 200:
            items = sorted(cache.items(), key=lambda kv: kv[1].get("mtime", 0), reverse=True)[:150]
            cache = dict(items)
        tmp = f"{CACHE_PATH}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE_PATH)
    except Exception:
        pass


def parse_file_cached(path: str, parser, cache: dict) -> dict | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    entry = cache.get(path)
    if entry and entry.get("mtime") == st.st_mtime_ns and entry.get("size") == st.st_size:
        return entry.get("data")
    parsed = parser(path)
    if parsed is not None:
        cache[path] = {"mtime": st.st_mtime_ns, "size": st.st_size, "data": parsed}
    return parsed


def proc_cmdline(pid: int | None) -> str:
    if not pid or pid <= 0:
        return ""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().replace(b"\x00", b" ").decode("utf-8", "ignore")
    except OSError:
        return ""


def match_harness_text(text: str) -> str:
    if not text:
        return ""
    if "codex" in text:
        return "codex"
    if "opencode" in text:
        return "opencode"
    if "cursor" in text:
        return "cursor"
    if "claude" in text:
        return "claude"
    if re.search(r"(?:^|/|\s)pi(?:\s|$)", text):
        return "pi"
    return ""


def detect_harness(term: dict) -> str:
    app = (term.get("app") or (term.get("report") or {}).get("app") or "").lower()
    prog_key = ((term.get("program") or {}).get("key") or "").lower()
    fg_argv = (term.get("foreground") or {}).get("argv") or []
    fg_bin = (fg_argv[0] if fg_argv else "").lower()
    fg_name = ((term.get("foreground") or {}).get("name") or "").lower()
    argv0 = ((term.get("argv") or [""])[0] or "").lower()
    for candidate in (app, prog_key, fg_bin, fg_name, argv0):
        h = match_harness_text(candidate)
        if h:
            return h
    pid = (term.get("foreground") or {}).get("pid") or term.get("pid")
    cmd = proc_cmdline(pid).lower()
    cmd0 = cmd.split()[0] if cmd.split() else ""
    return match_harness_text(cmd0) or match_harness_text(cmd)


def enrich_terminal(term: dict) -> dict:
    fg = term.get("foreground") or {}
    if fg.get("pid") or term.get("pid"):
        return term
    addr = term.get("address")
    if not addr or "/" in addr:
        return term
    try:
        out = subprocess.check_output(["hc", "get", addr], text=True, timeout=1.5)
        full = json.loads(out)
        merged = {**term, **full}
        if term.get("program") and not full.get("program"):
            merged["program"] = term["program"]
        return merged
    except Exception:
        return term


def main():
    payload = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    raw_terms = [t for t in (payload.get("terminals") or []) if t.get("address") and t.get("state") == "live"]

    with ThreadPoolExecutor(max_workers=8) as pool:
        terms = list(pool.map(enrich_terminal, raw_terms))

    oc_con = open_opencode_db()
    claimed_oc: set[str] = set()
    results = {}
    cache = load_cache()
    cache_before = json.dumps(cache, sort_keys=True)

    try:
        for term in terms:
            addr = term.get("address")
            if not addr:
                continue
            harness = detect_harness(term)
            if not harness:
                continue

            if harness == "cursor":
                pid = (term.get("foreground") or {}).get("pid") or term.get("pid")
                cmd = proc_cmdline(pid)
                m = re.search(r"--model\s+(\S+)", cmd)
                results[addr] = {
                    "harness": "cursor",
                    "model": m.group(1) if m else "subscription",
                    "tokens": empty_tokens(),
                    "totalTokens": 0,
                    "cost": None,
                    "billing": "subscription",
                }
                continue

            if harness == "codex":
                pid = (term.get("foreground") or {}).get("pid") or term.get("pid")
                files = [f for f in proc_open_files(pid) if re.search(r"[/\\]rollout-[^/\\]+\.jsonl$", f)]
                if files:
                    parsed = parse_file_cached(files[0], parse_codex_rollout, cache)
                    if parsed:
                        results[addr] = parsed
                continue

            if harness == "pi":
                pfile = find_pi_session_file(term)
                if pfile:
                    parsed = parse_file_cached(pfile, parse_pi_session, cache)
                    if parsed:
                        results[addr] = parsed
                continue

            if harness == "opencode" and oc_con is not None:
                sid = resolve_opencode_session(oc_con, term, claimed_oc)
                if sid:
                    claimed_oc.add(sid)
                    parsed = parse_opencode_session(oc_con, sid)
                    if parsed:
                        results[addr] = parsed
                continue
    finally:
        if oc_con is not None:
            oc_con.close()
        if json.dumps(cache, sort_keys=True) != cache_before:
            save_cache(cache)

    print(json.dumps({"agents": results}))


if __name__ == "__main__":
    main()
