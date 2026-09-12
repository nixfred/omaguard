#!/usr/bin/env bash
# OmaGuard's test suite. Everything runs against a throwaway HOME in a temp dir —
# no test ever reads or writes the real desktop config or the real state dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMAGUARD="$HERE/omaguard.py"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

# ── Runtime assertion: a missing interpreter is a silent outage, not a crash.
if ! command -v python3 >/dev/null; then
  echo "python3 not found — OmaGuard cannot run"; exit 1
fi
ok "python3 present ($(python3 --version 2>&1))"

# Fingerprint the real state dir before anything runs. OmaGuard may already be
# installed here, so "the dir does not exist" is the wrong assertion — "the
# suite did not change it" is the right one.
realstate() { find "$HOME/.local/state/omaguard" -type f -printf '%P %s %T@\n' 2>/dev/null | sort | sha256sum; }
REAL_BEFORE=$(realstate)

ROOT=$(mktemp -d -t omaguard-test-XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
export OMAGUARD_HOME="$ROOT/home" OMAGUARD_STATE="$ROOT/state"
mkdir -p "$OMAGUARD_HOME/.config/hypr" "$OMAGUARD_HOME/.config/omarchy"

cat > "$OMAGUARD_HOME/.config/hypr/input.lua" <<'LUA'
-- a comment mentioning kb_options = "decoy:option"
o.input({ kb_options = "altwin:swap_alt_win" })
LUA
cat > "$OMAGUARD_HOME/.config/hypr/hyprland.lua" <<'LUA'
require("hypr.input")
require("hypr.clipboard")
LUA
cat > "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'JSON'
{"bar":{"id":"nixfred.menubar-overload","layout":{"left":[{"id":"omarchy.clock"}],"center":[],"right":[]}},
 "plugins":{"omarchy.clock":{"seconds":true}},"idle":{"lock":600}}
JSON

g() { python3 "$OMAGUARD" "$@"; }
jq_() { python3 -c "import json,sys;d=json.load(sys.stdin);g=dict(globals());g['d']=d;print(eval(sys.argv[1],g))" "$1"; }

echo; echo "── capture and timeline"
g scan >/dev/null
check "first capture lands"          "$(g status | jq_ 'len(d["timeline"])')" "1"
check "no baseline until accepted"   "$(g status | jq_ 'd["baseline"]')" "None"
check "storage is reported"          "$(g status | jq_ 'd["storage"]["bytes"]>0')" "True"
check "state dir is 0700"            "$(stat -c %a "$ROOT/state")" "700"
check "snapshots are 0600"           "$(stat -c %a "$(find "$ROOT/state" -name '*.json' | head -1)")" "600"

echo; echo "── evidence, not guesses"
check "swap read from the file"      "$(g status | jq_ 'd["latest"]["facts"]["keyboard"]["swapLiteral"]')" "True"
check "commented decoy ignored"      "$(g status | jq_ 'd["latest"]["facts"]["keyboard"]["options"]')" "['altwin:swap_alt_win']"
check "missing file is missing"      "$(g status | jq_ 'd["latest"]["files"]["clipboard"]["status"]')" "missing"
check "missing file is not a pass"   "$(g status | jq_ '[c["status"] for c in d["latest"]["checks"] if c["name"]=="Clipboard policy"][0]')" "unknown"

echo; echo "── drift against an accepted reference"
BASE=$(g status | jq_ 'd["timeline"][-1]["id"]')
g baseline --id="$BASE" >/dev/null
check "reference accepted"           "$(g status | jq_ 'd["baseline"]')" "$BASE"
python3 - "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["plugins"]["omarchy.clock"]["seconds"]=False          # the regression
d["idle"]["lock"]=900                                    # an unrelated change
json.dump(d,open(p,"w"),indent=2)
PY
g scan >/dev/null
check "second capture recorded"      "$(g status | jq_ 'len(d["timeline"])')" "2"
check "the changed file is named"    "$(g status | jq_ 'd["timeline"][-1]["changes"][0]["file"]')" "shell"
check "drift from the reference"     "$(g status | jq_ 'len(d["comparison"]["changes"])')" "1"
check "timeline carries no diffs"    "$(g status | jq_ '"diff" in d["timeline"][-1]["changes"][0]')" "False"

echo; echo "── preview restores one value and nothing else"
LATEST=$(g status | jq_ 'd["timeline"][-1]["id"]')
OUT=$(g preview --id="$BASE" --file=shell --path='["plugins","omarchy.clock","seconds"]')
check "preview is never applied"     "$(echo "$OUT" | jq_ 'd["applied"]')" "False"
check "the regression is undone"     "$(echo "$OUT" | jq_ 'json.loads(d["after"])["plugins"]["omarchy.clock"]["seconds"]')" "True"
check "unrelated change is kept"     "$(echo "$OUT" | jq_ 'json.loads(d["after"])["idle"]["lock"]')" "900"
check "current hash is stated"       "$(echo "$OUT" | jq_ 'len(d["currentHash"])')" "64"
check "nothing was written to disk"  "$(python3 -c "import json;print(json.load(open('$OMAGUARD_HOME/.config/omarchy/shell.json'))['plugins']['omarchy.clock']['seconds'])")" "False"

echo; echo "── refusals"
check "whole shell.json refused"     "$(g preview --id="$BASE" --file=shell | jq_ '"refused" in d["error"]')" "True"
check "array position refused"       "$(g preview --id="$BASE" --file=shell --path='["bar","layout","left","0"]' | jq_ '"moved" in d["error"]')" "True"
check "container swap refused"       "$(g preview --id="$BASE" --file=shell --path='["bar","layout"]' | jq_ '"single value" in d["error"]')" "True"
check "prototype key refused"        "$(g preview --id="$BASE" --file=shell --path='["plugins","__proto__"]' | jq_ 'd["error"]')" "Unsafe field name"
check "unknown file id refused"      "$(g preview --id="$BASE" --file=/etc/shadow | jq_ 'd["error"]')" "Unknown file identifier"
check "bad capture id refused"       "$(g snapshot --id=../../etc/passwd | jq_ 'd["error"]')" "Invalid capture ID"
check "unknown capture refused"      "$(g snapshot --id=11111111-1111-4111-8111-111111111111 | jq_ 'd["error"]')" "Unknown or corrupt capture"
check "errors exit non-zero"         "$(g snapshot --id=bogus >/dev/null 2>&1; echo $?)" "1"

echo; echo "── deletion is explicit and never silent"
check "reference cannot be deleted"  "$(g forget --id="$BASE" | jq_ '"reference" in d["error"]')" "True"
g forget --id="$LATEST" >/dev/null
check "other captures can be"        "$(g status | jq_ 'len(d["timeline"])')" "1"

echo; echo "── symlinks cannot walk OmaGuard out of ~/.config"
mv "$OMAGUARD_HOME/.config/hypr/input.lua" "$ROOT/elsewhere.lua"
ln -s "$ROOT/elsewhere.lua" "$OMAGUARD_HOME/.config/hypr/input.lua"
g scan >/dev/null
check "symlinked config refused"     "$(g status | jq_ 'd["latest"]["files"]["input"]["status"]')" "unavailable"

echo; echo "── profiles: switching goes through a fake shell, never the real bar"
FAKEBIN="$ROOT/bin"; mkdir -p "$FAKEBIN"; CALLS="$ROOT/calls.log"
# A stand-in omarchy-shell that edits the fixture shell.json the way the real
# registry does, and logs every call so the test can assert on the argv.
cat > "$FAKEBIN/omarchy-shell" <<'SH'
#!/usr/bin/env python3
import json, os, sys
cfg = os.path.join(os.environ["OMAGUARD_HOME"], ".config/omarchy/shell.json")
open(os.environ["CALLS"], "a").write(json.dumps(sys.argv[1:]) + "\n")
d = json.load(open(cfg)); L = d["bar"]["layout"]
installed = ["omarchy.clock", "omarchy.battery", "omarchy.network"]
def pull(i):
    for s in L:
        for n, e in enumerate(L[s]):
            if e["id"] == i: return L[s].pop(n)
    return {"id": i}
a = sys.argv[1:]
if a == ["shell", "listPlugins"]:
    print(json.dumps([{"id": i, "kinds": ["bar-widget"]} for i in installed])); sys.exit()
if os.environ.get("FAIL_ON") and os.environ["FAIL_ON"] in a:
    print("refused by shell"); sys.exit()
if a[1] == "setPluginEnabled": pull(a[2])
elif a[1] in ("putBarWidget", "moveBarWidget"):
    e = pull(a[2]); p = json.loads(a[3]); L[p["section"]].insert(p["index"], e)
json.dump(d, open(cfg, "w")); print("ok")
SH
chmod +x "$FAKEBIN/omarchy-shell"
export PATH="$FAKEBIN:$PATH" CALLS
setbar() { python3 - "$OMAGUARD_HOME/.config/omarchy/shell.json" "$1" <<'PY2'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["bar"]["layout"]=json.loads(sys.argv[2]); json.dump(d,open(p,"w"))
PY2
}
setbar '{"left":[{"id":"omarchy.clock"},{"id":"omarchy.battery"}],"center":[],"right":[]}'
g profile-save --name=Work >/dev/null
WORK=$(g profiles | jq_ '[p["id"] for p in d["profiles"] if p["name"]=="Work"][0]')
check "profile captured"             "$(g profiles | jq_ 'd["profiles"][0]["widgets"]')" "2"
check "live bar is the active one"   "$(g profiles | jq_ 'd["profiles"][0]["active"]')" "True"
check "blank name refused"           "$(g profile-save --name='  ' | jq_ 'd["error"]')" "A profile needs a name"
check "duplicate name refused"       "$(g profile-save --name=work | jq_ '"already" in d["error"]')" "True"
setbar '{"left":[{"id":"omarchy.network"}],"center":[],"right":[{"id":"omarchy.clock"}]}'
g profile-save --name=Focus >/dev/null
FOCUS=$(g profiles | jq_ '[p["id"] for p in d["profiles"] if p["name"]=="Focus"][0]')
g profile-favorite --id="$WORK" --value=true >/dev/null
check "favourites sort first"        "$(g profiles | jq_ 'd["profiles"][0]["name"]')" "Work"
g profile-rename --id="$WORK" --name=Desk >/dev/null
check "rename keeps the favourite"   "$(g profiles | jq_ '[p["favorite"] for p in d["profiles"] if p["id"]=="'"$WORK"'"][0]')" "True"
PLAN=$(g profile-plan --id="$WORK")
check "plan removes what leaves"     "$(echo "$PLAN" | jq_ 'd["removes"]')" "['omarchy.network']"
check "plan adds by position"        "$(echo "$PLAN" | jq_ '[(a["id"],a["section"],a["index"]) for a in d["adds"]]')" "[('omarchy.battery', 'left', 1)]"
check "plan moves what moved"        "$(echo "$PLAN" | jq_ '[(m["id"],m["section"]) for m in d["moves"]]')" "[('omarchy.clock', 'left')]"
: > "$CALLS"
OUT=$(g profile-apply --id="$WORK")
check "switch applied"               "$(echo "$OUT" | jq_ 'd["applied"]')" "True"
check "bar matches the profile"      "$(echo "$OUT" | jq_ 'd["exact"]')" "True"
check "only IPC verbs were used"     "$(python3 -c "import json;print(sorted({json.loads(l)[1] for l in open('$CALLS')}))")" "['listPlugins', 'moveBarWidget', 'putBarWidget', 'setPluginEnabled']"
check "now the active profile"       "$(g profiles | jq_ '[p["active"] for p in d["profiles"] if p["id"]=="'"$WORK"'"][0]')" "True"
check "re-apply is a no-op"          "$(g profile-apply --id="$WORK" | jq_ 'd["steps"]')" "[]"
OUT=$(FAIL_ON=putBarWidget g profile-apply --id="$FOCUS")
check "failure is not success"       "$(echo "$OUT" | jq_ 'd["applied"]')" "False"
check "later steps not attempted"    "$(echo "$OUT" | jq_ 'any(s["result"]=="not attempted" for s in d["steps"]) or d["steps"][-1]["ok"] is False')" "True"
setbar '{"left":[{"id":"omarchy.clock"},{"id":"vendor.ghost"}],"center":[],"right":[]}'
g profile-save --name=Ghost >/dev/null
GHOST=$(g profiles | jq_ '[p["id"] for p in d["profiles"] if p["name"]=="Ghost"][0]')
check "missing plugin is named"      "$(g profiles | jq_ '[p["missing"] for p in d["profiles"] if p["name"]=="Ghost"][0]')" "['vendor.ghost']"
check "missing plugin blocks switch" "$(g profile-apply --id="$GHOST" | jq_ '"not installed" in d["error"]')" "True"
check "switching never installs"     "$(grep -c '"add"\|plugin' "$CALLS" 2>/dev/null | head -1)" "0"
python3 - "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'PY2'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["bar"]["id"]="other.bar"; json.dump(d,open(p,"w"))
PY2
check "bar plugin change refused"    "$(g profile-apply --id="$WORK" | jq_ '"different bar" in d["error"]')" "True"
# Put the fixture bar back, or every later test inherits a foreign bar id
# and is refused for a reason it is not testing.
python3 - "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'PY2'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["bar"]["id"]="nixfred.menubar-overload"; json.dump(d,open(p,"w"))
PY2
g profile-forget --id="$GHOST" >/dev/null
check "profile forgotten"            "$(g profiles | jq_ 'len(d["profiles"])')" "2"
check "profiles file is 0600"        "$(stat -c %a "$ROOT/state/profiles.json")" "600"

echo; echo "── profiles: Grok's review cases — duplicates fail closed, partials judged honestly"
setbar '{"left":[{"id":"omarchy.clock"}],"center":[],"right":[]}'
g profile-save --name=Solo >/dev/null
SOLO=$(g profiles | jq_ '[p["id"] for p in d["profiles"] if p["name"]=="Solo"][0]')
setbar '{"left":[{"id":"omarchy.clock"},{"id":"omarchy.clock"}],"center":[],"right":[]}'
OUT=$(g profile-apply --id="$SOLO")
check "two live copies are refused"   "$(echo "$OUT" | jq_ '"more than one copy" in d.get("error","")')" "True"
check "…and never reported as done"   "$(echo "$OUT" | jq_ 'd.get("exact")')" "None"
check "a two-copy bar is not saved"   "$(g profile-save --name=Twins | jq_ '"more than one copy" in d.get("error","")')" "True"
python3 - "$ROOT/state/profiles.json" "$SOLO" <<'PY2'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
for x in d["profiles"]:
    if x["id"]==sys.argv[2]: x["layout"]["sections"]["left"]=["omarchy.clock","omarchy.clock"]
json.dump(d,open(p,"w"))
PY2
chmod 600 "$ROOT/state/profiles.json"
setbar '{"left":[{"id":"omarchy.clock"}],"center":[],"right":[]}'
check "duplicate target is refused"   "$(g profile-apply --id="$SOLO" | jq_ '"more than once" in d.get("error","")')" "True"
g profile-forget --id="$SOLO" >/dev/null
setbar '{"left":[{"id":"omarchy.clock"},{"id":"vendor.ghost"},{"id":"omarchy.battery"}],"center":[],"right":[]}'
python3 - "$ROOT/state" "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'PY2'
import json,os,sys,uuid,time
p=os.path.join(sys.argv[1],"profiles.json"); d=json.load(open(p))
bar=json.load(open(sys.argv[2]))["bar"]["id"]
d["profiles"].append({"id":str(uuid.uuid4()),"name":"Partial","favorite":False,"created":"x","updated":"x",
  "layout":{"barId":bar,"sections":{"left":["vendor.ghost","omarchy.battery","omarchy.clock"],"center":[],"right":[]}}})
json.dump(d,open(p,"w"))
PY2
chmod 600 "$ROOT/state/profiles.json"
setbar '{"left":[{"id":"omarchy.clock"},{"id":"omarchy.battery"}],"center":[],"right":[]}'
PART=$(g profiles | jq_ '[p["id"] for p in d["profiles"] if p["name"]=="Partial"][0]')
OUT=$(g profile-apply --id="$PART" --allow-partial)
check "partial switch builds the rest" "$(python3 -c "import json;print([e['id'] for e in json.load(open('$OMAGUARD_HOME/.config/omarchy/shell.json'))['bar']['layout']['left']])")" "['omarchy.battery', 'omarchy.clock']"
check "partial is exact vs reduced"   "$(echo "$OUT" | jq_ 'd["exact"]')" "True"
check "partial names what it skipped" "$(echo "$OUT" | jq_ '"without vendor.ghost" in d["note"]')" "True"
python3 - "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'PY2'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["bar"]["id"]="other.bar"; json.dump(d,open(p,"w"))
PY2
OUT=$(g profile-apply --id="$PART" --allow-partial)
check "refusal names the real blocker" "$(echo "$OUT" | jq_ '"different bar" in d["error"] and "not installed" not in d["error"]')" "True"
check "plan lists every blocker"      "$(g profile-plan --id="$PART" | jq_ 'sorted(k for k,v in d["blockers"].items() if v)')" "['barChange', 'missing']"
python3 - "$OMAGUARD_HOME/.config/omarchy/shell.json" <<'PY2'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["bar"]["id"]="nixfred.menubar-overload"; json.dump(d,open(p,"w"))
PY2

echo; echo "── profiles: 300 random switches must all land in exact order"
STRESS=$(python3 - "$OMAGUARD" <<'PY2'
import json, os, random, subprocess, sys
guard = sys.argv[1]
home, state = os.environ["OMAGUARD_HOME"], os.environ["OMAGUARD_STATE"] + "-stress"
cfg = os.path.join(home, ".config/omarchy/shell.json")
env = dict(os.environ, OMAGUARD_STATE=state)
# the fake shell above lists omarchy.clock/battery/network; widen it for this run
pool = ["omarchy.clock", "omarchy.battery", "omarchy.network"]
rng = random.Random(20260912)
def layout():
    ids = rng.sample(pool, rng.randint(1, len(pool)))
    L = {"left": [], "center": [], "right": []}
    for i in ids: L[rng.choice(list(L))].append({"id": i})
    return L
def setbar(L): json.dump({"bar": {"id": "x", "layout": L}, "plugins": {}}, open(cfg, "w"))
def g(*a): return json.loads(subprocess.run(["python3", guard, *a], env=env, capture_output=True, text=True).stdout)
norm = lambda L: {s: [e["id"] for e in L[s]] for s in ("left", "center", "right")}
bad = 0
for _ in range(300):
    subprocess.run(["rm", "-rf", state])
    want = layout(); setbar(want)
    pid = g("profile-save", "--name=T")["profiles"][0]["id"]
    setbar(layout())
    out = g("profile-apply", f"--id={pid}")
    # An error reply has no "exact" key at all. Treating a missing key as a
    # pass is how a crashing switch once scored 97% here.
    if "error" in out or out.get("exact") is not True or norm(json.load(open(cfg))["bar"]["layout"]) != norm(want):
        bad += 1
subprocess.run(["rm", "-rf", state])
print(bad)
PY2
)
check "every random switch exact"     "$STRESS" "0"

echo; echo "── rename: an existing Guard state dir carries over once"
MIG="$ROOT/mig"; mkdir -p "$MIG/.local/state/guard" "$MIG/.config/omarchy"
echo '{"schema":1,"profiles":[{"id":"11111111-1111-4111-8111-111111111111","name":"Kept","favorite":true,"created":"x","updated":"x","layout":{"barId":"x","sections":{"left":[],"center":[],"right":[]}}}]}' > "$MIG/.local/state/guard/profiles.json"
cp "$OMAGUARD_HOME/.config/omarchy/shell.json" "$MIG/.config/omarchy/shell.json"
env -u OMAGUARD_STATE OMAGUARD_HOME="$MIG" python3 "$OMAGUARD" profiles >/dev/null
check "legacy state moved"            "$([ -d "$MIG/.local/state/omaguard" ] && [ ! -e "$MIG/.local/state/guard" ] && echo yes)" "yes"
check "profiles survive the rename"   "$(env -u OMAGUARD_STATE OMAGUARD_HOME="$MIG" python3 "$OMAGUARD" profiles | jq_ '[p["name"] for p in d["profiles"]]')" "['Kept']"

echo; echo "── real desktop config was never touched"
check "real OmaGuard state untouched"   "$(realstate)" "$REAL_BEFORE"
check "real shell.json untouched"    "$(grep -c vendor.ghost "$HOME/.config/omarchy/shell.json")" "0"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
