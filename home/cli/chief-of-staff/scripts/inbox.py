#!/usr/bin/env python3
"""Stateless bounded worker-report spooler and read-only coordinator digest for chief-of-staff."""

import argparse
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time

import work

VERSION = 1
MAX_PACKET_FILE_BYTES = 64 * 1024
MAX_STORED_TEXT_CHARS = 4000
MAX_STORED_PATHS = 128
MAX_PREVIEW_SUMMARY_CHARS = 320
MAX_PREVIEW_FIELD_CHARS = 240
MAX_PREVIEW_PATHS = 16
MAX_SCAN_FILES = 4096
MAX_TOKEN_VALUE = 10**12
MAX_COST_USD = 10**6

REPORT_KINDS = ("progress", "done", "question", "blocker", "error")
ACTIONABLE_PRIORITY = {"question": 0, "blocker": 1, "error": 2, "done": 3}

ANSI_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
ANSI_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
TEMP_FILE_RE = re.compile(r"\A\.tmp-\d+-[0-9a-f]{16}\.json\Z")


class InboxError(work.RecordError):
    pass


def _reject_nonfinite_json(token: str):
    raise ValueError(f"Non-finite JSON constant rejected: {token}")


def encode_json(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n"


def sha256_hex(payload: str) -> str:
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def safe_id_token(terminal: str) -> str:
    """Encode 'machine/t3' as 'machine:t3' for work.ID strings without changing logical terminal."""
    return terminal.replace("/", ":")


def encode_terminal_fs(terminal: str | None) -> str:
    """Bijective traversal-free filename token for logical terminal ('vps/t3' -> 'vps@t3')."""
    if not terminal:
        return "unassigned"
    return terminal.replace("/", "@")


def strip_terminal_escapes(raw: str) -> str:
    cleaned = ANSI_OSC_RE.sub("", raw or "")
    cleaned = ANSI_CSI_RE.sub("", cleaned)
    return cleaned.replace("\r\n", "\n").replace("\r", "\n")


def sanitize_text(raw: str, *, limit: int, allow_empty: bool = False) -> tuple[str, bool, int]:
    if not isinstance(raw, str):
        raise InboxError("Expected text string")
    orig_bytes = len(raw.encode("utf-8"))
    cleaned = strip_terminal_escapes(raw)
    cleaned = "".join(" " if ord(ch) < 32 or ord(ch) == 127 else ch for ch in cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        if allow_empty:
            return "", False, orig_bytes
        raise InboxError("Expected non-empty text after control-character stripping")
    if len(cleaned) > limit:
        return cleaned[: limit - 1].rstrip() + "…", True, orig_bytes
    return cleaned, False, orig_bytes


def preview_text(stored: str, *, limit: int) -> tuple[str, bool]:
    if len(stored) <= limit:
        return stored, False
    return stored[: limit - 1].rstrip() + "…", True


def normalize_usage_for_write(raw_usage: dict | None) -> dict:
    src = raw_usage or {}
    out: dict = {}
    for field in ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens"):
        val = src.get(field)
        if val is None or val == "unknown":
            out[field] = "unknown"
        elif type(val) is int and 0 <= val <= MAX_TOKEN_VALUE:
            out[field] = val
        else:
            raise InboxError(f"{field} must be a non-negative finite integer <= {MAX_TOKEN_VALUE}")

    cost_val = src.get("api_cost_usd")
    if cost_val is None or cost_val == "unknown":
        out["api_cost_usd"] = "unknown"
    elif isinstance(cost_val, (int, float)) and not isinstance(cost_val, bool) and math.isfinite(cost_val) and 0.0 <= float(cost_val) <= MAX_COST_USD:
        out["api_cost_usd"] = round(float(cost_val), 6)
    else:
        raise InboxError(f"api_cost_usd must be a non-negative finite number <= {MAX_COST_USD}")

    cs = src.get("cost_source")
    if cs is None or cs == "" or cs == "unknown":
        out["cost_source"] = "unknown"
    else:
        clean_cs, _, _ = sanitize_text(str(cs), limit=80)
        out["cost_source"] = clean_cs
    return out


def validate_stored_usage(raw_usage: object) -> dict:
    if not isinstance(raw_usage, dict):
        raise ValueError("usage must be an object")
    expected_keys = {"input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "api_cost_usd", "cost_source"}
    if set(raw_usage.keys()) != expected_keys:
        raise ValueError("unexpected usage keys")
    return normalize_usage_for_write(raw_usage)


def _has_portfolio_marker_nofollow(portfolio_root: Path) -> bool:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    odir = getattr(os, "O_DIRECTORY", 0)
    try:
        p_fd = os.open(portfolio_root, os.O_RDONLY | odir)
    except OSError:
        return False
    try:
        try:
            m_fd = os.open("portfolio.md", os.O_RDONLY | nofollow, dir_fd=p_fd)
            try:
                return stat.S_ISREG(os.fstat(m_fd).st_mode)
            finally:
                os.close(m_fd)
        except OSError:
            pass
        try:
            w_fd = os.open("work", os.O_RDONLY | odir | nofollow, dir_fd=p_fd)
            try:
                r_fd = os.open("registration.json", os.O_RDONLY | nofollow, dir_fd=w_fd)
                try:
                    return stat.S_ISREG(os.fstat(r_fd).st_mode)
                finally:
                    os.close(r_fd)
            finally:
                os.close(w_fd)
        except OSError:
            return False
    finally:
        os.close(p_fd)


def resolve_trusted_portfolio(portfolio_arg: Path) -> Path:
    if not portfolio_arg.is_absolute() or ".." in portfolio_arg.parts or "." in portfolio_arg.parts[1:]:
        raise InboxError("Portfolio path must be a normalized absolute path without '..'")
    try:
        st_arg = os.lstat(portfolio_arg)
    except OSError as exc:
        raise InboxError(f"Portfolio path does not exist: {portfolio_arg}") from exc
    if stat.S_ISLNK(st_arg.st_mode):
        raise InboxError(f"Symlink portfolio path rejected: {portfolio_arg}")
    cand = portfolio_arg.parent if (stat.S_ISREG(st_arg.st_mode) and portfolio_arg.name == "portfolio.md") else portfolio_arg
    try:
        if stat.S_ISLNK(os.lstat(cand).st_mode):
            raise InboxError(f"Symlink portfolio directory rejected: {cand}")
    except OSError as exc:
        raise InboxError(f"Portfolio directory inaccessible: {cand}") from exc
    resolved = cand.resolve()
    if not resolved.is_dir() or not _has_portfolio_marker_nofollow(resolved):
        raise InboxError(f"Not a valid chief-of-staff portfolio directory: {portfolio_arg}")
    return resolved


def _resolve_worker_artifact_target(artifact_dir: Path, task_id: str) -> tuple[Path, Path]:
    """Verify --artifact-dir is lexically <portfolio>/artifacts/<task_id> with no symlink components inside <portfolio>."""
    if not artifact_dir.is_absolute() or ".." in artifact_dir.parts or "." in artifact_dir.parts[1:]:
        raise InboxError("--artifact-dir must be a normalized absolute path without '..'")
    if len(artifact_dir.parts) < 4 or artifact_dir.name != task_id or artifact_dir.parent.name != "artifacts":
        raise InboxError("--artifact-dir must be <portfolio>/artifacts/<task> matching --task")

    portfolio_lexical = artifact_dir.parent.parent
    try:
        st_p = os.lstat(portfolio_lexical)
    except OSError as exc:
        raise InboxError(f"Portfolio parent does not exist: {portfolio_lexical}") from exc
    if stat.S_ISLNK(st_p.st_mode):
        raise InboxError("Portfolio directory itself must not be a symlink")
    portfolio_root = resolve_trusted_portfolio(portfolio_lexical)
    canonical_target = portfolio_root / "artifacts" / task_id
    return portfolio_root, canonical_target


def _mkdir_and_open_nofollow(parent_fd: int, name: str) -> int:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    odir = getattr(os, "O_DIRECTORY", 0)
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    except OSError as exc:
        raise InboxError(f"Cannot create directory component '{name}': {exc}") from exc
    try:
        fd = os.open(name, os.O_RDONLY | odir | nofollow, dir_fd=parent_fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise InboxError(f"Symlink or non-directory component rejected: {name}") from exc
        raise InboxError(f"Cannot open directory component '{name}': {exc}") from exc
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        raise InboxError(f"Component is not a directory: {name}")
    return fd


def _read_regular_in_dir_fd(dir_fd: int, fname: str, *, max_bytes: int = MAX_PACKET_FILE_BYTES) -> tuple[str | None, str | None, int]:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    fd = None
    try:
        fd = os.open(fname, os.O_RDONLY | nofollow, dir_fd=dir_fd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, "not_regular_file", 0
        raw = os.read(fd, max_bytes + 1)
        if len(raw) > max_bytes:
            return None, "oversized_packet", int(st.st_size)
        return raw.decode("utf-8"), None, len(raw)
    except FileNotFoundError:
        return None, "not_found", 0
    except UnicodeDecodeError:
        return None, "invalid_utf8", 0
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EISDIR):
            return None, "symlink_or_directory_rejected", 0
        return None, f"open_error_{exc.errno}", 0
    finally:
        if fd is not None:
            os.close(fd)


def _packet_semantic_core(pkt: dict) -> dict:
    return {
        "version": pkt.get("version"),
        "id": pkt.get("id"),
        "task": pkt.get("task"),
        "terminal": pkt.get("terminal"),
        "kind": pkt.get("kind"),
        "summary": pkt.get("summary"),
        "summary_truncated": pkt.get("summary_truncated"),
        "summary_original_bytes": pkt.get("summary_original_bytes"),
        "changed_paths": pkt.get("changed_paths"),
        "changed_paths_omitted": pkt.get("changed_paths_omitted"),
        "checks": pkt.get("checks"),
        "checks_truncated": pkt.get("checks_truncated"),
        "checks_original_bytes": pkt.get("checks_original_bytes"),
        "concerns": pkt.get("concerns"),
        "concerns_truncated": pkt.get("concerns_truncated"),
        "concerns_original_bytes": pkt.get("concerns_original_bytes"),
        "usage": pkt.get("usage"),
    }


def _format_send_line(task_id: str, kind: str, rid: str, pkt_path: Path, summary: str) -> str | None:
    if kind == "progress":
        return None
    short_sum, _ = preview_text(summary, limit=96)
    return f"[{task_id} {kind} id={rid}] {short_sum} (packet: {pkt_path})"


def write_worker_report(
    *,
    artifact_dir: Path,
    task_id: str,
    kind: str,
    summary: str,
    packet_id: str | None = None,
    terminal: str | None = None,
    changed_paths: list[str] | None = None,
    checks_summary: str = "",
    concerns: str = "",
    usage: dict | None = None,
    at: str | None = None,
) -> dict:
    work.identifier(task_id, "task")
    if kind not in REPORT_KINDS:
        raise InboxError(f"kind must be one of {REPORT_KINDS}")
    term = terminal if terminal is not None else ((os.environ.get("HC_TERMINAL_ID") or "").strip() or None)
    if term is not None and not work.TERMINAL.fullmatch(term):
        raise InboxError("terminal must be a valid Herdr terminal address (e.g. t2 or machine/t3)")

    portfolio_root, canonical_task_dir = _resolve_worker_artifact_target(artifact_dir, task_id)

    clean_summary, sum_trunc, sum_bytes = sanitize_text(summary, limit=MAX_STORED_TEXT_CHARS)
    clean_checks, chk_trunc, chk_bytes = sanitize_text(checks_summary, limit=MAX_STORED_TEXT_CHARS, allow_empty=True)
    clean_concerns, con_trunc, con_bytes = sanitize_text(concerns, limit=MAX_STORED_TEXT_CHARS, allow_empty=True)

    raw_paths = list(changed_paths or [])
    kept_paths = []
    any_path_trunc = False
    for raw_p in raw_paths[:MAX_STORED_PATHS]:
        cp, p_trunc, _ = sanitize_text(raw_p, limit=240)
        kept_paths.append(cp)
        any_path_trunc = any_path_trunc or p_trunc
    paths_omitted = max(0, len(raw_paths) - len(kept_paths))

    norm_usage = normalize_usage_for_write(usage)
    now_iso = at or work.utc_now()
    created_ns = time.time_ns()

    explicit_id = packet_id is not None
    if explicit_id:
        rid = work.identifier(packet_id, "id")
        final_fname = f"id--{rid}.json"
    else:
        rand_hex = os.urandom(4).hex()
        prefix_raw = f"{task_id}-{safe_id_token(term)}" if term else task_id
        prefix = re.sub(r"[^A-Za-z0-9._:-]+", "-", prefix_raw)[:48].rstrip("-") or task_id[:48]
        rid = work.identifier(f"{prefix}-{created_ns:016x}-{rand_hex}", "id")
        final_fname = f"auto--{encode_terminal_fs(term)}--{created_ns:020d}--{rand_hex}.json"

    truncated_at_write = bool(sum_trunc or chk_trunc or con_trunc or any_path_trunc or paths_omitted > 0)
    packet = {
        "version": VERSION,
        "id": rid,
        "task": task_id,
        "terminal": term,
        "kind": kind,
        "at": now_iso,
        "created_ns": created_ns,
        "untrusted": True,
        "summary": clean_summary,
        "summary_truncated": sum_trunc,
        "summary_original_bytes": sum_bytes,
        "changed_paths": kept_paths,
        "changed_paths_omitted": paths_omitted,
        "checks": clean_checks,
        "checks_truncated": chk_trunc,
        "checks_original_bytes": chk_bytes,
        "concerns": clean_concerns,
        "concerns_truncated": con_trunc,
        "concerns_original_bytes": con_bytes,
        "truncated_at_write": truncated_at_write,
        "usage": norm_usage,
    }
    encoded_bytes = encode_json(packet).encode("utf-8")
    if len(encoded_bytes) > MAX_PACKET_FILE_BYTES:
        raise InboxError("Serialized report packet exceeds 64 KiB bound")

    nofollow = getattr(os, "O_NOFOLLOW", 0)
    odir = getattr(os, "O_DIRECTORY", 0)
    p_fd = os.open(portfolio_root, os.O_RDONLY | odir)
    art_fd = None
    task_fd = None
    pkts_fd = None
    try:
        art_fd = _mkdir_and_open_nofollow(p_fd, "artifacts")
        task_fd = _mkdir_and_open_nofollow(art_fd, task_id)
        pkts_fd = _mkdir_and_open_nofollow(task_fd, "packets")

        while True:
            tmp_name = f".tmp-{os.getpid()}-{os.urandom(8).hex()}.json"
            tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600, dir_fd=pkts_fd)
            try:
                with os.fdopen(tmp_fd, "wb") as stream:
                    stream.write(encoded_bytes)
                    stream.flush()
                    os.fsync(stream.fileno())
                try:
                    os.link(tmp_name, final_fname, src_dir_fd=pkts_fd, dst_dir_fd=pkts_fd)
                    os.fsync(pkts_fd)
                    status = "recorded"
                    final_pkt = packet
                    break
                except FileExistsError:
                    if not explicit_id:
                        created_ns = time.time_ns()
                        rand_hex = os.urandom(4).hex()
                        rid = work.identifier(f"{prefix}-{created_ns:016x}-{rand_hex}", "id")
                        packet["id"] = rid
                        packet["created_ns"] = created_ns
                        encoded_bytes = encode_json(packet).encode("utf-8")
                        final_fname = f"auto--{encode_terminal_fs(term)}--{created_ns:020d}--{rand_hex}.json"
                        continue
                    existing_text, r_err, _ = _read_regular_in_dir_fd(pkts_fd, final_fname)
                    if r_err is not None or existing_text is None:
                        raise InboxError(f"Existing report '{rid}' could not be verified ({r_err})")
                    try:
                        existing_pkt = json.loads(existing_text, parse_constant=_reject_nonfinite_json)
                    except ValueError as exc:
                        raise InboxError(f"Existing report '{rid}' contains invalid JSON") from exc
                    if not isinstance(existing_pkt, dict) or _packet_semantic_core(existing_pkt) != _packet_semantic_core(packet):
                        raise InboxError(f"Report ID {rid} already exists with different content")
                    status = "duplicate"
                    final_pkt = existing_pkt
                    break
            finally:
                try:
                    os.unlink(tmp_name, dir_fd=pkts_fd)
                except FileNotFoundError:
                    pass
    finally:
        for fd_item in (pkts_fd, task_fd, art_fd, p_fd):
            if fd_item is not None:
                os.close(fd_item)

    pkt_path = canonical_task_dir / "packets" / final_fname
    notify = kind != "progress"
    send_line = _format_send_line(task_id, kind, final_pkt["id"], pkt_path, final_pkt["summary"])
    return {
        "status": status,
        "packet_id": final_pkt["id"],
        "packet_path": str(pkt_path),
        "notify_coordinator": notify,
        "truncated_at_write": bool(final_pkt.get("truncated_at_write", False)),
        "send_line": send_line,
    }


def _validate_packet_dict(raw: object, *, fname: str) -> dict:
    if not isinstance(raw, dict) or raw.get("version") != VERSION:
        raise ValueError("invalid_packet_version")
    rid = raw.get("id")
    tid = raw.get("task")
    if not isinstance(rid, str) or not work.ID.fullmatch(rid):
        raise ValueError("invalid_report_id")
    if fname.startswith("id--") and fname.endswith(".json") and fname[4:-5] != rid:
        raise ValueError("filename_id_mismatch")
    if not isinstance(tid, str) or not work.ID.fullmatch(tid):
        raise ValueError("invalid_task_id")
    term = raw.get("terminal")
    if term is not None and (not isinstance(term, str) or not work.TERMINAL.fullmatch(term)):
        raise ValueError("invalid_terminal")
    kind = raw.get("kind")
    if kind not in REPORT_KINDS:
        raise ValueError("invalid_kind")
    created_ns = raw.get("created_ns")
    if type(created_ns) is not int or created_ns < 0:
        raise ValueError("invalid_created_ns")
    at_val = raw.get("at")
    if not isinstance(at_val, str) or not at_val:
        raise ValueError("invalid_timestamp")

    clean_sum, s_tr, _ = sanitize_text(raw.get("summary"), limit=MAX_STORED_TEXT_CHARS)
    clean_chk, c_tr, _ = sanitize_text(raw.get("checks", ""), limit=MAX_STORED_TEXT_CHARS, allow_empty=True)
    clean_con, n_tr, _ = sanitize_text(raw.get("concerns", ""), limit=MAX_STORED_TEXT_CHARS, allow_empty=True)

    cpaths_raw = raw.get("changed_paths")
    if not isinstance(cpaths_raw, list) or len(cpaths_raw) > MAX_STORED_PATHS:
        raise ValueError("invalid_changed_paths")
    clean_paths = [sanitize_text(p, limit=240)[0] for p in cpaths_raw]
    paths_omitted = raw.get("changed_paths_omitted", 0)
    if type(paths_omitted) is not int or paths_omitted < 0:
        raise ValueError("invalid_changed_paths_omitted")

    norm_usage = validate_stored_usage(raw.get("usage"))
    trunc_write = bool(
        raw.get("truncated_at_write")
        or raw.get("summary_truncated")
        or raw.get("checks_truncated")
        or raw.get("concerns_truncated")
        or s_tr
        or c_tr
        or n_tr
        or paths_omitted > 0
    )
    return {
        "id": rid,
        "task": tid,
        "terminal": term,
        "kind": kind,
        "at": at_val,
        "created_ns": created_ns,
        "summary": clean_sum,
        "checks": clean_chk,
        "concerns": clean_con,
        "changed_paths": clean_paths,
        "changed_paths_omitted": paths_omitted,
        "truncated_at_write": trunc_write,
        "original_bytes": {
            "summary": raw.get("summary_original_bytes") if type(raw.get("summary_original_bytes")) is int else len(clean_sum.encode("utf-8")),
            "checks": raw.get("checks_original_bytes") if type(raw.get("checks_original_bytes")) is int else len(clean_chk.encode("utf-8")),
            "concerns": raw.get("concerns_original_bytes") if type(raw.get("concerns_original_bytes")) is int else len(clean_con.encode("utf-8")),
        },
        "usage": norm_usage,
    }


def _open_readonly_subdir_nofollow(parent_fd: int, name: str) -> tuple[int | None, str | None]:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    odir = getattr(os, "O_DIRECTORY", 0)
    try:
        fd = os.open(name, os.O_RDONLY | odir | nofollow, dir_fd=parent_fd)
    except FileNotFoundError:
        return None, "not_found"
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            return None, "symlink_or_not_directory"
        return None, f"open_error_{exc.errno}"
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        return None, "symlink_or_not_directory"
    return fd, None


def digest_reports(
    portfolio: Path,
    *,
    task_id: str,
    expected_terminals: list[str] | None = None,
    offset: int = 0,
    limit: int = 32,
    report_id: str | None = None,
) -> dict:
    """Read-only bounded digest over immutable worker report files under <portfolio>/artifacts/<task_id>/packets."""
    portfolio_root = resolve_trusted_portfolio(portfolio)
    work.identifier(task_id, "task")
    if type(offset) is not int or offset < 0:
        raise InboxError("--offset must be a non-negative integer")
    if type(limit) is not int or not 1 <= limit <= 128:
        raise InboxError("--limit must be an integer between 1 and 128")
    if report_id is not None:
        work.identifier(report_id, "report_id")

    expected_list: list[str] | None = None
    expected_set: set[str] | None = None
    if expected_terminals:
        expected_list = []
        for t in expected_terminals:
            if not isinstance(t, str) or not work.TERMINAL.fullmatch(t):
                raise InboxError(f"Invalid --terminal address: {t}")
            if t not in expected_list:
                expected_list.append(t)
        expected_set = set(expected_list)

    odir = getattr(os, "O_DIRECTORY", 0)
    p_fd = os.open(portfolio_root, os.O_RDONLY | odir)
    art_fd = None
    task_fd = None
    pkts_fd = None
    rejected: list[dict] = []
    accepted_by_id: dict[str, tuple[dict, str]] = {}
    conflicted_ids: set[str] = set()
    files_total = 0
    files_scanned = 0
    files_unscanned = 0
    ignored_temp_files = 0

    try:
        art_fd, art_err = _open_readonly_subdir_nofollow(p_fd, "artifacts")
        if art_err is not None:
            if art_err != "not_found":
                rejected.append({"entry": "artifacts", "reason": art_err})
        else:
            task_fd, task_err = _open_readonly_subdir_nofollow(art_fd, task_id)
            if task_err is not None:
                if task_err != "not_found":
                    rejected.append({"entry": f"artifacts/{task_id}", "reason": task_err})
            else:
                pkts_fd, pkts_err = _open_readonly_subdir_nofollow(task_fd, "packets")
                if pkts_err is not None:
                    if pkts_err != "not_found":
                        rejected.append({"entry": f"artifacts/{task_id}/packets", "reason": pkts_err})
                else:
                    with os.scandir(pkts_fd) as it:
                        raw_names = [entry.name for entry in it]

                    candidates = []
                    for name in raw_names:
                        if TEMP_FILE_RE.match(name):
                            ignored_temp_files += 1
                            continue
                        candidates.append(name)

                    # Prioritize explicit id--*.json files and target report_id so explicit IDs are never pushed past scan cap.
                    candidates.sort(key=lambda n: (
                        0 if (report_id and n == f"id--{report_id}.json") else (1 if n.startswith("id--") else 2),
                        n,
                    ))
                    files_total = len(candidates)
                    to_scan = candidates[:MAX_SCAN_FILES]
                    files_unscanned = max(0, files_total - len(to_scan))

                    pkts_base = portfolio_root / "artifacts" / task_id / "packets"
                    for fname in to_scan:
                        files_scanned += 1
                        if fname.startswith(".") or not fname.endswith(".json"):
                            rejected.append({"entry": fname, "reason": "unexpected_filename"})
                            continue
                        text_content, r_err, byte_len = _read_regular_in_dir_fd(pkts_fd, fname)
                        if r_err is not None or text_content is None:
                            rejected.append({"entry": fname, "reason": r_err or "read_failed", "bytes": byte_len})
                            continue
                        try:
                            raw_obj = json.loads(text_content, parse_constant=_reject_nonfinite_json)
                            pkt = _validate_packet_dict(raw_obj, fname=fname)
                        except (ValueError, InboxError) as exc:
                            rejected.append({"entry": fname, "reason": f"malformed_packet:{exc}", "bytes": byte_len})
                            continue

                        if pkt["task"] != task_id:
                            rejected.append({
                                "entry": fname,
                                "report_id": pkt["id"],
                                "reason": f"task_mismatch:{pkt['task']}",
                            })
                            continue

                        if expected_set is not None and pkt["terminal"] not in expected_set:
                            rejected.append({
                                "entry": fname,
                                "report_id": pkt["id"],
                                "kind": pkt["kind"],
                                "reason": f"unexpected_terminal:{pkt['terminal'] or 'none'}",
                            })
                            continue

                        rid = pkt["id"]
                        if rid in conflicted_ids:
                            continue
                        if rid in accepted_by_id:
                            prev_pkt, prev_path = accepted_by_id[rid]
                            if _packet_semantic_core(prev_pkt) != _packet_semantic_core(pkt):
                                del accepted_by_id[rid]
                                conflicted_ids.add(rid)
                                rejected.append({
                                    "entry": fname,
                                    "report_id": rid,
                                    "reason": f"conflicting_duplicate_id_with:{Path(prev_path).name}",
                                })
                            continue
                        accepted_by_id[rid] = (pkt, str(pkts_base / fname))
    finally:
        for fd_item in (pkts_fd, task_fd, art_fd, p_fd):
            if fd_item is not None:
                os.close(fd_item)

    if report_id is not None:
        if report_id not in accepted_by_id:
            rej_match = next((r for r in rejected if r.get("report_id") == report_id or r.get("entry") == f"id--{report_id}.json"), None)
            if rej_match is not None:
                raise InboxError(f"Report {report_id} rejected: {rej_match['reason']}")
            if files_unscanned > 0:
                raise InboxError(f"Report {report_id} not found within {files_scanned} scanned files ({files_unscanned} unscanned)")
            raise InboxError(f"Report {report_id} not found for task {task_id}")
        pkt, p_path = accepted_by_id[report_id]
        incomplete_reasons = []
        if pkt["truncated_at_write"]:
            incomplete_reasons.append("report_fields_truncated_at_write")
        if rejected:
            incomplete_reasons.append("rejected_artifacts")
        if files_unscanned > 0:
            incomplete_reasons.append("unscanned_files")
        return {
            "status": "ok",
            "read_only": True,
            "untrusted_worker_content": True,
            "task": task_id,
            "expected_terminals": expected_list,
            "complete": len(incomplete_reasons) == 0,
            "incomplete_reasons": incomplete_reasons,
            "report": {
                **pkt,
                "untrusted": True,
                "source": "untrusted_worker_report",
                "truncated_in_digest": False,
                "packet_path": p_path,
            },
            "rejected_artifacts": rejected[:64],
            "rejected_artifacts_omitted": max(0, len(rejected) - 64),
        }

    progress_by_term: dict[str, list[tuple[dict, str]]] = {}
    actionable_all: list[tuple[dict, str]] = []
    for pkt, p_path in accepted_by_id.values():
        if pkt["kind"] == "progress":
            progress_by_term.setdefault(pkt["terminal"] or "unassigned", []).append((pkt, p_path))
        else:
            actionable_all.append((pkt, p_path))

    progress_batches = []
    for term_key in sorted(progress_by_term):
        items = sorted(progress_by_term[term_key], key=lambda pair: (pair[0]["created_ns"], pair[0]["id"]))
        merged_usage = {k: "unknown" for k in ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "api_cost_usd", "cost_source")}
        for item_pkt, _ in items:
            for uk, uv in item_pkt["usage"].items():
                if uv != "unknown":
                    merged_usage[uk] = uv
        latest_pkt, latest_path = items[-1]
        sum_prev, sum_prev_trunc = preview_text(latest_pkt["summary"], limit=MAX_PREVIEW_FIELD_CHARS)
        progress_batches.append({
            "terminal": None if term_key == "unassigned" else term_key,
            "untrusted": True,
            "source": "untrusted_worker_report",
            "progress_count": len(items),
            "omitted_progress_count": len(items) - 1,
            "first_at": items[0][0]["at"],
            "last_at": latest_pkt["at"],
            "latest_report_id": latest_pkt["id"],
            "latest_summary": sum_prev,
            "latest_truncated": bool(sum_prev_trunc or latest_pkt["truncated_at_write"]),
            "latest_packet_path": latest_path,
            "latest_known_usage": merged_usage,
        })

    actionable_all.sort(key=lambda pair: (ACTIONABLE_PRIORITY.get(pair[0]["kind"], 99), pair[0]["created_ns"], pair[0]["id"]))
    total_actionable = len(actionable_all)
    sliced = actionable_all[offset : offset + limit]
    next_offset = (offset + limit) if (offset + limit) < total_actionable else None

    rendered_actionable = []
    any_trunc_in_digest = False
    any_trunc_at_write = False
    for pkt, p_path in sliced:
        s_prev, s_tr = preview_text(pkt["summary"], limit=MAX_PREVIEW_SUMMARY_CHARS)
        c_prev, c_tr = preview_text(pkt["checks"], limit=MAX_PREVIEW_FIELD_CHARS)
        n_prev, n_tr = preview_text(pkt["concerns"], limit=MAX_PREVIEW_FIELD_CHARS)
        shown_paths = pkt["changed_paths"][:MAX_PREVIEW_PATHS]
        extra_paths_omitted = max(0, len(pkt["changed_paths"]) - len(shown_paths))
        trunc_in_digest = bool(s_tr or c_tr or n_tr or extra_paths_omitted > 0)
        any_trunc_in_digest = any_trunc_in_digest or trunc_in_digest
        any_trunc_at_write = any_trunc_at_write or pkt["truncated_at_write"]
        rendered_actionable.append({
            "id": pkt["id"],
            "task": pkt["task"],
            "terminal": pkt["terminal"],
            "kind": pkt["kind"],
            "at": pkt["at"],
            "untrusted": True,
            "source": "untrusted_worker_report",
            "summary": s_prev,
            "checks": c_prev,
            "concerns": n_prev,
            "changed_paths": shown_paths,
            "changed_paths_omitted": pkt["changed_paths_omitted"] + extra_paths_omitted,
            "usage": pkt["usage"],
            "truncated_at_write": pkt["truncated_at_write"],
            "truncated_in_digest": trunc_in_digest,
            "packet_path": p_path,
        })

    incomplete_reasons = []
    if offset > 0:
        incomplete_reasons.append("nonzero_page_offset")
    if next_offset is not None:
        incomplete_reasons.append("actionable_paged")
    if files_unscanned > 0:
        incomplete_reasons.append("unscanned_files")
    if rejected:
        incomplete_reasons.append("rejected_artifacts")
    if any_trunc_in_digest:
        incomplete_reasons.append("report_fields_truncated_in_digest")
    if any_trunc_at_write:
        incomplete_reasons.append("report_fields_truncated_at_write")

    result = {
        "status": "ok",
        "read_only": True,
        "untrusted_worker_content": True,
        "task": task_id,
        "expected_terminals": expected_list,
        "complete": len(incomplete_reasons) == 0,
        "incomplete_reasons": incomplete_reasons,
        "pagination": {
            "offset": offset,
            "limit": limit,
            "actionable_total": total_actionable,
            "actionable_returned": len(rendered_actionable),
            "actionable_omitted": max(0, total_actionable - (offset + len(rendered_actionable))),
            "next_offset": next_offset,
        },
        "scan": {
            "files_total": files_total,
            "files_scanned": files_scanned,
            "files_unscanned": files_unscanned,
            "ignored_temp_files": ignored_temp_files,
            "rejected_count": len(rejected),
        },
        "rejected_artifacts": rejected[:64],
        "rejected_artifacts_omitted": max(0, len(rejected) - 64),
        "actionable": rendered_actionable,
        "progress_batches": progress_batches,
    }
    result["digest_bytes"] = len(encode_json(result).encode("utf-8"))
    return result


def measure_report_fixture() -> dict:
    """Execute a small synthetic file-level comparison of unbatched report reads vs worker-report + read-only digest."""
    import tempfile

    with tempfile.TemporaryDirectory(prefix="cos-report-fixture-") as tmp:
        base = Path(tmp)
        portfolio = base / "portfolio"
        portfolio.mkdir(mode=0o700)
        (portfolio / "portfolio.md").write_text("# Isolated synthetic report fixture\n", encoding="utf-8")
        art_dir = portfolio / "artifacts" / "T001"

        events = []
        for idx in range(70):
            term = "t2" if idx % 2 == 0 else "vps/t3"
            events.append({
                "id": f"prog-{idx:03d}",
                "terminal": term,
                "kind": "progress",
                "summary": f"Completed incremental check {idx} across module files",
                "checks": "unit slice ok",
                "usage": {"input_tokens": 1200 + idx * 10} if idx == 69 else None,
            })
        events.extend([
            {"id": "q-schema", "terminal": "t2", "kind": "question", "summary": "Confirm migration column nullable default?", "checks": ""},
            {"id": "err-test", "terminal": "vps/t3", "kind": "error", "summary": "Parser test failed on trailing newline", "checks": "pytest -k parser -> exit 1"},
            # Idempotent retry of the exact same error report ID:
            {"id": "err-test", "terminal": "vps/t3", "kind": "error", "summary": "Parser test failed on trailing newline", "checks": "pytest -k parser -> exit 1"},
            # Conflicting ID reuse attempt (must be rejected):
            {"id": "err-test", "terminal": "vps/t3", "kind": "error", "summary": "Different summary reusing err-test ID", "checks": ""},
            {"id": "done-t2", "terminal": "t2", "kind": "done", "summary": "Implemented schema migration and tests", "checks": "34 passed"},
            {
                "id": "done-remote",
                "terminal": "vps/t3",
                "kind": "done",
                "summary": "Fixed parser newline handling on remote worker",
                "checks": "19 passed",
                "usage": {"input_tokens": 18400, "cache_read_tokens": 14200, "cache_write_tokens": 4200, "output_tokens": 920, "api_cost_usd": 0.0412, "cost_source": "fixture"},
            },
        ])

        # Workflow 1: Unbatched individual JSON report files read one-by-one without progress spooling/dedup
        raw_dir = base / "unbatched"
        raw_dir.mkdir(mode=0o700)
        unbatched_writes = 0
        unbatched_notify_count = 0
        unbatched_paths: list[Path] = []
        for idx, ev in enumerate(events):
            p = raw_dir / f"report-{idx:04d}.json"
            payload = encode_json({"task": "T001", **ev})
            p.write_text(payload, encoding="utf-8")
            unbatched_writes += 1
            unbatched_notify_count += 1
            unbatched_paths.append(p)

        unbatched_read_ops = 0
        unbatched_read_bytes = 0
        for p in unbatched_paths:
            unbatched_read_ops += 1
            unbatched_read_bytes += len(p.read_bytes())

        # Workflow 2: Real write_worker_report + read-only digest_reports on the exact same event list
        recorded_count = 0
        duplicate_count = 0
        conflict_rejected_count = 0
        notify_true_count = 0
        send_line_bytes = 0
        for ev in events:
            try:
                res = write_worker_report(
                    artifact_dir=art_dir,
                    task_id="T001",
                    packet_id=ev["id"],
                    terminal=ev["terminal"],
                    kind=ev["kind"],
                    summary=ev["summary"],
                    checks_summary=ev["checks"],
                    usage=ev.get("usage"),
                )
            except InboxError:
                conflict_rejected_count += 1
                continue
            if res["status"] == "recorded":
                recorded_count += 1
                if res["notify_coordinator"]:
                    notify_true_count += 1
                    send_line_bytes += len((res["send_line"] or "").encode("utf-8"))
            else:
                duplicate_count += 1

        digest = digest_reports(portfolio, task_id="T001", expected_terminals=["t2", "vps/t3"])
        digest_bytes = digest["digest_bytes"]

    return {
        "measurement_kind": "synthetic_report_artifact_fixture",
        "scope_note": (
            "Measures only isolated file writes, notify-flag counts, and read/digest UTF-8 bytes over a 76-attempt "
            "(70 progress + question + error + retry + conflict + 2 done) synthetic fixture. Does NOT measure live "
            "Herdr PTY wakeups, provider token billing, or subscription costs."
        ),
        "unbatched_individual_reports": {
            "write_attempts": len(events),
            "files_written": unbatched_writes,
            "notify_instructions_emitted": unbatched_notify_count,
            "coordinator_read_ops": unbatched_read_ops,
            "coordinator_bytes_read": unbatched_read_bytes,
            "live_api_cost_usd": "unknown",
        },
        "worker_report_plus_readonly_digest": {
            "write_attempts": len(events),
            "recorded_packets": recorded_count,
            "duplicates_suppressed_idempotently": duplicate_count,
            "conflicting_ids_rejected": conflict_rejected_count,
            "notify_instructions_emitted": notify_true_count,
            "actionable_send_line_bytes": send_line_bytes,
            "coordinator_read_ops": 1,
            "digest_output_bytes": digest_bytes,
            "total_coordinator_bytes": send_line_bytes + digest_bytes,
            "complete_digest": digest["complete"],
            "actionable_ids_preserved": [item["id"] for item in digest["actionable"]],
            "progress_counts_by_terminal": {
                (b["terminal"] or "unassigned"): b["progress_count"] for b in digest["progress_batches"]
            },
            "live_api_cost_usd": "unknown",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portfolio", type=Path, help="Portfolio directory or portfolio.md (required for digest)")
    sub = parser.add_subparsers(dest="command", required=True)

    wr = sub.add_parser("worker-report", help="Write an immutable per-report artifact packet")
    wr.add_argument("--artifact-dir", type=Path, required=True, help="Must be <portfolio>/artifacts/<task>")
    wr.add_argument("--task", required=True)
    wr.add_argument("--kind", required=True, choices=list(REPORT_KINDS))
    wr.add_argument("--summary", required=True)
    wr.add_argument("--id", dest="packet_id")
    wr.add_argument("--terminal")
    wr.add_argument("--changed", action="append", default=[])
    wr.add_argument("--checks", default="")
    wr.add_argument("--concerns", default="")
    wr.add_argument("--input-tokens", type=int)
    wr.add_argument("--cache-read-tokens", type=int)
    wr.add_argument("--cache-write-tokens", type=int)
    wr.add_argument("--output-tokens", type=int)
    wr.add_argument("--api-cost-usd", type=float)
    wr.add_argument("--cost-source")

    dg = sub.add_parser("digest", help="Read-only bounded digest of worker report packets for a task")
    dg.add_argument("--task", required=True)
    dg.add_argument("--terminal", action="append", default=[], dest="terminals", help="Expected worker terminal(s), repeatable")
    dg.add_argument("--offset", type=int, default=0)
    dg.add_argument("--limit", type=int, default=32)
    dg.add_argument("--report-id", help="Read full stored bounded fields for one report ID")

    sub.add_parser("measure-fixture", help="Run isolated synthetic report-vs-digest byte/op fixture measurement")

    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "worker-report":
            usage = {
                "input_tokens": args.input_tokens,
                "cache_read_tokens": args.cache_read_tokens,
                "cache_write_tokens": args.cache_write_tokens,
                "output_tokens": args.output_tokens,
                "api_cost_usd": args.api_cost_usd,
                "cost_source": args.cost_source,
            }
            result = write_worker_report(
                artifact_dir=args.artifact_dir,
                task_id=args.task,
                kind=args.kind,
                summary=args.summary,
                packet_id=args.packet_id,
                terminal=args.terminal,
                changed_paths=args.changed,
                checks_summary=args.checks,
                concerns=args.concerns,
                usage=usage,
            )
        elif args.command == "digest":
            if args.portfolio is None:
                raise InboxError("--portfolio is required for digest")
            result = digest_reports(
                args.portfolio,
                task_id=args.task,
                expected_terminals=args.terminals or None,
                offset=args.offset,
                limit=args.limit,
                report_id=args.report_id,
            )
        else:
            result = measure_report_fixture()
        print(encode_json(result), end="")
        return 0
    except (InboxError, work.RecordError, OSError, ValueError, KeyError, TypeError) as exc:
        print(encode_json({"status": "error", "message": str(exc)}), file=sys.stderr, end="")
        return 2


if __name__ == "__main__":
    sys.exit(main())
