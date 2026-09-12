#!/usr/bin/env python3
"""guard.py — Guard's whole engine. python3 stdlib only, no pip, no bun.

Guard answers one question: *what changed in my desktop, and does what I
chose on purpose still hold?* It captures six allowlisted config files,
keeps a private timeline of every capture, compares the live compositor
against what is saved on disk, and can show a precise before/after for a
recovery.

Guard NEVER writes desktop config. Every restore is a PREVIEW. The only
thing it writes is its own state under ~/.local/state/guard (0700/0600).

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
# Six files, named explicitly. Guard has no "read any path" mode: an
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

HOME = Path(os.environ.get("GUARD_HOME") or Path.home())
STATE = Path(os.environ.get("GUARD_STATE") or (HOME / ".local/state/guard"))


class GuardError(Exception):
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
def secure_state() -> Path:
    """0700 state dir that must not overlap the config Guard watches."""
    state, home = STATE.resolve(), HOME.resolve()
    if state == home or str(state).startswith(str(home / ".config") + os.sep):
        raise GuardError("Guard state must not live inside the config it watches")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state.is_symlink():
        raise GuardError("Guard state directory is a symlink")
    os.chmod(state, 0o700)
    return state


def read_own(path: Path) -> str:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_STORED:
            raise GuardError("Stored file is not a regular file, or is too large")
        return os.read(fd, MAX_STORED).decode("utf-8", "replace")
    finally:
        os.close(fd)


def write_own(name: str, value: object) -> None:
    """Atomic 0600 write: temp file in the same dir, then rename."""
    state = secure_state()
    fd, tmp = tempfile.mkstemp(dir=state, prefix=".guard-", suffix=".tmp")
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
    Guard must never be walked out of ~/.config by a link."""
    if file_id not in FILES:
        raise GuardError("Unknown file identifier")
    path = HOME / ".config" / FILES[file_id]
    try:
        walk = HOME
        for part in Path(".config", FILES[file_id]).parts:
            walk = walk / part
            if walk.is_symlink():
                raise GuardError("Symlink rejected")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise GuardError("Not a regular file")
            if st.st_size > MAX_FILE:
                raise GuardError("Exceeds 1 MiB")
            text = os.read(fd, MAX_FILE).decode("utf-8", "replace")
        finally:
            os.close(fd)
        return {"status": "present", "text": text, "hash": sha(text)}
    except FileNotFoundError:
        return {"status": "missing", "reason": "File not present on this machine"}
    except (GuardError, OSError) as exc:
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
        raise GuardError("Command failed")
    return proc.stdout


