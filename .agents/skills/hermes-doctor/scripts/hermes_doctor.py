#!/usr/bin/env python3
"""
Hermes Doctor — end-to-end diagnostics for the running Project Hermes system.

A dev-time tool for AI coding agents (and humans) to debug the live pipeline
(Android phone -> newline-delimited JSON over TCP:9999 -> Windows companion).

It only READS runtime state; the sole state-changing action is the opt-in
`probe --fix-forward` flag (runs `adb forward`). Every subcommand degrades to a
Windows-only view when adb or the phone is unavailable, and never hard-crashes.

Subcommands: doctor | status | logs | probe | report
"""

import argparse
import glob
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]

DEFAULT_PORT = 9999
WIN_PY_LOG = REPO_ROOT / "windows.log"
WIN_PS_LOG = REPO_ROOT / "windows" / "hermes.log"
CONFIG_PATH = REPO_ROOT / "windows" / "hermes.config.json"
MAIN_PY = REPO_ROOT / "windows" / "main.py"
TRANSPORT_KT = (
    REPO_ROOT / "android" / "app" / "src" / "main" / "java"
    / "com" / "hermes" / "transport" / "TransportServerService.kt"
)
ERROR_SCHEMA = REPO_ROOT / "protocol" / "schemas" / "v1" / "error.schema.json"
SCHEMAS_DIR = REPO_ROOT / "protocol" / "schemas" / "v1"
ANDROID_PKG = "com.hermes"
LOGCAT_TAGS = ["TransportServer", "AndroidSpeechEngine", "SpeechEngine"]
ADB_SDK_PATH = "/home/calur/android-dev/sdk/platform-tools/adb"

# Status markers
OK, WARN, FAIL, INFO = "ok", "warn", "fail", "info"
_MARK = {OK: "✅", WARN: "⚠️", FAIL: "❌", INFO: "ℹ️"}
_SRC_PREFIX = {"win-py": "\U0001fa9f", "win-ps": "⌨️", "android": "\U0001f916"}

try:
    import jsonschema
except ImportError:  # optional, mirrors tests/unit/protocol/test_schemas.py
    jsonschema = None


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

