#!/usr/bin/env python3
"""omaguard.py — OmaGuard's whole engine. python3 stdlib only, no pip, no bun.

OmaGuard answers one question: *what changed in my desktop, and does what I
chose on purpose still hold?* It captures six allowlisted config files,
keeps a private timeline of every capture, compares the live compositor
against what is saved on disk, and can show a precise before/after for a
recovery.

OmaGuard NEVER writes desktop config. Every restore is a PREVIEW. The only
thing it writes is its own state under ~/.local/state/omaguard (0700/0600).

Subcommands (all print one JSON object on stdout):
  scan                        capture now, append to the timeline
  status                      timeline + baseline + newest capture
  snapshot --id=UUID          one capture with its comparison to baseline
  baseline --id=UUID          mark a capture as the reference you accept
  preview --id=UUID --file=ID [--path=a.b.c]   before/after, never applied
  forget --id=UUID            delete one capture (explicit, never automatic)
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

# ── Scope ────────────────────────────────────────────────────────────────
# Six files, named explicitly. OmaGuard has no "read any path" mode: an
# identifier the user cannot influence maps to a path, or nothing happens.
FILES: dict[str, str] = {
    "hyprland": "hypr/hyprland.lua",
    "bindings": "hypr/bindings.lua",
    "input": "hypr/input.lua",
    "clipboard": "hypr/clipboard.lua",
    "keyboardPolicy": "hypr/keyboard-policy.lua",
    "shell": "omarchy/shell.json",
}
LABELS = {
    "hyprland": "Hyprland entry",
    "bindings": "Keybindings",
    "input": "Input / keyboard",
    "clipboard": "Clipboard policy",
    "keyboardPolicy": "Keyboard policy",
    "shell": "Bar & plugins",
}
MAX_FILE = 1 << 20          # 1 MiB per config file
MAX_STORED = 16 << 20       # 16 MiB per stored snapshot
RUNTIME_TIMEOUT = 2.0       # seconds per runtime probe
UUID4 = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

HOME = Path(os.environ.get("OMAGUARD_HOME") or Path.home())
STATE = Path(os.environ.get("OMAGUARD_STATE") or (HOME / ".local/state/omaguard"))


class OmaGuardError(Exception):
    """Anything the user should be told about, verbatim."""


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def diff_text(a: str, b: str) -> str:
    if a == b:
        return "No changes"
    return "\n".join(
        difflib.unified_diff(
            a.splitlines(), b.splitlines(), "before", "after", lineterm="", n=3
        )
    )


# ── Private state ────────────────────────────────────────────────────────
LEGACY_STATE = HOME / ".local/state/guard"


def secure_state() -> Path:
    """0700 state dir that must not overlap the config OmaGuard watches."""
    # Renamed from Guard in 1.2.0. Carry the existing timeline and profiles
    # across once, by rename on the same filesystem, rather than start a new
    # empty history beside the old one. Only for the default location: an
    # explicit OMAGUARD_STATE is never moved or merged.
    if (not os.environ.get("OMAGUARD_STATE") and LEGACY_STATE.is_dir()
            and not LEGACY_STATE.is_symlink() and not STATE.exists()):
        STATE.parent.mkdir(parents=True, exist_ok=True)
        os.rename(LEGACY_STATE, STATE)
    state, home = STATE.resolve(), HOME.resolve()
    if state == home or str(state).startswith(str(home / ".config") + os.sep):
        raise OmaGuardError("OmaGuard state must not live inside the config it watches")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state.is_symlink():
        raise OmaGuardError("OmaGuard state directory is a symlink")
    os.chmod(state, 0o700)
    return state


def read_own(path: Path) -> str:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_STORED:
            raise OmaGuardError("Stored file is not a regular file, or is too large")
        return os.read(fd, MAX_STORED).decode("utf-8", "replace")
    finally:
        os.close(fd)


def write_own(name: str, value: object) -> None:
    """Atomic 0600 write: temp file in the same dir, then rename."""
    state = secure_state()
    fd, tmp = tempfile.mkstemp(dir=state, prefix=".omaguard-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(value, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, state / name)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


# ── Capture ──────────────────────────────────────────────────────────────
def read_config(file_id: str) -> dict:
    """Read one allowlisted file. A symlink anywhere on the path is refused:
    OmaGuard must never be walked out of ~/.config by a link."""
    if file_id not in FILES:
        raise OmaGuardError("Unknown file identifier")
    path = HOME / ".config" / FILES[file_id]
    try:
        walk = HOME
        for part in Path(".config", FILES[file_id]).parts:
            walk = walk / part
            if walk.is_symlink():
                raise OmaGuardError("Symlink rejected")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise OmaGuardError("Not a regular file")
            if st.st_size > MAX_FILE:
                raise OmaGuardError("Exceeds 1 MiB")
            text = os.read(fd, MAX_FILE).decode("utf-8", "replace")
        finally:
            os.close(fd)
        return {"status": "present", "text": text, "hash": sha(text)}
    except FileNotFoundError:
        return {"status": "missing", "reason": "File not present on this machine"}
    except (OmaGuardError, OSError) as exc:
        return {"status": "unavailable", "reason": str(exc) or "Unreadable"}


def run(args: list[str]) -> str:
    proc = subprocess.run(
        args,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=RUNTIME_TIMEOUT,
        text=True,
    )
    if proc.returncode != 0:
        raise OmaGuardError("Command failed")
    return proc.stdout


def observe_runtime() -> dict:
    """What the machine is actually doing right now, as distinct from what
    is written down. Every probe may be unavailable, and unavailable is a
    first-class answer — never a silent pass."""
    fixture = os.environ.get("OMAGUARD_RUNTIME")
    if fixture:
        # Tests only: a recorded runtime, so checks are judged on known
        # evidence instead of whatever compositor the test machine runs.
        try:
            return json.loads(Path(fixture).read_text())
        except Exception:
            return {k: {"status": "unavailable", "reason": "runtime fixture unreadable"}
                    for k in ("binds", "devices", "configerrors", "service")}
    probes = {
        "binds": ["hyprctl", "-j", "binds"],
        "devices": ["hyprctl", "-j", "devices"],
        "configerrors": ["hyprctl", "-j", "configerrors"],
        "service": [
            "systemctl", "--user", "show", "omarchy-selection-copy.service",
            "--property=LoadState,ActiveState,UnitFileState", "--no-pager",
        ],
    }
    out: dict[str, dict] = {}
    for key, args in probes.items():
        try:
            raw = run(args)
            if key == "service":
                data = dict(
                    line.split("=", 1)
                    for line in raw.strip().splitlines()
                    if "=" in line
                )
                if data.get("LoadState") != "loaded":
                    raise OmaGuardError("Service not loaded")
            else:
                data = json.loads(raw)
                if key in ("binds", "configerrors") and not isinstance(data, list):
                    raise OmaGuardError("Unexpected runtime schema")
                if key == "devices" and not isinstance(data.get("keyboards"), list):
                    raise OmaGuardError("Unexpected device schema")
            out[key] = {"status": "available", "data": data}
        except Exception:
            out[key] = {
                "status": "unavailable",
                "reason": "Absent, failed, timed out, or an unsupported schema",
            }
    return out


# ── Evidence ─────────────────────────────────────────────────────────────
LUA_NOISE = re.compile(
    r"--\[(=*)\[[\s\S]*?\]\1\]"          # long comments
    r"|\"(?:\\.|[^\"\\])*\""             # keep: double-quoted strings
    r"|'(?:\\.|[^'\\])*'"                # keep: single-quoted strings
    r"|--[^\n]*"                          # line comments
)


def lua_text(text: str) -> str:
    """Strip Lua comments while preserving quoted strings. This is a lexical
    filter, nothing more. OmaGuard never executes Lua and never claims to know
    what the file would do when loaded."""
    return LUA_NOISE.sub(lambda m: "" if m.group(0).startswith("--") else m.group(0), text)


KB_OPTIONS = re.compile(r"\bkb_options\s*=\s*[\"']([^\"']*)[\"']")
REQUIRE = re.compile(r"^\s*require\s*\(\s*[\"']([^\"']+)[\"']\s*\)\s*;?\s*$", re.M)


def gather_facts(files: dict) -> dict:
    def body(key: str) -> str:
        return lua_text(files.get(key, {}).get("text") or "")

    options = KB_OPTIONS.findall(body("input")) + KB_OPTIONS.findall(body("keyboardPolicy"))
    requires = REQUIRE.findall(body("hyprland"))
    clip = body("clipboard")

    shell: dict = {"status": "unknown", "reason": "Missing or malformed shell.json"}
    try:
        value = json.loads(files["shell"]["text"])
        if not isinstance(value, dict) or not isinstance(value.get("bar"), dict):
            raise ValueError
        shell = {
            "status": "observed",
            "barId": value["bar"].get("id"),
            "layout": value["bar"].get("layout"),
            "plugins": value.get("plugins"),
            "disabledPlugins": value.get("disabledPlugins"),
            "reason": "Saved fields only — presence does not prove a plugin is running",
        }
    except Exception:
        pass

    return {
        "keyboard": {
            "options": options,
            "swapLiteral": (
                all("altwin:swap_alt_win" in v.split(",") for v in options)
                if options else None
            ),
            "requires": requires,
            "status": "textual evidence" if options else "unknown",
        },
        "clipboard": {
            "status": "textual evidence"
            if files.get("clipboard", {}).get("status") == "present" else "unknown",
            "finalRequire": (requires[-1] == "hypr.clipboard") if requires else None,
            "ctrlAliases": [
                k for k in ("C", "X", "V")
                if re.search(r"\b(?:o|hl)\.bind\s*\(\s*[\"']CTRL\s*\+\s*" + k + r"[\"']", clip)
            ],
            "imageHelperReference": bool(
                re.search(r"[\"'](?:[^\"'\n]*/)?omarchy-terminal-paste[\"']", clip)
            ),
        },
        "shell": shell,
    }


def bar_widgets(shell_facts: dict) -> list[str]:
    layout = shell_facts.get("layout")
    if not isinstance(layout, dict):
        return []
    out = []
    for section in ("left", "center", "right"):
        for entry in layout.get(section) or []:
            if isinstance(entry, dict) and isinstance(entry.get("id"), str):
                out.append(f"{section}:{entry['id']}")
            elif isinstance(entry, str):
                out.append(f"{section}:{entry}")
    return out


def build_checks(facts: dict, runtime: dict) -> list[dict]:
    """Every check is judged on the live desktop. A config file only says what
    should be true; OmaGuard reports a problem only when the running compositor
    or systemd confirms it is not. A text scan that finds nothing is never a
    problem: 1.3.0 flagged a working clipboard.lua as broken because it builds
    its binds in a loop, and that warning had no way to clear.

    status: ok | broken (confirmed live) | unknown (could not ask) | n/a."""
    checks: list[dict] = []

    def add(name, status, detail, fix=""):
        checks.append({"name": name, "status": status, "detail": detail, "fix": fix})

    errors = runtime.get("configerrors", {}).get("data")
    if isinstance(errors, list):
        # Hyprland reports a clean config as [""], not [].
        real = [str(e).strip() for e in errors if str(e).strip()]
        if real:
            add("Hyprland config", "broken", "Hyprland reports: " + "; ".join(real[:3]),
                "Open the file named in the error, fix that line, then run: hyprctl reload")
        else:
            add("Hyprland config", "ok", "Hyprland loaded your config without errors.")
    else:
        add("Hyprland config", "unknown", "Hyprland could not be asked for config errors.")

    binds = runtime.get("binds", {}).get("data")
    if facts["clipboard"]["status"] == "unknown":
        add("Clipboard shortcuts", "n/a", "There is no clipboard.lua here, so no clipboard policy to hold.")
    elif not isinstance(binds, list):
        add("Clipboard shortcuts", "unknown",
            "clipboard.lua exists, but Hyprland's live key bindings could not be read.")
    else:
        missing = [k for k in ("C", "X", "V")
                   if not any(b.get("modmask") == 4 and str(b.get("key", "")).upper() == k for b in binds)]
        if missing:
            keys = ", ".join("Ctrl+" + k for k in missing)
            add("Clipboard shortcuts", "broken",
                f"clipboard.lua is in your config, but the running desktop has nothing bound to {keys}.",
                "Run: hyprctl reload. If it is still missing, the Hyprland config check will name the bad line.")
        else:
            add("Clipboard shortcuts", "ok", "Ctrl+C, Ctrl+X and Ctrl+V are bound in the running desktop.")

    kb = facts["keyboard"]
    wants_swap = any("altwin:swap_alt_win" in o.split(",") for o in kb["options"])
    keyboards = (runtime.get("devices", {}).get("data") or {}).get("keyboards")
    if not wants_swap:
        add("Alt / Super swap", "n/a", "Your config does not swap Alt and Super.")
    elif not isinstance(keyboards, list):
        add("Alt / Super swap", "unknown",
            "Your config swaps Alt and Super, but Hyprland's keyboards could not be read.")
    else:
        reported = [k for k in keyboards if isinstance(k.get("options"), str)]
        applied = [k for k in reported if "altwin:swap_alt_win" in k["options"].split(",")]
        if not reported:
            add("Alt / Super swap", "unknown", "Hyprland reported no keyboard options.")
        elif not applied:
            add("Alt / Super swap", "broken",
                "Your config swaps Alt and Super, but no keyboard in the running desktop has the swap.",
                "Run: hyprctl reload")
        else:
            add("Alt / Super swap", "ok", f"Applied on {plural(len(applied), 'keyboard')}.")

    svc = runtime.get("service", {})
    if svc.get("status") == "available":
        state = svc["data"].get("ActiveState", "unknown")
        if state == "active":
            add("Copy on select", "ok", "The selection-copy service is running.")
        else:
            add("Copy on select", "broken", f"The selection-copy service is installed but {state}.",
                "Run: systemctl --user restart omarchy-selection-copy.service")
    else:
        add("Copy on select", "n/a", "The selection-copy service is not installed here, or systemd could not be read.")
    return checks


def health() -> dict:
    """The live checks on their own: nothing is written, no snapshot taken."""
    files = {key: read_config(key) for key in FILES}
    checks = build_checks(gather_facts(files), observe_runtime())
    return {"checks": checks, "problems": [c for c in checks if c["status"] == "broken"],
            "checkedAt": iso(time.time())}


# ── Timeline ─────────────────────────────────────────────────────────────
def load_snapshot(snap_id: str) -> dict:
    if not isinstance(snap_id, str) or not UUID4.match(snap_id):
        raise OmaGuardError("Invalid capture ID")
    try:
        snap = json.loads(read_own(secure_state() / f"{snap_id}.json"))
    except OmaGuardError:
        raise
    except Exception:
        raise OmaGuardError("Unknown or corrupt capture")
    if snap.get("id") != snap_id or "files" not in snap or "time" not in snap:
        raise OmaGuardError("Unknown or corrupt capture")
    return snap


def timeline() -> list[dict]:
    state = secure_state()
    rows = []
    for entry in state.iterdir():
        if not entry.name.endswith(".json") or not UUID4.match(entry.name[:-5]):
            continue
        try:
            snap = load_snapshot(entry.name[:-5])
        except OmaGuardError:
            continue
        rows.append({
            "id": snap["id"],
            "time": snap["time"],
            # Headlines only. A full diff is fetched per capture on demand —
            # a timeline that inlines every diff grows without bound and the
            # panel pays for history it is not showing.
            "changes": [{k: c[k] for k in ("file", "label", "kind") if k in c}
                        for c in snap.get("changes", [])],
            "summary": summarize(snap.get("changes", [])),
            "broken": [c["name"] for c in snap.get("checks", []) if c.get("status") == "broken"],
        })
    rows.sort(key=lambda r: (r["time"], r["id"]))
    return rows


def summarize(changes: list) -> str:
    if not changes:
        return "No change since the previous capture"
    return ", ".join(f"{LABELS.get(c['file'], c['file'])} {c['kind']}" for c in changes)


def current_baseline() -> str | None:
    try:
        ref = json.loads(read_own(secure_state() / "baseline.json"))
    except (FileNotFoundError, OmaGuardError):
        return None
    except Exception:
        return None
    baseline = ref.get("id")
    try:
        load_snapshot(baseline)
    except OmaGuardError:
        return None
    return baseline


def compare_to_baseline(snap: dict) -> dict:
    baseline = current_baseline()
    if not baseline:
        return {"baseline": None, "changes": [],
                "meaning": "No reference accepted yet. A capture alone is not proof "
                           "the machine is healthy — accept one you trust."}
    if baseline == snap["id"]:
        return {"baseline": baseline, "changes": [],
                "meaning": "This capture is the accepted reference."}
    ref = load_snapshot(baseline)
    changes = []
    for key in FILES:
        a, b = ref["files"].get(key, {}), snap["files"].get(key, {})
        if a.get("hash") != b.get("hash") or a.get("status") != b.get("status"):
            changes.append({
                "file": key,
                "label": LABELS[key],
                "diff": diff_text(a.get("text", f"[{a.get('status')}]"),
                                  b.get("text", f"[{b.get('status')}]")),
            })
    for change in changes:
        change["summary"] = summarize_change(change["file"], ref["files"].get(change["file"], {}),
                                             snap["files"].get(change["file"], {}))
    return {"baseline": baseline, "changes": changes,
            "meaning": "Differences from the reference you accepted. "
                       "Different is not automatically wrong."}


def scan() -> dict:
    history = timeline()
    previous = load_snapshot(history[-1]["id"]) if history else None
    files = {key: read_config(key) for key in FILES}

    changes = []
    if previous:
        for key in FILES:
            a, b = previous["files"].get(key, {}), files[key]
            if a.get("status") != b.get("status") or a.get("hash") != b.get("hash"):
                kind = ("added" if a.get("status") == "missing" and b["status"] == "present"
                        else "removed" if a.get("status") == "present" and b["status"] == "missing"
                        else "unavailable" if "unavailable" in (a.get("status"), b["status"])
                        else "changed")
                changes.append({
                    "file": key, "label": LABELS[key], "kind": kind,
                    "diff": diff_text(a.get("text", f"[{a.get('status')}]"),
                                      b.get("text", f"[{b['status']}]")),
                })

    runtime = observe_runtime()
    facts = gather_facts(files)
    # Monotonic: two captures inside the same second must still order stably.
    now = time.time()
    if previous:
        now = max(now, parse_time(previous["time"]) + 0.001)
    snap = {
        "id": str(uuid.uuid4()),
        "time": iso(now),
        "files": files,
        "facts": facts,
        "runtime": runtime,
        "checks": build_checks(facts, runtime),
        "changes": changes,
        "source": "unknown",
    }
    write_own(f"{snap['id']}.json", snap)
    return snap


def iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(epoch)) + f".{int(epoch % 1 * 1000):03d}Z"


def parse_time(text: str) -> float:
    try:
        base = time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
        return time.mktime(base) - time.timezone + int(text[20:23] or 0) / 1000
    except Exception:
        return 0.0


def storage() -> dict:
    state = secure_state()
    total = sum(f.stat().st_size for f in state.iterdir() if f.is_file())
    return {"path": str(state), "bytes": total,
            "captures": len([f for f in state.iterdir() if UUID4.match(f.name[:-5] or "")])}


def status() -> dict:
    rows = timeline()
    latest = load_snapshot(rows[-1]["id"]) if rows else None
    return {
        "version": VERSION,
        "baseline": current_baseline(),
        "timeline": rows,
        "files": FILES,
        "labels": LABELS,
        "storage": storage(),
        "latest": strip(latest) if latest else None,
        "comparison": compare_to_baseline(latest) if latest else None,
    }


def strip(snap: dict) -> dict:
    """The panel never needs whole file bodies — those are fetched per diff."""
    light = dict(snap)
    light["files"] = {
        k: {kk: vv for kk, vv in v.items() if kk != "text"}
        for k, v in snap["files"].items()
    }
    return light


# ── Preview (never applies) ──────────────────────────────────────────────
FORBIDDEN_KEYS = {"__proto__", "prototype", "constructor"}


def preview(snap_id: str, file_id: str, path: list[str] | None) -> dict:
    snap = load_snapshot(snap_id)
    if file_id not in FILES:
        raise OmaGuardError("Unknown file identifier")
    old, live = snap["files"].get(file_id, {}), read_config(file_id)
    if old.get("status") != "present" or live["status"] != "present":
        raise OmaGuardError("A preview needs both the captured and the current file")

    after = old["text"]
    if file_id == "shell" and path:
        if not (2 <= len(path) <= 12):
            raise OmaGuardError("Choose a specific field, 2 to 12 levels deep")
        for key in path:
            if not isinstance(key, str) or not key or len(key) > 128 or key in FORBIDDEN_KEYS:
                raise OmaGuardError("Unsafe field name")
            if key.isdigit():
                raise OmaGuardError("Array positions are refused — an entry may have moved")
        live_doc, want_doc = json.loads(live["text"]), json.loads(old["text"])

        def locate(doc):
            node = doc
            for key in path[:-1]:
                if not isinstance(node, dict) or key not in node:
                    raise OmaGuardError("That field does not exist in both versions")
                node = node[key]
            if not isinstance(node, dict) or path[-1] not in node:
                raise OmaGuardError("That field does not exist in both versions")
            return node

        here, there = locate(live_doc), locate(want_doc)
        leaf = path[-1]
        if isinstance(there[leaf], (dict, list)) or isinstance(here[leaf], (dict, list)):
            raise OmaGuardError("Pick a single value — OmaGuard will not swap whole sections")
        here[leaf] = there[leaf]
        after = json.dumps(live_doc, indent=2) + "\n"
    elif file_id == "shell":
        raise OmaGuardError("shell.json needs a specific field — whole-file restore is refused")
    elif path:
        raise OmaGuardError("A field path only applies to shell.json")

    return {
        "applied": False,
        "label": "PREVIEW ONLY — nothing was written",
        "file": file_id,
        "fileLabel": LABELS[file_id],
        "path": path,
        "capture": snap_id,
        "capturedAt": snap["time"],
        "currentHash": live["hash"],
        "before": live["text"],
        "after": after,
        "diff": diff_text(live["text"], after),
        "note": ("Only the one value you picked differs. Everything else in the "
                 "current file is kept.") if file_id == "shell" else
                ("The whole captured file, for you to read against the current one. "
                 "The hash above is the precondition for any manual restore."),
    }


def accept_baseline(snap_id: str) -> dict:
    load_snapshot(snap_id)
    write_own("baseline.json", {"id": snap_id, "acceptedAt": iso(time.time())})
    return {"baseline": snap_id,
            "meaning": "Your chosen reference. OmaGuard measures drift from here; "
                       "it does not certify that this state is healthy."}


def forget(snap_id: str) -> dict:
    load_snapshot(snap_id)
    if current_baseline() == snap_id:
        raise OmaGuardError("That capture is the accepted reference. Accept another first.")
    (secure_state() / f"{snap_id}.json").unlink()
    return {"forgotten": snap_id}


# ── Profiles: named bar layouts you can switch between ──────────────────
# A profile is a *wanted* state of the bar: which widgets are on it, in which
# section, in what order, and which are pinned to a zone. Switching applies
# that through the shell's own IPC verbs — putBarWidget / moveBarWidget /
# setPluginEnabled / setBarWidget — one widget at a time, inside the process
# that owns shell.json. OmaGuard never rewrites shell.json itself.
#
# Switching NEVER installs anything. A profile naming a plugin this machine
# does not have is reported as blocked, with the names, and nothing is applied
# unless you accept a reduced switch explicitly.
PROFILES_FILE = "profiles.json"
RENAMED_WIDGET = ("nixfred.guard", "nixfred.omaguard")
SECTIONS = ("left", "center", "right")
# Bars like menubar-overload draw each side as zones: an entry marked "outer"
# or "inner" stays pinned there whatever its position in the list. Order alone
# does not describe such a bar — a switch that restores order but not pins
# changes shell.json while the bar looks exactly the same.
ZONES = ("outer", "inner")
# How long a switch waits for the shell to write shell.json before judging it.
SETTLE_SECONDS = float(os.environ.get("OMAGUARD_SETTLE_SECONDS") or 3.0)


def load_profiles() -> dict:
    try:
        data = json.loads(read_own(secure_state() / PROFILES_FILE))
    except (FileNotFoundError, OmaGuardError, ValueError):
        return {"schema": 1, "profiles": []}
    if not isinstance(data, dict) or not isinstance(data.get("profiles"), list):
        return {"schema": 1, "profiles": []}
    # Renamed from Guard in 1.2.0: rewrite the widget id in place, once, and
    # never where the profile already carries the new id.
    changed = False
    for prof in data["profiles"]:
        sections = (prof.get("layout") or {}).get("sections") or {}
        ids = [w for sec in SECTIONS for w in sections.get(sec, [])]
        if RENAMED_WIDGET[0] in ids and RENAMED_WIDGET[1] not in ids:
            for sec in SECTIONS:
                sections[sec] = [RENAMED_WIDGET[1] if w == RENAMED_WIDGET[0] else w
                                 for w in sections.get(sec, [])]
            zones = (prof.get("layout") or {}).get("zones")
            if isinstance(zones, dict) and RENAMED_WIDGET[0] in zones:
                zones[RENAMED_WIDGET[1]] = zones.pop(RENAMED_WIDGET[0])
            changed = True
    if changed:
        save_profiles(data)
    return data


def save_profiles(data: dict) -> None:
    write_own(PROFILES_FILE, data)


def find_profile(data: dict, pid: str) -> dict:
    for p in data["profiles"]:
        if p.get("id") == pid:
            return p
    raise OmaGuardError("No profile with that ID")


def shell_ipc(args: list[str]) -> str:
    """One omarchy-shell call. Arguments are a fixed argv list — there is no
    shell string anywhere in OmaGuard, so a plugin id can never be
    interpolated into a command."""
    try:
        proc = subprocess.run(
            ["omarchy-shell"] + args,
            stdin=subprocess.DEVNULL, capture_output=True,
            timeout=RUNTIME_TIMEOUT * 3, text=True,
        )
    except FileNotFoundError:
        raise OmaGuardError("omarchy-shell is not on PATH — OmaGuard cannot reach the bar")
    except subprocess.TimeoutExpired:
        raise OmaGuardError("The shell did not answer in time. Nothing was changed.")
    if proc.returncode != 0:
        raise OmaGuardError((proc.stderr or proc.stdout).strip()[:200] or "The shell refused the call")
    return proc.stdout.strip()


def installed_plugins() -> dict:
    try:
        rows = json.loads(shell_ipc(["shell", "listPlugins"]))
    except (ValueError, OmaGuardError):
        return {}
    return {r["id"]: r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), str)}


def live_layout() -> dict:
    """The bar as it is right now: order per section, plus pinned zones."""
    capture = read_config("shell")
    if capture["status"] != "present":
        raise OmaGuardError("shell.json could not be read, so the bar cannot be captured")
    try:
        doc = json.loads(capture["text"])
        bar = doc["bar"]
        layout = bar.get("layout") or {}
    except Exception:
        raise OmaGuardError("shell.json is not valid JSON, so the bar cannot be captured")
    out = {"barId": bar.get("id"), "sections": {}, "zones": {}}
    for section in SECTIONS:
        ids = []
        for entry in layout.get(section) or []:
            if isinstance(entry, dict) and isinstance(entry.get("id"), str):
                ids.append(entry["id"])
                if entry.get("zone") in ZONES:
                    out["zones"][entry["id"]] = entry["zone"]
            elif isinstance(entry, str):
                ids.append(entry)
        out["sections"][section] = ids
    return out


def has_zones(layout: dict) -> bool:
    return isinstance(layout.get("zones"), dict)


def duplicate_ids(layout: dict) -> list[str]:
    """Widgets that appear more than once. The shell's verbs address a widget
    by id alone, so two copies cannot be told apart. OmaGuard refuses such a
    bar rather than report a switch it cannot actually perform."""
    seen, dup = set(), set()
    for sec in SECTIONS:
        for w in layout["sections"].get(sec, []):
            (dup if w in seen else seen).add(w)
    return sorted(dup)


def layout_signature(layout: dict, with_zones: bool = True) -> str:
    parts = [layout.get("barId"), [layout["sections"].get(s, []) for s in SECTIONS]]
    if with_zones:
        parts.append(sorted((layout.get("zones") or {}).items()))
    return sha(json.dumps(parts, sort_keys=True))


def same_layout(profile_layout: dict, live: dict) -> bool:
    # A profile saved before pins were recorded can only be compared on order.
    zones = has_zones(profile_layout)
    return layout_signature(profile_layout, zones) == layout_signature(live, zones)


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def name_list(ids, limit: int = 4) -> str:
    ids = list(ids)
    head = ", ".join(ids[:limit])
    return head + (f" and {len(ids) - limit} more" if len(ids) > limit else "")


def compute_plan(want: dict, live: dict, have: dict) -> dict:
    """Every step a switch would take, decided against the bar as it will be
    at that step. Pure: no IPC, so the panel can describe every profile."""
    all_wanted = [(s, w) for s in SECTIONS for w in want["sections"].get(s, [])]
    missing = sorted({w for _, w in all_wanted if w not in have})
    # Positions come from the profile *minus* what is not installed, so a
    # skipped widget never shifts the widgets after it.
    wanted = [(s, i, w) for s in SECTIONS
              for i, w in enumerate([x for x in want["sections"].get(s, []) if x in have])]
    wanted_ids = {w for _, _, w in wanted}
    initial = {w: (s, i) for s in SECTIONS
               for i, w in enumerate(live["sections"].get(s, []))}
    removes = sorted(w for w in initial if w not in wanted_ids and w not in missing)
    twins_live, twins_want = duplicate_ids(live), duplicate_ids(want)

    # The shell's verbs splice a widget out and insert it at an index. Walking
    # the target left→right while simulating the same splice makes each index
    # land in a bar where every earlier position is already right.
    sim = {sec: [w for w in live["sections"].get(sec, []) if w in wanted_ids] for sec in SECTIONS}
    steps = []
    for sec, idx, w in wanted:
        where = next(((x, sim[x].index(w)) for x in SECTIONS if w in sim[x]), None)
        if where == (sec, idx):
            continue
        if where:
            sim[where[0]].pop(where[1])
        slot = min(idx, len(sim[sec]))
        sim[sec].insert(slot, w)
        steps.append({"id": w, "section": sec, "index": slot,
                      "verb": "move" if w in initial else "add",
                      "from": where[0] if where else None,
                      "fromIndex": where[1] if where else None})

    zone_steps = []
    if has_zones(want):
        wz, lz = want["zones"], live.get("zones") or {}
        for _, _, w in wanted:
            target, current = wz.get(w, ""), lz.get(w, "")
            if target != current:
                zone_steps.append({"id": w, "verb": "zone", "zone": target, "from": current})

    bar_change = want.get("barId") != live.get("barId")
    blockers = {
        "duplicatesLive": ("The bar has more than one copy of " + ", ".join(twins_live)
                           + "; OmaGuard cannot tell copies apart, so it will not switch.")
                          if twins_live else "",
        "duplicatesProfile": ("This layout lists " + ", ".join(twins_want) + " more than once; "
                              "the shell cannot place two copies of one widget.")
                             if twins_want else "",
        "barChange": (f"This layout was saved with a different bar style "
                      f"({want.get('barId')}); OmaGuard will not change the bar style itself.")
                     if bar_change else "",
        "missing": ("This layout needs plugins that are not installed here: "
                    + ", ".join(missing)) if missing else "",
    }
    adds = [x for x in steps if x["verb"] == "add"]
    moves = [x for x in steps if x["verb"] == "move"]
    words = []
    if moves:
        words.append("move " + plural(len(moves), "widget"))
    if adds:
        words.append("put back " + name_list(x["id"] for x in adds))
    if removes:
        words.append("take off " + name_list(removes))
    if zone_steps:
        words.append("re-pin " + plural(len(zone_steps), "widget"))
    return {
        "removes": removes, "adds": adds, "moves": moves, "steps": steps,
        "zones": zone_steps, "missing": missing,
        "duplicates": {"live": twins_live, "profile": twins_want},
        "barChange": {"from": live.get("barId"), "to": want.get("barId")} if bar_change else None,
        "blockers": blockers,
        "blocked": any(blockers.values()),
        "reason": " ".join(r for r in blockers.values() if r),
        "summary": (" and ".join([", ".join(words[:-1]), words[-1]]) if len(words) > 1
                    else (words[0] if words else "")),
    }


def profile_rows(data: dict, live: dict | None, have: dict) -> list[dict]:
    rows = []
    for p in data["profiles"]:
        layout = p["layout"]
        widgets = [w for s in SECTIONS for w in layout["sections"].get(s, [])]
        plan = compute_plan(layout, live, have) if live and have else None
        active = bool(live) and same_layout(layout, live)
        twins = [q["name"] for q in data["profiles"] if q is not p
                 and layout_signature(q["layout"], has_zones(q["layout"]) and has_zones(layout))
                 == layout_signature(layout, has_zones(q["layout"]) and has_zones(layout))]
        rows.append({
            "id": p["id"],
            "name": p["name"],
            "favorite": bool(p.get("favorite")),
            "created": p.get("created"),
            "updated": p.get("updated"),
            "barId": layout.get("barId"),
            "widgets": len(widgets),
            "pinned": len(layout.get("zones") or {}),
            "missing": plan["missing"] if plan else [],
            "active": active,
            # Saved before OmaGuard recorded pin zones: a switch can restore
            # the order, never the pins, and the panel says so.
            "incomplete": not has_zones(layout),
            "sameAs": twins,
            "blocked": bool(plan and plan["blocked"]),
            "reason": plan["reason"] if plan else "The bar could not be read.",
            # What differs, as a person sees it. The plan's step count
            # overstates it: one real move shifts every widget after it, and
            # "loading will move 10 widgets" read as a far bigger change than
            # the two widgets that actually differ.
            "changes": "; ".join(summarize_layout(layout, live)) if live and not active else "",
            "canSwitch": bool(plan) and not active and not plan["blocked"],
        })
    rows.sort(key=lambda r: (not r["favorite"], r["name"].lower()))
    return rows


def profiles_status() -> dict:
    data = load_profiles()
    try:
        live = live_layout()
        error = ""
    except OmaGuardError as exc:
        live, error = None, str(exc)
    have = installed_plugins()
    return {
        "profiles": profile_rows(data, live, have),
        "live": live,
        "liveError": error or ("" if have else "The shell did not list its plugins, so switching is unavailable."),
        "canApply": bool(have),
    }


def profile_save(name: str, pid: str = "") -> dict:
    name = (name or "").strip()
    if not name:
        raise OmaGuardError("A profile needs a name")
    if len(name) > 60:
        raise OmaGuardError("That name is too long (60 characters maximum)")
    data = load_profiles()
    if any(p["name"].lower() == name.lower() and p["id"] != pid for p in data["profiles"]):
        raise OmaGuardError(f"You already have a profile called {name!r}")
    layout, now = live_layout(), iso(time.time())
    twins = duplicate_ids(layout)
    if twins:
        raise OmaGuardError("The bar has more than one copy of " + ", ".join(twins)
                            + ". OmaGuard switches widgets by id and cannot tell copies apart, "
                            "so it will not save this bar as a profile.")
    if pid:
        target = find_profile(data, pid)
        target.update({"name": name, "layout": layout, "updated": now})
        data["loaded"] = pid
    else:
        new_id = str(uuid.uuid4())
        data["loaded"] = new_id
        data["profiles"].append({
            "id": new_id, "name": name, "favorite": False,
            "created": now, "updated": now, "layout": layout,
        })
    save_profiles(data)
    return profiles_status()


def profile_set(pid: str, *, name: str | None = None, favorite: bool | None = None) -> dict:
    data = load_profiles()
    target = find_profile(data, pid)
    if name is not None:
        name = name.strip()
        if not name:
            raise OmaGuardError("A profile needs a name")
        if any(p["name"].lower() == name.lower() and p["id"] != pid for p in data["profiles"]):
            raise OmaGuardError(f"You already have a profile called {name!r}")
        target["name"] = name
    if favorite is not None:
        target["favorite"] = favorite
    target["updated"] = iso(time.time())
    save_profiles(data)
    return profiles_status()


def profile_forget(pid: str) -> dict:
    data = load_profiles()
    find_profile(data, pid)
    data["profiles"] = [p for p in data["profiles"] if p["id"] != pid]
    if data.get("loaded") == pid:
        data["loaded"] = None
    save_profiles(data)
    return profiles_status()


def profile_plan(pid: str) -> dict:
    data = load_profiles()
    target = find_profile(data, pid)
    live, have = live_layout(), installed_plugins()
    if not have:
        raise OmaGuardError("The shell did not list any plugins, so a switch cannot be planned")
    plan = compute_plan(target["layout"], live, have)
    plan["profile"] = {"id": target["id"], "name": target["name"]}
    # Proven, not inferred: an empty step list can also mean "the planner
    # cannot express what is wrong".
    plan["nothingToDo"] = same_layout(target["layout"], live)
    plan["incomplete"] = not has_zones(target["layout"])
    return plan


def profile_apply(pid: str, allow_partial: bool = False) -> dict:
    """Apply a plan one supported IPC call at a time and report what each
    call did. A failure part-way is reported as partial — never as success."""
    plan = profile_plan(pid)
    b = plan["blockers"]
    for hard in ("duplicatesLive", "duplicatesProfile", "barChange"):
        if b[hard]:
            raise OmaGuardError(b[hard])
    if b["missing"] and not allow_partial:
        raise OmaGuardError(b["missing"] + ". Switch anyway to apply the rest.")
    if plan["nothingToDo"]:
        set_loaded(pid)
        return {"applied": True, "exact": True, "profile": plan["profile"],
                "steps": [], "skipped": [], "incomplete": plan["incomplete"],
                "note": "This layout is already what the bar is showing."}

    steps: list[dict] = []
    failed = False

    def step(what: str, widget: str, args: list[str]) -> None:
        nonlocal failed
        if failed:
            steps.append({"action": what, "id": widget, "result": "not attempted"})
            return
        try:
            answer = shell_ipc(args)
        except OmaGuardError as exc:
            answer = str(exc)
        ok = answer in ("ok", "")
        steps.append({"action": what, "id": widget, "result": answer or "ok", "ok": ok})
        if not ok:
            failed = True

    for widget in plan["removes"]:
        step("remove", widget, ["shell", "setPluginEnabled", widget, "false"])
    for entry in plan["steps"]:
        verb = "putBarWidget" if entry["verb"] == "add" else "moveBarWidget"
        step(entry["verb"], entry["id"], ["shell", verb, entry["id"],
                                          json.dumps({"section": entry["section"], "index": entry["index"]})])
    for entry in plan["zones"]:
        step("pin" if entry["zone"] else "unpin", entry["id"],
             ["shell", "setBarWidget", entry["id"], "zone", json.dumps(entry["zone"]), "{}"])

    target = find_profile(load_profiles(), pid)["layout"]
    if plan["missing"]:
        gone = set(plan["missing"])
        target = {"barId": target.get("barId"),
                  "sections": {sec: [w for w in target["sections"].get(sec, []) if w not in gone]
                               for sec in SECTIONS},
                  **({"zones": {w: z for w, z in target["zones"].items() if w not in gone}}
                     if has_zones(target) else {})}
    # The shell answers each verb before it writes shell.json. Reading the
    # file straight away judged a switch that had fully landed as "does not
    # match exactly" — measured in the Test Drive VM, where the same bar read
    # correct two seconds later. Wait for the file to catch up, bounded.
    after, matched = live_layout(), False
    if not failed:
        deadline = time.monotonic() + SETTLE_SECONDS
        while True:
            after = live_layout()
            matched = same_layout(target, after)
            if matched or time.monotonic() >= deadline:
                break
            time.sleep(0.15)
    else:
        matched = same_layout(target, after)
    name = plan["profile"]["name"]
    if failed:
        note = ("Stopped at the first failure. The bar is part-way between two layouts; "
                "the steps below say exactly where.")
    elif matched:
        note = f"Switched to {name}."
        if plan["missing"]:
            note = f"Switched to {name} without {', '.join(plan['missing'])}, which is not installed here."
        if plan["incomplete"]:
            note += (" This layout was saved before OmaGuard remembered pinned widgets, so pins "
                     "were left as they were.")
    else:
        note = "Applied, but the bar does not match the layout exactly — read the steps below."
    if not failed and matched:
        set_loaded(pid)
    return {
        "applied": not failed,
        "exact": matched,
        "profile": plan["profile"],
        "steps": steps,
        "skipped": plan["missing"],
        "incomplete": plan["incomplete"],
        "note": note,
    }


# ── Layouts are your setups ─────────────────────────────────────────────
# One idea: the loaded layout. Loading one makes it loaded; a later bar change
# is "unsaved changes" to it, answered by Save, Undo or Save as new.
def set_loaded(pid: str | None) -> None:
    data = load_profiles()
    data["loaded"] = pid
    save_profiles(data)


def summarize_layout(want: dict, live: dict) -> list[str]:
    """What differs between a saved layout and the bar, in sentences."""
    out = []
    wsec = {w: s for s in SECTIONS for w in want["sections"].get(s, [])}
    lsec = {w: s for s in SECTIONS for w in live["sections"].get(s, [])}
    added = [w for w in lsec if w not in wsec]
    removed = [w for w in wsec if w not in lsec]
    if added:
        out.append("Added to the bar: " + name_list(added))
    if removed:
        out.append("Taken off the bar: " + name_list(removed))
    moved = [w for w in lsec if w in wsec and wsec[w] != lsec[w]]
    for sec in SECTIONS:
        a = [w for w in want["sections"].get(sec, []) if lsec.get(w) == sec]
        b = [w for w in live["sections"].get(sec, []) if wsec.get(w) == sec]
        keep = _lcs(a, b)
        moved += [w for w in b if w not in keep]
    moved = list(dict.fromkeys(moved))
    if moved:
        out.append(plural(len(moved), "widget") + " moved: " + name_list(moved))
    if has_zones(want):
        wz, lz = want["zones"], live.get("zones") or {}
        pins = [w for w in lsec if w in wsec and wz.get(w, "") != lz.get(w, "")]
        if pins:
            out.append(plural(len(pins), "widget") + " pinned or unpinned: " + name_list(pins))
    if want.get("barId") != live.get("barId"):
        out.append("Bar style changed")
    return out


def layouts_status(result: dict | None = None, adopt: bool = False) -> dict:
    if adopt:
        adopt_new_widgets()
    data = load_profiles()
    try:
        live, error = live_layout(), ""
    except OmaGuardError as exc:
        live, error = None, str(exc)
    have = installed_plugins()
    rows = profile_rows(data, live, have)
    ids = {r["id"] for r in rows}
    loaded = data.get("loaded") if data.get("loaded") in ids else None
    detected = False
    if not loaded:
        # Nothing loaded yet, but the bar matches a saved layout exactly: that
        # layout is what you are using, so say so instead of "not saved".
        match = next((r for r in rows if r["active"]), None)
        if match:
            loaded, detected = match["id"], True
    profile = next((p for p in data["profiles"] if p["id"] == loaded), None)
    unsaved = bool(profile and live and not same_layout(profile["layout"], live))
    changes = summarize_layout(profile["layout"], live) if unsaved else []
    if unsaved and not changes:
        changes = ["The bar differs from this layout"]
    undo_reason = ""
    if unsaved:
        row = next(r for r in rows if r["id"] == loaded)
        undo_reason = row["reason"] if row["blocked"] else ""
    for r in rows:
        r["loaded"] = r["id"] == loaded
    h = health()
    out = {
        "version": VERSION,
        "layouts": rows,
        "loaded": loaded,
        "loadedName": profile["name"] if profile else None,
        "detected": detected,
        "unsaved": unsaved,
        "unsavedChanges": changes,
        "canUndo": unsaved and not undo_reason,
        "undoReason": undo_reason,
        "problems": h["problems"],
        "checks": h["checks"],
        "checkedAt": h["checkedAt"],
        "liveError": error or ("" if have else "The shell did not list its plugins, so layouts can't be loaded."),
        "lastAction": last_action(),
    }
    if result is not None:
        out["result"] = result
    return out


# The bar rebuilds every widget in a section whenever shell.json changes, so
# the OmaGuard widget is destroyed by the first move of any switch it runs —
# measured in Test Drive: a new widget instance after every IPC move, the
# switch killed part-way, its result gone with the old instance. Layout
# actions therefore run detached from the widget and leave their outcome
# here, where whichever widget instance exists next can read it.
LAST_ACTION_FILE = "last-action.json"
INTERRUPTED_AFTER = 60.0
LAYOUT_ACTIONS = {
    "layout-load": "Loading a layout", "layout-save": "Saving",
    "layout-save-as": "Saving as new", "layout-undo": "Undoing",
    "layout-rename": "Renaming", "layout-delete": "Deleting",
    "layout-update": "Updating", "layout-favorite": "Starring",
    "layout-adopt": "Adding new widgets",
}
# A load in progress moves widgets onto the bar that belong to the *new*
# layout; adopting them into the old one would corrupt it. Adoption waits this
# long after any layout action.
ADOPT_QUIET_SECONDS = float(os.environ.get("OMAGUARD_ADOPT_QUIET_SECONDS") or 10)


def record_action(action: str, payload: dict) -> None:
    now = time.time()
    write_own(LAST_ACTION_FILE, {"action": action, "label": LAYOUT_ACTIONS.get(action, action),
                                 "at": iso(now), "epoch": now, **payload})


def last_action() -> dict | None:
    try:
        rec = json.loads(read_own(secure_state() / LAST_ACTION_FILE))
    except Exception:
        return None
    if not isinstance(rec, dict):
        return None
    if rec.get("pending") and time.time() - float(rec.get("epoch") or 0) > INTERRUPTED_AFTER:
        # Never let a dead action read as still running, or as done.
        rec = {**rec, "pending": False, "ok": False, "interrupted": True,
               "note": rec.get("label", "The last action") + " did not finish. Check the bar, then try again."}
    return rec


def run_layout_action(command: str, args) -> dict:
    record_action(command, {"pending": True})
    try:
        if command == "layout-load":
            out = layout_load(args.id)
        elif command == "layout-save":
            out = layout_save()
        elif command == "layout-save-as":
            out = layout_save_as(args.name)
        elif command == "layout-undo":
            out = layout_undo()
        elif command == "layout-rename":
            out = layout_rename(args.id, args.name)
        elif command == "layout-update":
            out = layout_update(args.id)
        elif command == "layout-favorite":
            out = layout_favorite(args.id, args.value == "true")
        else:
            out = layout_delete(args.id)
    except Exception as exc:
        record_action(command, {"pending": False, "ok": False, "note": str(exc) or type(exc).__name__})
        raise
    r = out.get("result") or {}
    ok = r.get("ok") is True or (r.get("applied") is True and r.get("exact") is not False)
    record_action(command, {"pending": False, "ok": ok, "note": r.get("note", ""),
                            "steps": [st for st in r.get("steps", []) if st.get("ok") is False or st.get("result") == "not attempted"]})
    out["lastAction"] = last_action()
    return out


def adopt_new_widgets() -> list[str]:
    """Widgets you added to the bar join the loaded layout, where you put them.

    Only additions. A move or a removal stays an unsaved change for you to
    Save or Undo, so an accidental drag is never silently kept. Nothing is
    adopted while a layout action is running or just after one."""
    recent = last_action()
    if recent and (recent.get("pending")
                   or time.time() - float(recent.get("epoch") or 0) < ADOPT_QUIET_SECONDS):
        return []
    data = load_profiles()
    prof = next((p for p in data["profiles"] if p["id"] == data.get("loaded")), None)
    if not prof:
        return []
    try:
        live = live_layout()
    except OmaGuardError:
        return []
    if duplicate_ids(live):
        return []
    have = installed_plugins()
    want = prof["layout"]
    known = {w for sec in SECTIONS for w in want["sections"].get(sec, [])}
    added = []
    for sec in SECTIONS:
        target = want["sections"].setdefault(sec, [])
        row = live["sections"].get(sec, [])
        for i, w in enumerate(row):
            if w in known or (have and w not in have):
                continue
            # After the nearest widget to its left that the layout already has.
            before = [x for x in row[:i] if x in target]
            target.insert(target.index(before[-1]) + 1 if before else 0, w)
            known.add(w)
            added.append(w)
            zone = (live.get("zones") or {}).get(w)
            if zone and has_zones(want):
                want["zones"][w] = zone
    if added:
        prof["updated"] = iso(time.time())
        save_profiles(data)
        record_action("layout-adopt", {"pending": False, "ok": True,
                                       "note": f"Added {name_list(added)} to {prof['name']}."})
    return added


def layout_update(pid: str) -> dict:
    name = find_profile(load_profiles(), pid)["name"]
    profile_save(name, pid)
    return layouts_status({"ok": True, "note": f"Updated {name} to your bar as it is now. It is your loaded layout."})


def layout_favorite(pid: str, on: bool) -> dict:
    name = find_profile(load_profiles(), pid)["name"]
    profile_set(pid, favorite=on)
    return layouts_status({"ok": True, "note": f"{name} is {'a favourite' if on else 'no longer a favourite'}."})


def layout_load(pid: str) -> dict:
    return layouts_status(profile_apply(pid))


def layout_save() -> dict:
    data = load_profiles()
    loaded = data.get("loaded")
    if not loaded or not any(p["id"] == loaded for p in data["profiles"]):
        raise OmaGuardError("No layout is loaded to save into. Use Save as new to name this bar.")
    name = find_profile(data, loaded)["name"]
    profile_save(name, loaded)
    return layouts_status({"ok": True, "note": f"Saved the bar into {name}."})


def layout_save_as(name: str) -> dict:
    profile_save(name)
    return layouts_status({"ok": True, "note": f"Saved as {name.strip()}. It is now your loaded layout."})


def layout_undo() -> dict:
    data = load_profiles()
    loaded = data.get("loaded")
    if not loaded or not any(p["id"] == loaded for p in data["profiles"]):
        raise OmaGuardError("No layout is loaded, so there is nothing to go back to.")
    result = profile_apply(loaded)
    if result.get("applied") and result.get("exact"):
        result["note"] = "Undone. The bar is back to " + result["profile"]["name"] + "."
    return layouts_status(result)


def layout_rename(pid: str, name: str) -> dict:
    profile_set(pid, name=name)
    return layouts_status({"ok": True, "note": f"Renamed to {name.strip()}."})


def layout_delete(pid: str) -> dict:
    name = find_profile(load_profiles(), pid)["name"]
    profile_forget(pid)
    return layouts_status({"ok": True, "note": f"Deleted {name}."})


# ── Plain-language change summaries ─────────────────────────────────────
def _lcs(a: list, b: list) -> set:
    """Items on the longest common ordered subsequence: everything else moved."""
    n, m = len(a), len(b)
    t = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            t[i][j] = t[i + 1][j + 1] + 1 if a[i] == b[j] else max(t[i + 1][j], t[i][j + 1])
    keep, i, j = set(), 0, 0
    while i < n and j < m:
        if a[i] == b[j]:
            keep.add(a[i]); i += 1; j += 1
        elif t[i + 1][j] >= t[i][j + 1]:
            i += 1
        else:
            j += 1
    return keep


def summarize_change(file_id: str, before: dict, after: dict) -> list[str]:
    """What changed, in words a person reads — not a diff."""
    if before.get("status") != "present" and after.get("status") == "present":
        return ["This file appeared"]
    if before.get("status") == "present" and after.get("status") != "present":
        return ["This file is gone"]
    at, bt = before.get("text"), after.get("text")
    if at is None or bt is None:
        return ["This file could not be read"]
    if file_id != "shell":
        n = sum(1 for line in diff_text(at, bt).splitlines()
                if line[:1] in "+-" and not line.startswith(("+++", "---")))
        return [plural(n, "line") + " changed"]
    try:
        ad, bd = json.loads(at), json.loads(bt)
    except ValueError:
        return ["shell.json could not be parsed"]

    def entries(doc):
        lay = ((doc.get("bar") or {}).get("layout") or {}) if isinstance(doc, dict) else {}
        found = {}
        for sec in SECTIONS:
            for e in lay.get(sec) or []:
                if isinstance(e, dict) and isinstance(e.get("id"), str):
                    found[e["id"]] = (sec, e)
        return found, lay

    ea, la = entries(ad)
    eb, lb = entries(bd)
    out = []
    added = [w for w in eb if w not in ea]
    removed = [w for w in ea if w not in eb]
    if added:
        out.append("Added to the bar: " + name_list(added))
    if removed:
        out.append("Taken off the bar: " + name_list(removed))
    moved = [w for w in eb if w in ea and ea[w][0] != eb[w][0]]
    for sec in SECTIONS:
        sa = [e["id"] for e in la.get(sec) or [] if isinstance(e, dict) and e.get("id") in eb and eb[e["id"]][0] == sec]
        sb = [e["id"] for e in lb.get(sec) or [] if isinstance(e, dict) and e.get("id") in ea and ea[e["id"]][0] == sec]
        keep = _lcs(sa, sb)
        moved += [w for w in sb if w not in keep]
    moved = list(dict.fromkeys(moved))
    if moved:
        out.append(plural(len(moved), "widget") + " moved: " + name_list(moved))
    pins = [w for w in eb if w in ea and (ea[w][1].get("zone") or "") != (eb[w][1].get("zone") or "")]
    if pins:
        out.append(plural(len(pins), "widget") + " pinned or unpinned: " + name_list(pins))
    strip_keys = lambda e: {k: v for k, v in e.items() if k not in ("id", "zone")}
    tweaked = [w for w in eb if w in ea and strip_keys(ea[w][1]) != strip_keys(eb[w][1])]
    if tweaked:
        out.append("Widget settings changed: " + name_list(tweaked))
    if isinstance(ad, dict) and isinstance(bd, dict):
        if (ad.get("bar") or {}).get("id") != (bd.get("bar") or {}).get("id"):
            out.append("Bar style changed")
        other = sorted(k for k in set(ad) | set(bd) if k != "bar" and ad.get(k) != bd.get(k))
        if other:
            out.append("Other shell settings changed: " + name_list(other))
    return out or ["Formatting only — nothing that changes the bar"]


def accept_current() -> dict:
    """One click: take a snapshot of the setup as it is now and make it the
    good setup. This is what clears a drift warning you agree with."""
    snap = scan()
    accept_baseline(snap["id"])
    return status()


VERSION = "1.5.1"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="omaguard.py", description=__doc__)
    parser.add_argument("command",
                        choices=["scan", "status", "snapshot", "baseline", "preview", "forget",
                                 "profiles", "profile-save", "profile-rename", "profile-favorite",
                                 "profile-forget", "profile-plan", "profile-apply", "accept-current",
                                 "health", "layouts", "layout-load", "layout-save", "layout-save-as",
                                 "layout-undo", "layout-rename", "layout-delete",
                                 "layout-update", "layout-favorite"])
    parser.add_argument("--id", default="")
    parser.add_argument("--file", default="")
    parser.add_argument("--name", default="")
    parser.add_argument("--value", choices=["true", "false"], default="true")
    parser.add_argument("--allow-partial", action="store_true")
    parser.add_argument("--adopt", action="store_true",
                        help="layouts: add widgets that are new on the bar to the loaded layout")
    # A JSON array, not a dotted string: every Omarchy plugin key is itself
    # dotted ("plugins" → "omarchy.clock" → "seconds"), so a "." separator
    # can never address the one thing this tool exists to restore.
    parser.add_argument("--path", default="", metavar='\'["plugins","omarchy.clock","seconds"]\'')
    args = parser.parse_args(argv)

    try:
        if args.command == "scan":
            scan()
            result = status()
        elif args.command == "status":
            result = status()
        elif args.command == "snapshot":
            snap = load_snapshot(args.id)
            result = {**strip(snap), "comparison": compare_to_baseline(snap)}
        elif args.command == "baseline":
            accept_baseline(args.id)
            result = status()
        elif args.command == "health":
            result = health()
        elif args.command == "layouts":
            result = layouts_status(adopt=args.adopt)
        elif args.command in LAYOUT_ACTIONS:
            result = run_layout_action(args.command, args)
        elif args.command == "accept-current":
            result = accept_current()
        elif args.command == "profiles":
            result = profiles_status()
        elif args.command == "profile-save":
            result = profile_save(args.name, args.id)
        elif args.command == "profile-rename":
            result = profile_set(args.id, name=args.name)
        elif args.command == "profile-favorite":
            result = profile_set(args.id, favorite=args.value == "true")
        elif args.command == "profile-forget":
            result = profile_forget(args.id)
        elif args.command == "profile-plan":
            result = profile_plan(args.id)
        elif args.command == "profile-apply":
            result = profile_apply(args.id, args.allow_partial)
        elif args.command == "forget":
            forget(args.id)
            result = status()
        else:
            path = None
            if args.path:
                try:
                    path = json.loads(args.path)
                except ValueError:
                    raise OmaGuardError('--path must be a JSON array, e.g. '
                                     '\'["plugins","omarchy.clock","seconds"]\'')
                if not isinstance(path, list):
                    raise OmaGuardError("--path must be a JSON array of key names")
            result = preview(args.id, args.file, path)
    except OmaGuardError as exc:
        json.dump({"error": str(exc)}, sys.stdout)
        sys.stdout.write("\n")
        return 1
    except Exception as exc:  # never a traceback on stdout
        json.dump({"error": f"{type(exc).__name__}: {exc}"}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