def observe_runtime() -> dict:
    """What the machine is actually doing right now, as distinct from what
    is written down. Every probe may be unavailable, and unavailable is a
    first-class answer — never a silent pass."""
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
                    raise GuardError("Service not loaded")
            else:
                data = json.loads(raw)
                if key in ("binds", "configerrors") and not isinstance(data, list):
                    raise GuardError("Unexpected runtime schema")
                if key == "devices" and not isinstance(data.get("keyboards"), list):
                    raise GuardError("Unexpected device schema")
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
    filter, nothing more. Guard never executes Lua and never claims to know
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
    """Each check carries its own certainty. 'evidence' means Guard read it in
    a file; 'observed' means Guard asked the running system; 'unknown' means
    Guard could not tell — which is never reported as a pass."""
    checks: list[dict] = []

    def add(name, status, detail, protected=False):
        checks.append({"name": name, "status": status, "detail": detail,
                       "protected": protected})

    kb = facts["keyboard"]
    add(
        "Alt / Super swap",
        ("ok" if kb["swapLiteral"] else "broken") if kb["options"] else "unknown",
        (f"altwin:swap_alt_win present in every saved literal: {kb['swapLiteral']}. "
         f"Saved: {' → '.join(kb['options'])}. Load order is not inferred.")
        if kb["options"] else "No literal kb_options found in the captured files.",
        protected=True,
    )

    clip = facts["clipboard"]
    aliases = ", ".join(clip["ctrlAliases"]) or "none"
    add(
        "Clipboard policy",
        "unknown" if clip["status"] == "unknown"
        else ("ok" if clip["ctrlAliases"] else "broken"),
        (f"Final textual require is hypr.clipboard: {clip['finalRequire']}. "
         f"Ctrl aliases bound literally: {aliases}. "
         f"omarchy-terminal-paste referenced: {clip['imageHelperReference']}. "
         "Dynamically built binds are not visible to a text scan."),
        protected=True,
    )

    keyboards = (runtime.get("devices", {}).get("data") or {}).get("keyboards")
    if isinstance(keyboards, list) and keyboards:
        lines = []
        for k in keyboards:
            opts = k.get("options") if isinstance(k.get("options"), str) else None
            match = "matches a saved literal" if opts in kb["options"] else "differs from every saved literal"
            lines.append(f"{k.get('name', '?')}: {opts or 'options unavailable'} — {match}")
        live_ok = any(o in kb["options"] for o in
                      (k.get("options") for k in keyboards if isinstance(k.get("options"), str)))
        add("Live keyboard matches disk", "ok" if live_ok else "drift", "\n".join(lines))
    else:
        add("Live keyboard matches disk", "unknown",
            "hyprctl devices unavailable, or it reported no keyboards.")

    binds = runtime.get("binds", {}).get("data")
    if not isinstance(binds, list):
        add("Live Ctrl clipboard handlers", "unknown", "hyprctl binds unavailable.")
    elif not clip["ctrlAliases"]:
        # Nothing was ever asked for, so nothing can have drifted. Reporting
        # "0 handlers" as drift on a machine with no clipboard policy is a
        # false alarm, and false alarms are how a drift tool gets ignored.
        add("Live Ctrl clipboard handlers", "n/a",
            "No Ctrl clipboard aliases are saved on this machine, so there is "
            "nothing for Guard to hold the compositor to.")
    else:
        counts = {
            k: sum(1 for b in binds
                   if b.get("modmask") == 4 and str(b.get("key", "")).upper() == k)
            for k in clip["ctrlAliases"]
        }
        add("Live Ctrl clipboard handlers",
            "ok" if all(counts.values()) else "drift",
            "; ".join(f"Ctrl+{k}: {n} handler(s) live" for k, n in counts.items())
            + " — measured against the aliases your config asks for. "
              "Presence only; behaviour is not verified.")

    errors = runtime.get("configerrors", {}).get("data")
    if isinstance(errors, list):
        # Hyprland reports a clean config as [""], not []. Taking the list
        # length at face value marks a healthy machine BROKEN with an empty
        # reason — exactly the false alarm Guard exists to avoid.
        real = [str(e).strip() for e in errors if str(e).strip()]
        add("Hyprland config errors", "ok" if not real else "broken",
            "Hyprland reports no config errors." if not real
            else "\n".join(real[:10]))
    else:
        add("Hyprland config errors", "unknown", "hyprctl configerrors unavailable.")

    svc = runtime.get("service", {})
    if svc.get("status") == "available":
        data = svc["data"]
        add("Selection-copy service",
            "ok" if data.get("ActiveState") == "active" else "drift",
            " · ".join(f"{k}={v}" for k, v in data.items()))
    else:
        add("Selection-copy service", "unknown", "systemctl --user could not be read.")

    shell = facts["shell"]
    if shell["status"] == "observed":
        widgets = bar_widgets(shell)
        add("Saved bar layout", "ok",
            f"Bar: {shell.get('barId') or 'stock'} · {len(widgets)} widgets placed. "
            + shell["reason"], protected=True)
    else:
        add("Saved bar layout", "unknown", shell["reason"], protected=True)

    return checks


# ── Timeline ─────────────────────────────────────────────────────────────
def load_snapshot(snap_id: str) -> dict:
    if not isinstance(snap_id, str) or not UUID4.match(snap_id):
        raise GuardError("Invalid capture ID")
    try:
        snap = json.loads(read_own(secure_state() / f"{snap_id}.json"))
    except GuardError:
        raise
    except Exception:
        raise GuardError("Unknown or corrupt capture")
    if snap.get("id") != snap_id or "files" not in snap or "time" not in snap:
        raise GuardError("Unknown or corrupt capture")
    return snap