class Out:
    """Coloured/plain output helper."""

    def __init__(self, no_color: bool):
        self.color = (not no_color) and sys.stdout.isatty() and not os.environ.get("NO_COLOR")

    def _c(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.color else text

    def head(self, text: str):
        print(self._c("1;36", f"\n== {text} =="))

    def line(self, status: str, name: str, detail: str, hint: str = ""):
        mark = _MARK.get(status, "")
        colour = {OK: "32", WARN: "33", FAIL: "31", INFO: "36"}.get(status, "0")
        print(f"{mark} {self._c(colour, name)}: {detail}")
        if hint:
            print(f"     {self._c('2', 'hint: ' + hint)}")

    def note(self, text: str):
        print(self._c("2", text))


def run_cmd(cmd, timeout=8):
    """Run a command; return (ok, stdout, stderr). Never raises."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return res.returncode == 0, (res.stdout or "").strip(), (res.stderr or "").strip()
    except FileNotFoundError:
        return False, "", f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return False, "", f"{cmd[0]}: timed out after {timeout}s"
    except Exception as e:  # pragma: no cover - defensive
        return False, "", str(e)


def resolve_adb(args) -> str:
    if getattr(args, "adb", None):
        return args.adb
    env = os.environ.get("HERMES_ADB")
    if env:
        return env
    if Path(ADB_SDK_PATH).exists():
        return ADB_SDK_PATH
    return "adb"


def run_adb(adb, adb_args, timeout=8):
    return run_cmd([adb] + adb_args, timeout=timeout)


def read_config() -> dict:
    try:
        if CONFIG_PATH.exists():
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        pass
    return {}


def resolve_endpoint(args):
    """Mirror windows/main.py load_config: env -> hermes.config.json -> default."""
    host, port = "127.0.0.1", DEFAULT_PORT
    cfg = read_config()
    host = str(cfg.get("host", host))
    try:
        port = int(cfg.get("port", port))
    except (TypeError, ValueError):
        port = DEFAULT_PORT
    host = os.environ.get("HERMES_HOST", host)
    try:
        port = int(os.environ.get("HERMES_PORT", port))
    except ValueError:
        pass
    if getattr(args, "host", None):
        host = args.host
    if getattr(args, "port", None):
        port = args.port
    return host, port


def is_loopback(host: str) -> bool:
    return host in ("127.0.0.1", "localhost", "::1")


# --------------------------------------------------------------------------- #
# TCP protocol client (framing ported from windows/send_command.py)
# --------------------------------------------------------------------------- #

def _recv_json_lines(sock, deadline):
    """Yield parsed JSON objects from a newline-delimited stream until deadline."""
    buffer = ""
    while time.monotonic() < deadline:
        try:
            sock.settimeout(max(0.1, deadline - time.monotonic()))
            chunk = sock.recv(4096).decode("utf-8", errors="replace")
        except socket.timeout:
            return
        if not chunk:
            return
        buffer += chunk
        while "\n" in buffer:
            line, buffer = buffer.split("\n", 1)
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


def tcp_probe_ping(host, port, timeout):
    """Connect, read on-connect heartbeat, send ping, expect heartbeat=ready."""
    result = {"reachable": False, "rtt_ms": None, "heartbeat_status": None, "error": None}
    try:
        t0 = time.monotonic()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        result["reachable"] = True
        deadline = time.monotonic() + timeout
        # on-connect heartbeat
        for msg in _recv_json_lines(sock, deadline):
            if msg.get("type") == "heartbeat":
                result["heartbeat_status"] = msg.get("status")
                break
        # ping round-trip
        ping = {"version": "1.0", "type": "command", "command": "ping",
                "timestamp": int(time.time() * 1000)}
        sock.sendall((json.dumps(ping) + "\n").encode("utf-8"))
        for msg in _recv_json_lines(sock, time.monotonic() + timeout):
            if msg.get("type") == "heartbeat":
                result["heartbeat_status"] = msg.get("status")
                result["rtt_ms"] = round((time.monotonic() - t0) * 1000, 1)
                break
        sock.close()
    except Exception as e:
        result["error"] = str(e)
    return result


def tcp_probe_simulate(host, port, timeout, mock_text):
    """Drive simulate_speech and capture the causal chain with per-hop latency."""
    steps = []

    def step(n, label, payload=None, valid=None):
        steps.append({"n": n, "label": label,
                      "t_ms": round((time.monotonic() - t0) * 1000, 1),
                      "payload": payload, "schema_valid": valid})

    t0 = time.monotonic()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        step(1, "connected + command sent")
        for msg in _recv_json_lines(sock, time.monotonic() + timeout):
            if msg.get("type") == "heartbeat":
                step(2, "on-connect heartbeat", msg.get("status"),
                     validate_frame(msg, "heartbeat"))
                break
        sim = {"version": "1.0", "type": "command", "command": "simulate_speech",
               "mock_text": mock_text, "timestamp": int(time.time() * 1000)}
        sock.sendall((json.dumps(sim) + "\n").encode("utf-8"))
        final_seen = False
        for msg in _recv_json_lines(sock, time.monotonic() + timeout):
            mtype = msg.get("type")
            if mtype == "partial":
                step(3, "partial received", msg.get("text"), validate_frame(msg, "partial"))
            elif mtype == "final":
                step(4, "final received", msg.get("text"), validate_frame(msg, "final"))
                final_seen = True
                break
            elif mtype == "error":
                step(4, "error received", f"{msg.get('code')}: {msg.get('message')}",
                     validate_frame(msg, "error"))
                break
        sock.close()
        return {"steps": steps, "result": "PASS" if final_seen else "FAIL"}
    except Exception as e:
        step(1, f"connect failed: {e}")
        return {"steps": steps, "result": "FAIL", "error": str(e)}


def validate_frame(msg, kind):
    """Validate a frame against its v1 schema. Returns True/False/None(unavailable)."""
    if jsonschema is None:
        return None
    schema_path = SCHEMAS_DIR / f"{kind}.schema.json"
    if not schema_path.exists():
        return None
    try:
        jsonschema.validate(instance=msg, schema=json.loads(schema_path.read_text()))
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# Process / device checks
# --------------------------------------------------------------------------- #

def check_python_daemon():
    ok, out, _ = run_cmd(["pgrep", "-f", "python3 windows/main.py"])
    if ok and out:
        return OK, f"running (pid {out.replace(chr(10), ', ')})", ""
    return WARN, "not running", "start with `task windows:run`"


def check_powershell_tray(timeout):
    # Match the tray script's command line, but exclude this diagnostic query itself
    # (its own command line contains the word 'hermes_hotkey').
    query = ("Get-CimInstance Win32_Process -Filter \"name='powershell.exe'\" | "
             "Where-Object { $_.CommandLine -match 'hermes_hotkey\\.ps1' -and "
             "$_.CommandLine -notmatch 'Get-CimInstance' } | "
             "Select-Object -ExpandProperty ProcessId")
    ok, out, err = run_cmd(["powershell.exe", "-NoProfile", "-Command", query], timeout=timeout)
    if not ok and "not found" in err:
        return INFO, "skipped (powershell.exe unavailable; WSL interop off?)", ""
    pids = [p.strip() for p in (out or "").splitlines() if p.strip()]
    if pids:
        return OK, f"running (pid {', '.join(pids)})", ""
    return WARN, "not running", "start with `task windows:ps` or install via `task windows:install`"


def adb_device_state(adb):
    ok, out, err = run_cmd([adb, "devices"], timeout=8)
    if not ok:
        return None, err or "adb unavailable"
    devices = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2:
            devices.append((parts[0], parts[1]))
    return devices, None


# --------------------------------------------------------------------------- #
# Config-sanity checks (surface the two known bugs; auto-clear once fixed)
# --------------------------------------------------------------------------- #

def check_hotkey_config(cfg):
    """Bug 1 (REQ-FUNC-003): main.py must honour config `hotkeys` rather than hardcoding f12."""
    if not MAIN_PY.exists():
        return INFO, "windows/main.py not found; skipped", ""
    text = MAIN_PY.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"HotkeyManager\((.*?)\)", text, re.DOTALL)
    hardcoded_f12 = bool(m and re.search(r"hotkey_name\s*=\s*[\"']f12[\"']", m.group(1)))
    reads_hotkeys = "hotkeys" in text
    hotkeys = cfg.get("hotkeys")
    if hardcoded_f12 and hotkeys:
        return (WARN,
                f"windows/main.py hardcodes hotkey 'f12', but config hotkeys={hotkeys} "
                f"(163 = Right Ctrl). The Python daemon ignores the configured key.",
                "REQ-FUNC-003 — have load_config() read `hotkeys` and pass it to HotkeyManager")
    if hardcoded_f12:
        return WARN, "windows/main.py hardcodes hotkey 'f12'", "REQ-FUNC-003"
    if reads_hotkeys:
        return OK, "windows/main.py reads `hotkeys` from config (Right Ctrl honoured)", ""
    return INFO, "could not determine hotkey resolution in windows/main.py", ""


def check_error_enum_drift():
    """Bug 2 (REQ-NFR-006/009): every code emitted by Kotlin must exist in error.schema.json."""
    if not ERROR_SCHEMA.exists() or not TRANSPORT_KT.exists():
        return INFO, "error schema or Kotlin source not found; skipped", ""
    try:
        schema_codes = set(json.loads(ERROR_SCHEMA.read_text())["properties"]["code"]["enum"])
    except Exception as e:
        return INFO, f"could not read error.schema.json enum ({e})", ""
    kt = TRANSPORT_KT.read_text(encoding="utf-8", errors="replace")
    # Anchor on the function DEFINITION (`fun getErrorCodeString`), not its call site.
    block = re.search(r"fun getErrorCodeString\(.*?\{(.*?)\n\s{4}\}", kt, re.DOTALL)
    scope = block.group(1) if block else kt
    emitted = set(re.findall(r'->\s*"([A-Z_]+)"', scope))
    orphans = sorted(emitted - schema_codes)
    if orphans:
        return (FAIL,
                f"{len(orphans)} emitted error code(s) absent from error.schema.json: "
                f"{', '.join(orphans)} — real error frames fail schema validation",
                "REQ-NFR-006, REQ-FUNC-009 — expand the error.schema.json `code` enum")
    return OK, "Android error codes all present in error.schema.json (no drift)", ""


# --------------------------------------------------------------------------- #
# Log parsing + merge
# --------------------------------------------------------------------------- #

_RE_WIN_PY = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(?P<ms>\d{3}) "
    r"\[(?P<lvl>\w+)\] \((?P<logger>[^)]+)\) (?P<msg>.*)$")
_RE_WIN_PS = re.compile(r"^(?P<h>\d{2})[.:](?P<m>\d{2})[.:](?P<s>\d{2})\s+(?P<msg>.*)$")
_RE_LOGCAT = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.(?P<ms>\d{3})\s+"
    r"\d+\s+\d+\s+(?P<lvl>[VDIWEF])\s+(?P<tag>\S+?):?\s+(?P<msg>.*)$")


def _rec(dt, source, level, msg, raw):
    return {"dt": dt, "source": source, "level": level, "msg": msg, "raw": raw}


def parse_win_py(text):
    records, last = [], None
    for raw in text.splitlines():
        m = _RE_WIN_PY.match(raw)
        if m:
            dt = datetime.strptime(m["ts"], "%Y-%m-%d %H:%M:%S").replace(
                microsecond=int(m["ms"]) * 1000)
            last = _rec(dt, "win-py", m["lvl"], f"({m['logger']}) {m['msg']}", raw)
            records.append(last)
        elif last is not None:  # continuation / torn write
            last["msg"] += " " + raw.strip()
    return records


def parse_win_ps(text, base_date):
    records = []
    prev_secs = None
    day = base_date
    for raw in text.splitlines():
        m = _RE_WIN_PS.match(raw)
        if not m:
            continue
        secs = int(m["h"]) * 3600 + int(m["m"]) * 60 + int(m["s"])
        if prev_secs is not None and secs < prev_secs - 5:  # midnight rollover heuristic
            day = day + timedelta(days=1)
        prev_secs = secs
        dt = datetime(day.year, day.month, day.day, int(m["h"]), int(m["m"]), int(m["s"]))
        records.append(_rec(dt, "win-ps", "INFO", m["msg"], raw))
    return records


def parse_logcat(text):
    records = []
    for raw in text.splitlines():
        m = _RE_LOGCAT.match(raw)
        if not m:
            continue
        dt = datetime.strptime(m["ts"], "%Y-%m-%d %H:%M:%S").replace(
            microsecond=int(m["ms"]) * 1000)
        records.append(_rec(dt, "android", m["lvl"], f"{m['tag']}: {m['msg']}", raw))
    return records


def _tail_text(path, lines):
    try:
        data = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(data[-lines:]) if lines else "\n".join(data)
    except Exception:
        return ""


def collect_android_logcat(adb, lines):
    ok, out, _ = run_adb(
        adb, ["logcat", "-v", "year", "-d", "-t", str(lines)]
        + [f"{t}:V" for t in LOGCAT_TAGS] + ["*:S"], timeout=12)
    if not ok:
        # fall back to threadtime (older devices) and prepend current year
        ok2, out2, _ = run_adb(
            adb, ["logcat", "-v", "threadtime", "-d", "-t", str(lines)]
            + [f"{t}:V" for t in LOGCAT_TAGS] + ["*:S"], timeout=12)
        if ok2:
            year = time.strftime("%Y")
            out = "\n".join(f"{year}-{ln}" for ln in out2.splitlines())
        else:
            return []
    return parse_logcat(out)


def parse_since(spec):
    if not spec:
        return None
    m = re.fullmatch(r"(\d+)([smhd])", spec.strip())
    if m:
        n, unit = int(m.group(1)), m.group(2)
        delta = {"s": timedelta(seconds=n), "m": timedelta(minutes=n),
                 "h": timedelta(hours=n), "d": timedelta(days=n)}[unit]
        return datetime.now() - delta
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(spec, fmt)
        except ValueError:
            continue
    return None


def collect_logs(args, sources, lines):
    records = []
    if "win-py" in sources and WIN_PY_LOG.exists():
        records += parse_win_py(_tail_text(WIN_PY_LOG, lines))
    if "win-ps" in sources and WIN_PS_LOG.exists():
        base = datetime.fromtimestamp(WIN_PS_LOG.stat().st_mtime)
        records += parse_win_ps(_tail_text(WIN_PS_LOG, lines), base)
    android_available = True
    android_reason = ""
    if "android" in sources and not getattr(args, "skip_android", False):
        adb = resolve_adb(args)
        devices, err = adb_device_state(adb)
        if not devices:
            android_available = False
            android_reason = err or "no authorised device"
        else:
            records += collect_android_logcat(adb, lines)
    else:
        android_available = False
        android_reason = "skipped"
    records.sort(key=lambda r: r["dt"])
    return records, android_available, android_reason


# --------------------------------------------------------------------------- #
# Subcommand: doctor
# --------------------------------------------------------------------------- #

def cmd_doctor(args):
    out = Out(args.no_color)
    host, port = resolve_endpoint(args)
    cfg = read_config()
    checks = []

    def add(cid, status, detail, hint="", **extra):
        checks.append({"id": cid, "status": status, "detail": detail, "hint": hint, **extra})

    add("win.python_daemon", *check_python_daemon())
    add("win.powershell_tray", *check_powershell_tray(args.timeout))

    mode = "full"
    if not args.skip_android:
        adb = resolve_adb(args)
        devices, err = adb_device_state(adb)
        if devices is None:
            mode = "windows-only"
            add("adb.available", WARN, f"adb unavailable ({err})",
                "set HERMES_ADB or run via `task` (PATH includes platform-tools)")
        elif not devices:
            mode = "windows-only"
            add("adb.device", WARN, "no device connected",
                "plug in USB + enable USB debugging, then "
                "`python3 .agents/skills/adb-tunnel-manager/scripts/manage_adb_forward.py --setup`")
        else:
            states = ", ".join(f"{s}({st})" for s, st in devices)
            authed = any(st == "device" for _, st in devices)
            add("adb.device", OK if authed else WARN, states,
                "" if authed else "authorise the RSA prompt on the phone")
            _, flist, _ = run_adb(adb, ["forward", "--list"])
            has_fwd = f"tcp:{port}" in (flist or "")
            add("adb.forward", OK if (has_fwd or not is_loopback(host)) else WARN,
                (flist or "no forward rules") if has_fwd else "tcp:%d not forwarded" % port,
                "" if (has_fwd or not is_loopback(host)) else f"`{adb} forward tcp:{port} tcp:{port}`")
            _, pkgs, _ = run_adb(adb, ["shell", "pm", "list", "packages", ANDROID_PKG])
            add("android.installed", OK if ANDROID_PKG in (pkgs or "") else WARN,
                "installed" if ANDROID_PKG in (pkgs or "") else "not installed",
                "" if ANDROID_PKG in (pkgs or "") else "`task deploy`")
            _, pid, _ = run_adb(adb, ["shell", "pidof", ANDROID_PKG])
            add("android.running", OK if pid.strip() else WARN,
                f"running (pid {pid.strip()})" if pid.strip() else "foreground service not running",
                "" if pid.strip() else "open the app / start the service")
    else:
        mode = "windows-only"
        add("android", INFO, "skipped (--skip-android)")

    # TCP reachability + liveness
    ping = tcp_probe_ping(host, port, args.timeout)
    if ping["reachable"] and ping["heartbeat_status"]:
        add("tcp.reachable", OK,
            f"{host}:{port} heartbeat status={ping['heartbeat_status']}"
            + (f" (rtt {ping['rtt_ms']} ms)" if ping["rtt_ms"] else ""),
            **{"endpoint": {"host": host, "port": port, "reach": True, "rtt_ms": ping["rtt_ms"]}})
    else:
        add("tcp.reachable", FAIL, f"{host}:{port} unreachable ({ping.get('error') or 'no heartbeat'})",
            f"`{resolve_adb(args)} forward tcp:{port} tcp:{port}` (loopback) or check the phone's serving address",
            **{"endpoint": {"host": host, "port": port, "reach": False, "rtt_ms": None}})

    add("config.hotkey", *check_hotkey_config(cfg))
    add("config.error_enum", *check_error_enum_drift())

    summary = {"ok": sum(c["status"] == OK for c in checks),
               "warn": sum(c["status"] == WARN for c in checks),
               "fail": sum(c["status"] == FAIL for c in checks)}

    if args.json:
        print(json.dumps({"summary": summary, "mode": mode,
                          "endpoint": {"host": host, "port": port},
                          "checks": checks}, indent=2))
    else:
        out.head("Hermes Doctor — health check")
        for c in checks:
            out.line(c["status"], c["id"], c["detail"], c["hint"])
        out.note(f"\nSummary: {summary['ok']} ok / {summary['warn']} warn / "
                 f"{summary['fail']} fail — mode: {mode}")
        if is_loopback(host):
            out.note("Note: a green TCP result from WSL (via WSL-side `adb forward`) does not prove "
                     "the Windows companion can reach the phone — it uses Windows loopback / the tether IP.")

    if args.strict and summary["fail"]:
        return 1
    return 0


# --------------------------------------------------------------------------- #
# Subcommand: status (live runtime state, from existing signals only)
# --------------------------------------------------------------------------- #

_STATE_MARKERS = [
    ("start_listening", "LISTENING"),
    ("PartialResult", "RECOGNISING"),
    ("Partial", "RECOGNISING"),
    ("FinalResult", "FINALISING"),
    ("final", "FINALISING"),
    ("stop_listening", "STOPPED"),
    ("Error", "ERROR"),
]


def android_serving_text(adb, timeout):
    """Best-effort: read the foreground-service notification content (currentServingText)."""
    ok, out, _ = run_adb(adb, ["shell", "dumpsys", "notification", "--noredact"], timeout=timeout)
    if not ok or not out:
        ok, out, _ = run_adb(adb, ["shell", "dumpsys", "activity", "services", ANDROID_PKG],
                             timeout=timeout)
    for line in (out or "").splitlines():
        if "Listening on" in line or ("Idle" in line and "transport" in line):
            return line.strip()
    return None


def android_recent_state(records):
    for r in reversed(records):
        for marker, state in _STATE_MARKERS:
            if marker in r["msg"]:
                return state, r["dt"], r["msg"]
    return None, None, None


def cmd_status(args):
    out = Out(args.no_color)
    host, port = resolve_endpoint(args)
    data = {"endpoint": {"host": host, "port": port}}

    ping = tcp_probe_ping(host, port, args.timeout)
    data["reachable"] = ping["reachable"]
    data["heartbeat_status"] = ping["heartbeat_status"]

    serving = None
    recent_state = recent_dt = recent_msg = None
    android_available = False
    if not args.skip_android:
        adb = resolve_adb(args)
        devices, _ = adb_device_state(adb)
        if devices:
            android_available = True
            serving = android_serving_text(adb, args.timeout)
            recs = collect_android_logcat(adb, 200)
            recent_state, recent_dt, recent_msg = android_recent_state(recs)
    data["android_available"] = android_available
    data["serving_text"] = serving
    data["recent_pipeline_state"] = recent_state

    py_status, py_detail, _ = check_python_daemon()
    ps_status, ps_detail, _ = check_powershell_tray(args.timeout)
    data["windows"] = {"python_daemon": py_detail, "powershell_tray": ps_detail}

    if args.json:
        print(json.dumps(data, indent=2, default=str))
        return 0

    out.head("Hermes Doctor — live runtime status")
    out.line(OK if ping["reachable"] else FAIL, "transport",
             f"{host}:{port} " + (f"reachable, heartbeat={ping['heartbeat_status']}"
                                   if ping["reachable"] else "unreachable"))
    if android_available:
        out.line(OK if serving else INFO, "serving state",
                 serving or "unknown (notification not readable)")
        if recent_state:
            out.line(INFO, "recent pipeline state",
                     f"{recent_state} (last seen {recent_dt}) — inferred from logcat")
        else:
            out.line(INFO, "recent pipeline state", "no recent speech events in logcat")
    else:
        out.line(INFO, "android", "unavailable (no device) — Windows-only status")
    out.line(OK if py_status == OK else WARN, "windows python daemon", py_detail)
    out.line(OK if ps_status == OK else (INFO if ps_status == INFO else WARN),
             "windows powershell tray", ps_detail)
    out.note("\nLimitations: the heartbeat status is hard-coded to 'ready' on the device, so "
             "listening-vs-idle and pipeline state are inferred from the notification and logcat, "
             "not queried. Connected-client count is not exposed over the wire.")
    return 0


# --------------------------------------------------------------------------- #
# Subcommand: logs
# --------------------------------------------------------------------------- #

def _print_record(out, r):
    prefix = _SRC_PREFIX.get(r["source"], "")
    ts = r["dt"].strftime("%H:%M:%S.%f")[:-3]
    colour = {"win-py": "34", "win-ps": "35", "android": "32"}.get(r["source"], "0")
    src = out._c(colour, f"[{r['source']}]")
    print(f"{ts} {prefix}{src} {r['level']:<5} {r['msg']}")


def cmd_logs(args):
    out = Out(args.no_color)
    sources = [s.strip() for s in args.sources.split(",")] if args.sources else \
        ["win-py", "win-ps", "android"]

    out.note("Cross-device ordering note: Android lines use the phone clock, Windows lines use the "
             "PC clock — ordering within ~1s across devices is approximate.")

    if args.follow:
        return _follow_logs(args, out, sources)

    records, android_ok, reason = collect_logs(args, sources, args.lines)
    cutoff = parse_since(args.since)
    if cutoff:
        records = [r for r in records if r["dt"] >= cutoff]

    if args.json:
        print(json.dumps([{**r, "dt": r["dt"].isoformat()} for r in records], indent=2))
        return 0

    if "android" in sources and not android_ok:
        out.note(f"(android source unavailable: {reason})")
    for r in records:
        _print_record(out, r)
    return 0


def _follow_logs(args, out, sources):
    buf, lock, stop = [], threading.Lock(), threading.Event()
    hold = 1.0

    def add_records(recs):
        now = time.monotonic()
        with lock:
            for r in recs:
                buf.append((now, r))

    def tail_file(path, parse_one):
        if not path.exists():
            return
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            f.seek(0, os.SEEK_END)
            while not stop.is_set():
                line = f.readline()
                if not line:
                    time.sleep(0.2)
                    continue
                r = parse_one(line.rstrip("\n"))
                if r:
                    add_records([r])

    def tail_logcat():
        adb = resolve_adb(args)
        devices, _ = adb_device_state(adb)
        if not devices:
            out.note("(android follow unavailable: no device)")
            return
        cmd = [adb, "logcat", "-v", "year"] + [f"{t}:V" for t in LOGCAT_TAGS] + ["*:S"]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
        except Exception as e:
            out.note(f"(android follow unavailable: {e})")
            return
        try:
            while not stop.is_set():
                line = proc.stdout.readline()
                if not line:
                    break
                recs = parse_logcat(line.rstrip("\n"))
                if recs:
                    add_records(recs)
        finally:
            proc.terminate()

    threads = []
    if "win-py" in sources:
        threads.append(threading.Thread(
            target=tail_file, args=(WIN_PY_LOG, lambda ln: (parse_win_py(ln) or [None])[0]),
            daemon=True))
    if "win-ps" in sources:
        base = datetime.now()
        threads.append(threading.Thread(
            target=tail_file,
            args=(WIN_PS_LOG, lambda ln: (parse_win_ps(ln, base) or [None])[0]), daemon=True))
    if "android" in sources and not args.skip_android:
        threads.append(threading.Thread(target=tail_logcat, daemon=True))
    for t in threads:
        t.start()

    try:
        while True:
            now = time.monotonic()
            with lock:
                ready = [(a, r) for (a, r) in buf if a <= now - hold]
                for item in ready:
                    buf.remove(item)
            for _, r in sorted(ready, key=lambda x: x[1]["dt"]):
                _print_record(out, r)
            time.sleep(0.2)
    except KeyboardInterrupt:
        stop.set()
        with lock:
            for _, r in sorted(buf, key=lambda x: x[1]["dt"]):
                _print_record(out, r)
        print()
    return 0


# --------------------------------------------------------------------------- #
# Subcommand: probe
# --------------------------------------------------------------------------- #

def cmd_probe(args):
    out = Out(args.no_color)
    host, port = resolve_endpoint(args)

    if args.fix_forward and is_loopback(host):
        adb = resolve_adb(args)
        _, flist, _ = run_adb(adb, ["forward", "--list"])
        if f"tcp:{port}" not in (flist or ""):
            run_adb(adb, ["forward", f"tcp:{port}", f"tcp:{port}"])
            out.note(f"(ran `adb forward tcp:{port} tcp:{port}`)")

    if args.simulate:
        res = tcp_probe_simulate(host, port, args.timeout, args.mock_text)
    else:
        p = tcp_probe_ping(host, port, args.timeout)
        res = {"steps": [{"n": 1, "label": "ping", "payload": p.get("heartbeat_status"),
                          "t_ms": p.get("rtt_ms"), "schema_valid": None}],
               "result": "PASS" if p.get("heartbeat_status") else "FAIL",
               "error": p.get("error")}

    if args.with_logcat and not args.skip_android:
        adb = resolve_adb(args)
        devices, _ = adb_device_state(adb)
        if devices:
            recs = collect_android_logcat(adb, 40)
            res["android_tail"] = [r["raw"] for r in recs
                                   if "simulate" in r["msg"].lower() or "Command:" in r["msg"]][-5:]

    if args.json:
        print(json.dumps(res, indent=2, default=str))
        return 0 if res["result"] == "PASS" else 1

    out.head("Hermes Doctor — pipeline probe")
    for s in res["steps"]:
        valid = "" if s.get("schema_valid") is None else \
            (" schema_valid" if s["schema_valid"] else " SCHEMA-INVALID")
        dt = f"  Δ={s['t_ms']} ms" if s.get("t_ms") is not None else ""
        payload = f'  "{s["payload"]}"' if s.get("payload") else ""
        print(f"  ①..④ [{s['n']}] {s['label']}{dt}{payload}{valid}")
    for raw in res.get("android_tail", []):
        out.note(f"    logcat: {raw}")
    status_colour = OK if res["result"] == "PASS" else FAIL
    out.line(status_colour, "result", res["result"] + (f" ({res['error']})" if res.get("error") else ""))
    if is_loopback(host):
        out.note("Caveat: a PASS from WSL does not prove the Windows companion can reach the phone.")
    return 0 if res["result"] == "PASS" else 1


# --------------------------------------------------------------------------- #
# Subcommand: report
# --------------------------------------------------------------------------- #

def cmd_report(args):
    out = Out(args.no_color)
    host, port = resolve_endpoint(args)
    ts = time.strftime("%Y%m%d-%H%M%S")
    out_dir = Path(args.out) if args.out else (REPO_ROOT / ".task" / "hermes-doctor")
    out_dir = out_dir / f"report-{ts}"
    out_dir.mkdir(parents=True, exist_ok=True)

    _, git_branch, _ = run_cmd(["git", "-C", str(REPO_ROOT), "rev-parse", "--abbrev-ref", "HEAD"])
    _, git_sha, _ = run_cmd(["git", "-C", str(REPO_ROOT), "rev-parse", "--short", "HEAD"])
    _, git_dirty, _ = run_cmd(["git", "-C", str(REPO_ROOT), "status", "--porcelain"])

    records, android_ok, reason = collect_logs(args, ["win-py", "win-ps", "android"], args.lines)
    ping = tcp_probe_ping(host, port, args.timeout)
    probe = None
    if not args.no_probe:
        probe = tcp_probe_simulate(host, port, args.timeout,
                                   "Project Hermes automated speech synthesis end to end test")

    report = {
        "generated_at": ts,
        "endpoint": {"host": host, "port": port, "reachable": ping["reachable"],
                     "heartbeat_status": ping["heartbeat_status"], "rtt_ms": ping["rtt_ms"]},
        "git": {"branch": git_branch, "sha": git_sha, "dirty": bool(git_dirty)},
        "env": {k: os.environ.get(k) for k in
                ("HERMES_HOST", "HERMES_PORT", "HERMES_ADB", "WSL_DISTRO_NAME")},
        "config": read_config(),
        "windows": {"python_daemon": check_python_daemon()[1],
                    "powershell_tray": check_powershell_tray(args.timeout)[1]},
        "android": {"available": android_ok, "reason": reason if not android_ok else None},
        "findings": {
            "hotkey": check_hotkey_config(read_config())[:2],
            "error_enum": check_error_enum_drift()[:2],
        },
        "probe": probe,
        "log_tail": [{"dt": r["dt"].isoformat(), "source": r["source"],
                      "level": r["level"], "msg": r["msg"]} for r in records[-args.lines:]],
    }

    json_path = out_dir / f"report-{ts}.json"
    json_path.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")

    md_lines = [
        f"# Hermes Diagnostic Report — {ts}", "",
        f"- Endpoint: `{host}:{port}` — reachable: **{ping['reachable']}** "
        f"(heartbeat: {ping['heartbeat_status']}, rtt: {ping['rtt_ms']} ms)",
        f"- Git: `{git_branch}` @ `{git_sha}`" + (" (dirty)" if git_dirty else ""),
        f"- Android logs available: **{android_ok}**" + (f" ({reason})" if not android_ok else ""),
        "",
        "## Windows processes",
        f"- Python daemon: {report['windows']['python_daemon']}",
        f"- PowerShell tray: {report['windows']['powershell_tray']}",
        "",
        "## Known-issue findings",
        f"- Hotkey ({report['findings']['hotkey'][0]}): {report['findings']['hotkey'][1]}",
        f"- Error enum ({report['findings']['error_enum'][0]}): {report['findings']['error_enum'][1]}",
        "",
        "## Config", "```json", json.dumps(read_config(), indent=2), "```", "",
    ]
    if probe:
        md_lines += ["## Pipeline probe", f"Result: **{probe['result']}**", "```"]
        md_lines += [f"[{s['n']}] {s['label']} {s.get('payload') or ''}" for s in probe["steps"]]
        md_lines += ["```", ""]
    md_lines += ["## Recent unified log tail", "```"]
    md_lines += [f"{r['dt'].strftime('%H:%M:%S')} [{r['source']}] {r['msg']}"
                 for r in records[-args.lines:]]
    md_lines += ["```", ""]
    md_path = out_dir / f"report-{ts}.md"
    md_path.write_text("\n".join(md_lines), encoding="utf-8")

    if args.json_only:
        print(str(json_path.resolve()))
    else:
        out.head("Hermes Doctor — diagnostic report written")
        print(f"  JSON: {json_path.resolve()}")
        print(f"  Markdown: {md_path.resolve()}")
    return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser():
    # Common options shared by every subcommand (usable AFTER the subcommand name).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--host", help="override transport host")
    common.add_argument("--port", type=int, help="override transport port")
    common.add_argument("--adb", help="path to adb binary")
    common.add_argument("--timeout", type=float, default=5.0,
                        help="socket timeout seconds (default 5)")
    common.add_argument("--json", action="store_true", help="machine-readable JSON output")
    common.add_argument("--no-color", action="store_true", help="disable coloured output")
    common.add_argument("--skip-android", action="store_true", help="skip adb/logcat checks")

    p = argparse.ArgumentParser(description="Hermes Doctor — end-to-end diagnostics")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("doctor", parents=[common], help="health check")
    d.add_argument("--strict", action="store_true", help="exit non-zero on any failure")
    d.set_defaults(func=cmd_doctor)

    st = sub.add_parser("status", parents=[common], help="live runtime status")
    st.set_defaults(func=cmd_status)

    lg = sub.add_parser("logs", parents=[common], help="unified cross-device log view")
    lg.add_argument("--lines", type=int, default=100, help="per-source tail size")
    lg.add_argument("--since", help="e.g. 10m, 2h, or ISO datetime")
    lg.add_argument("--follow", action="store_true", help="live tail")
    lg.add_argument("--sources", help="comma list of win-py,win-ps,android")
    lg.set_defaults(func=cmd_logs)

    pr = sub.add_parser("probe", parents=[common], help="active pipeline probe")
    pr.add_argument("--simulate", action="store_true", help="drive simulate_speech")
    pr.add_argument("--mock-text",
                    default="Project Hermes automated speech synthesis end to end test")
    pr.add_argument("--with-logcat", action="store_true", help="correlate with Android logcat")
    pr.add_argument("--fix-forward", action="store_true",
                    help="run `adb forward` if missing (state-changing)")
    pr.set_defaults(func=cmd_probe)

    rp = sub.add_parser("report", parents=[common], help="write a diagnostic bundle")
    rp.add_argument("--out", help="output directory (default .task/hermes-doctor/)")
    rp.add_argument("--lines", type=int, default=300, help="log tail size")
    rp.add_argument("--json-only", action="store_true", help="print only the JSON path")
    rp.add_argument("--no-probe", action="store_true", help="skip the active probe")
    rp.set_defaults(func=cmd_report)
    return p


def main():
    args = build_parser().parse_args()
    try:
        sys.exit(args.func(args))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