def timeline() -> list[dict]:
    state = secure_state()
    rows = []
    for entry in state.iterdir():
        if not entry.name.endswith(".json") or not UUID4.match(entry.name[:-5]):
            continue
        try:
            snap = load_snapshot(entry.name[:-5])
        except GuardError:
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
    except (FileNotFoundError, GuardError):
        return None
    except Exception:
        return None
    baseline = ref.get("id")
    try:
        load_snapshot(baseline)
    except GuardError:
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
        raise GuardError("Unknown file identifier")
    old, live = snap["files"].get(file_id, {}), read_config(file_id)
    if old.get("status") != "present" or live["status"] != "present":
        raise GuardError("A preview needs both the captured and the current file")

    after = old["text"]
    if file_id == "shell" and path:
        if not (2 <= len(path) <= 12):
            raise GuardError("Choose a specific field, 2 to 12 levels deep")
        for key in path:
            if not isinstance(key, str) or not key or len(key) > 128 or key in FORBIDDEN_KEYS:
                raise GuardError("Unsafe field name")
            if key.isdigit():
                raise GuardError("Array positions are refused — an entry may have moved")
        live_doc, want_doc = json.loads(live["text"]), json.loads(old["text"])

        def locate(doc):
            node = doc
            for key in path[:-1]:
                if not isinstance(node, dict) or key not in node:
                    raise GuardError("That field does not exist in both versions")
                node = node[key]
            if not isinstance(node, dict) or path[-1] not in node:
                raise GuardError("That field does not exist in both versions")
            return node

        here, there = locate(live_doc), locate(want_doc)
        leaf = path[-1]
        if isinstance(there[leaf], (dict, list)) or isinstance(here[leaf], (dict, list)):
            raise GuardError("Pick a single value — Guard will not swap whole sections")
        here[leaf] = there[leaf]
        after = json.dumps(live_doc, indent=2) + "\n"
    elif file_id == "shell":
        raise GuardError("shell.json needs a specific field — whole-file restore is refused")
    elif path:
        raise GuardError("A field path only applies to shell.json")

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
            "meaning": "Your chosen reference. Guard measures drift from here; "
                       "it does not certify that this state is healthy."}


def forget(snap_id: str) -> dict:
    load_snapshot(snap_id)
    if current_baseline() == snap_id:
        raise GuardError("That capture is the accepted reference. Accept another first.")
    (secure_state() / f"{snap_id}.json").unlink()
    return {"forgotten": snap_id}


# ── Profiles: named bar layouts you can switch between ──────────────────
# A profile is a *wanted* state of the bar: which widgets are on it, in which
# section, in what order. Switching applies that through the shell's own IPC
# verbs — putBarWidget / moveBarWidget / setPluginEnabled — one widget at a
# time, inside the process that owns shell.json. Guard never rewrites
# shell.json itself: a dozen agent sessions may be editing the bar at once and
# a whole-file write reverts every one of them.
#
# Switching NEVER installs anything. A profile naming a plugin this machine
# does not have is reported as blocked, with the names, and nothing is applied
# unless you accept a reduced switch explicitly.
PROFILES_FILE = "profiles.json"
SECTIONS = ("left", "center", "right")
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


def load_profiles() -> dict:
    try:
        data = json.loads(read_own(secure_state() / PROFILES_FILE))
    except (FileNotFoundError, GuardError, ValueError):
        return {"schema": 1, "profiles": []}
    if not isinstance(data, dict) or not isinstance(data.get("profiles"), list):
        return {"schema": 1, "profiles": []}
    return data


def save_profiles(data: dict) -> None:
    write_own(PROFILES_FILE, data)


def find_profile(data: dict, pid: str) -> dict:
    for p in data["profiles"]:
        if p.get("id") == pid:
            return p
    raise GuardError("No profile with that ID")


def shell_ipc(args: list[str]) -> str:
    """One omarchy-shell call. Arguments are a fixed argv list — there is no
    shell string anywhere in Guard, so a plugin id can never be interpolated
    into a command."""
    try:
        proc = subprocess.run(
            ["omarchy-shell"] + args,
            stdin=subprocess.DEVNULL, capture_output=True,
            timeout=RUNTIME_TIMEOUT * 3, text=True,
        )
    except FileNotFoundError:
        raise GuardError("omarchy-shell is not on PATH — Guard cannot reach the bar")
    except subprocess.TimeoutExpired:
        raise GuardError("The shell did not answer in time. Nothing was changed.")
    if proc.returncode != 0:
        raise GuardError((proc.stderr or proc.stdout).strip()[:200] or "The shell refused the call")
    return proc.stdout.strip()


def installed_plugins() -> dict:
    """Every plugin the shell has actually discovered, by id. `enabled` here
    means "in the bar" for a bar-widget, which is not the same as a service
    being loaded — Guard only ever uses it for bar widgets."""
    try:
        rows = json.loads(shell_ipc(["shell", "listPlugins"]))
    except (ValueError, GuardError):
        return {}
    return {r["id"]: r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), str)}


def live_layout() -> dict:
    """The bar as it is right now, read from the saved shell.json. Order is the
    whole point: a profile that restores the set but not the order has not
    restored the bar."""
    capture = read_config("shell")
    if capture["status"] != "present":
        raise GuardError("shell.json could not be read, so the bar cannot be captured")
    try:
        doc = json.loads(capture["text"])
        bar = doc["bar"]
        layout = bar.get("layout") or {}
    except Exception:
        raise GuardError("shell.json is not valid JSON, so the bar cannot be captured")
    out = {"barId": bar.get("id"), "sections": {}}
    for section in SECTIONS:
        ids = []
        for entry in layout.get(section) or []:
            if isinstance(entry, dict) and isinstance(entry.get("id"), str):
                ids.append(entry["id"])
            elif isinstance(entry, str):
                ids.append(entry)
        out["sections"][section] = ids
    return out


def duplicate_ids(layout: dict) -> list[str]:
    """Widgets that appear more than once. The shell's verbs address a widget
    by id alone, so two copies of one id cannot be told apart, moved
    separately, or removed one at a time. Guard refuses such a bar rather than
    report a switch it cannot actually perform."""
    seen, dup = set(), set()
    for sec in SECTIONS:
        for w in layout["sections"].get(sec, []):
            (dup if w in seen else seen).add(w)
    return sorted(dup)


def layout_signature(layout: dict) -> str:
    return sha(json.dumps([layout.get("barId"),
                           [layout["sections"].get(s, []) for s in SECTIONS]],
                          sort_keys=True))


def profile_rows(data: dict, live: dict | None = None) -> list[dict]:
    if live is None:
        try:
            live = live_layout()
        except GuardError:
            live = None
    signature = layout_signature(live) if live else None
    have = installed_plugins()
    rows = []
    for p in data["profiles"]:
        widgets = [w for s in SECTIONS for w in p["layout"]["sections"].get(s, [])]
        rows.append({
            "id": p["id"],
            "name": p["name"],
            "favorite": bool(p.get("favorite")),
            "created": p.get("created"),
            "updated": p.get("updated"),
            "barId": p["layout"].get("barId"),
            "widgets": len(widgets),
            # Named, not counted: "3 missing" is not something you can act on.
            "missing": sorted(w for w in widgets if have and w not in have),
            "active": signature is not None and layout_signature(p["layout"]) == signature,
        })
    rows.sort(key=lambda r: (not r["favorite"], r["name"].lower()))
    return rows


def profiles_status() -> dict:
    data = load_profiles()
    try:
        live = live_layout()
        error = ""
    except GuardError as exc:
        live, error = None, str(exc)
    return {
        "profiles": profile_rows(data, live),
        "live": live,
        "liveError": error,
        "canApply": bool(installed_plugins()),
    }


def profile_save(name: str, pid: str = "") -> dict:
    name = (name or "").strip()
    if not name:
        raise GuardError("A profile needs a name")
    if len(name) > 60:
        raise GuardError("That name is too long (60 characters maximum)")
    data = load_profiles()
    if any(p["name"].lower() == name.lower() and p["id"] != pid for p in data["profiles"]):
        raise GuardError(f"You already have a profile called {name!r}")
    layout, now = live_layout(), iso(time.time())
    twins = duplicate_ids(layout)
    if twins:
        raise GuardError("The bar has more than one copy of " + ", ".join(twins)
                         + ". Guard switches widgets by id and cannot tell copies apart, "
                         "so it will not save this bar as a profile.")
    if pid:
        # An overwrite keeps the profile's ID, so favourites, references and
        # anything pointing at this profile survive a re-capture.
        target = find_profile(data, pid)
        target.update({"name": name, "layout": layout, "updated": now})
    else:
        data["profiles"].append({
            "id": str(uuid.uuid4()), "name": name, "favorite": False,
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
            raise GuardError("A profile needs a name")
        if any(p["name"].lower() == name.lower() and p["id"] != pid for p in data["profiles"]):
            raise GuardError(f"You already have a profile called {name!r}")
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
    save_profiles(data)
    return profiles_status()


def profile_plan(pid: str) -> dict:
    """Exactly what switching would do, before anything is done. Every entry
    names a widget — a plan you cannot read is not a plan you can approve."""
    data = load_profiles()
    target = find_profile(data, pid)
    want, live = target["layout"], live_layout()
    have = installed_plugins()
    if not have:
        raise GuardError("The shell did not list any plugins, so a switch cannot be planned")

    wanted = [(s, i, w) for s in SECTIONS
              for i, w in enumerate(want["sections"].get(s, []))]
    wanted_ids = {w for _, _, w in wanted}
    initial = {w: (s, i) for s in SECTIONS
               for i, w in enumerate(live["sections"].get(s, []))}

    missing = sorted(w for _, _, w in wanted if w not in have)
    removes = sorted(w for w in initial if w not in wanted_ids)
    twins_live, twins_want = duplicate_ids(live), duplicate_ids(want)

    # Decide every placement against the bar *as it will be at that step*,
    # not as it was before the switch began. The shell's verbs splice a widget
    # out and insert it at an index, so an add or move judged against the
    # starting layout can land one slot off once an earlier step has shifted
    # its neighbours — a switch that "succeeds" into the wrong order. Walking
    # the target left→right while simulating the same splice semantics makes
    # each index land in a bar where every earlier position is already right.
    sim = {sec: [w for w in live["sections"].get(sec, []) if w in wanted_ids]
           for sec in SECTIONS}
    steps = []
    for sec, idx, w in wanted:
        if w not in have:
            continue
        where = next(((x, sim[x].index(w)) for x in SECTIONS if w in sim[x]), None)
        # Every earlier slot in the target is already correct, so a widget is
        # in place exactly when it sits at (section, index) right now.
        if where == (sec, idx):
            continue
        if where:
            # A widget still waiting to be placed can only sit at or after
            # `idx` in its own section, so popping it never shifts the
            # already-correct slots in front of it.
            sim[where[0]].pop(where[1])
        slot = min(idx, len(sim[sec]))
        sim[sec].insert(slot, w)
        steps.append({"id": w, "section": sec, "index": slot,
                      "verb": "move" if w in initial else "add",
                      "from": where[0] if where else None,
                      "fromIndex": where[1] if where else None})
    adds = [x for x in steps if x["verb"] == "add"]
    moves = [x for x in steps if x["verb"] == "move"]

    # Changing which bar plugin is running is a different, riskier operation
    # than arranging widgets inside one. Guard refuses it rather than doing it
    # halfway.
    bar_change = want.get("barId") != live.get("barId")
    # One message per blocker, keyed by the check that raised it. A single
    # shared reason once told a user to install a plugin when the switch was
    # really refused because it was saved under a different bar.
    blockers = {
        "duplicatesLive": ("The bar has more than one copy of " + ", ".join(twins_live)
                           + "; Guard cannot tell copies apart, so it will not switch.")
                          if twins_live else "",
        "duplicatesProfile": ("This profile lists " + ", ".join(twins_want) + " more than once; "
                              "the shell's controls cannot place two copies of one widget.")
                             if twins_want else "",
        "barChange": (f"This profile was saved under a different bar "
                      f"({want.get('barId')}); Guard will not switch the bar itself.")
                     if bar_change else "",
        "missing": ("This profile needs plugins that are not installed here: "
                    + ", ".join(missing)) if missing else "",
    }
    return {
        "profile": {"id": target["id"], "name": target["name"]},
        "removes": removes, "adds": adds, "moves": moves,
        # The exact order apply will use. adds/moves above are the same steps
        # split by verb, kept for readers of the plan.
        "steps": steps,
        "missing": missing,
        "barChange": {"from": live.get("barId"), "to": want.get("barId")} if bar_change else None,
        "duplicates": {"live": twins_live, "profile": twins_want},
        "blocked": bool(missing) or bar_change or bool(twins_live or twins_want),
        "reason": " ".join(r for r in blockers.values() if r),
        "blockers": blockers,
        # Proven, not inferred: an empty step list can also mean "the planner
        # cannot express what is wrong" (a duplicate it cannot address), and
        # that once reported a two-copy bar as already correct.
        "nothingToDo": layout_signature(live) == layout_signature(want),
    }


def profile_apply(pid: str, allow_partial: bool = False) -> dict:
    """Apply a plan, one supported IPC call at a time, and report what each
    one actually did. A failure part-way through is reported as a partial
    switch with the remaining steps named — never as success."""
    plan = profile_plan(pid)
    b = plan["blockers"]
    for hard in ("duplicatesLive", "duplicatesProfile", "barChange"):
        if b[hard]:
            raise GuardError(b[hard])
    if b["missing"] and not allow_partial:
        raise GuardError(b["missing"] + ". Switch anyway to apply the rest.")
    if plan["nothingToDo"]:
        # Same shape as a real switch. A reply that omits "exact" reads as
        # "not exact" to anything checking it strictly, which turned every
        # already-matching switch into a reported failure.
        return {"applied": True, "exact": True, "profile": plan["profile"],
                "steps": [], "skipped": [],
                "note": "This profile is already what the bar is showing."}

    steps: list[dict] = []
    failed = False

    def step(what: str, widget: str, args: list[str]) -> None:
        nonlocal failed
        if failed:
            steps.append({"action": what, "id": widget, "result": "not attempted"})
            return
        try:
            answer = shell_ipc(args)
        except GuardError as exc:
            answer = str(exc)
        ok = answer == "ok" or answer == ""
        steps.append({"action": what, "id": widget, "result": answer or "ok", "ok": ok})
        if not ok:
            failed = True

    # Remove first, so indices in the target layout are not fighting widgets
    # that are on their way out.
    for widget in plan["removes"]:
        step("remove", widget, ["shell", "setPluginEnabled", widget, "false"])
    # Then place, in target order, exactly as the plan simulated it.
    for entry in plan["steps"]:
        verb = "putBarWidget" if entry["verb"] == "add" else "moveBarWidget"
        step(entry["verb"], entry["id"], ["shell", verb, entry["id"],
                                          json.dumps({"section": entry["section"], "index": entry["index"]})])
    after = live_layout()
    target = find_profile(load_profiles(), pid)["layout"]
    # With --allow-partial the user accepted the profile minus what is not
    # installed, so that reduced bar is what "exact" is measured against.
    if plan["missing"]:
        gone = set(plan["missing"])
        target = {"barId": target.get("barId"),
                  "sections": {sec: [w for w in target["sections"].get(sec, []) if w not in gone]
                               for sec in SECTIONS}}
    matched = layout_signature(after) == layout_signature(target)
    return {
        "applied": not failed,
        "exact": matched,
        "profile": plan["profile"],
        "steps": steps,
        "skipped": plan["missing"],
        "note": (("Switched." if not plan["missing"] else
                  "Switched without " + ", ".join(plan["missing"]) + ", which "
                  + ("is" if len(plan["missing"]) == 1 else "are") + " not installed here.")
                 if matched else
                 "Applied, but the bar does not match the profile exactly — "
                 "read the steps below.") if not failed else
                "Stopped at the first failure. The bar is part-way between two "
                "profiles; the steps below say exactly where.",
    }


VERSION = "1.1.0"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="guard.py", description=__doc__)
    parser.add_argument("command",
                        choices=["scan", "status", "snapshot", "baseline", "preview", "forget",
                                 "profiles", "profile-save", "profile-rename", "profile-favorite",
                                 "profile-forget", "profile-plan", "profile-apply"])
    parser.add_argument("--id", default="")
    parser.add_argument("--file", default="")
    parser.add_argument("--name", default="")
    parser.add_argument("--value", choices=["true", "false"], default="true")
    parser.add_argument("--allow-partial", action="store_true")
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
                    raise GuardError('--path must be a JSON array, e.g. '
                                     '\'["plugins","omarchy.clock","seconds"]\'')
                if not isinstance(path, list):
                    raise GuardError("--path must be a JSON array of key names")
            result = preview(args.id, args.file, path)
    except GuardError as exc:
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
