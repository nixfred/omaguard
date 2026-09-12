<p align="center">
  <img src="docs/hero.svg" alt="OmaGuard — a shield in your Omarchy bar" width="100%">
</p>

<p align="center">
  <b>Keep my Omarchy mine.</b><br>
  A shield in the bar that remembers what your desktop used to look like.
</p>

<p align="center">
  <img alt="Omarchy plugin" src="https://img.shields.io/badge/Omarchy-plugin-7dd3a8?style=flat-square">
  <img alt="python3 stdlib only" src="https://img.shields.io/badge/python3-stdlib%20only-5b8def?style=flat-square">
  <img alt="Preview-only restore" src="https://img.shields.io/badge/restore-preview%20only-e3b75f?style=flat-square">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-8b94a7?style=flat-square">
</p>

---

You spend an afternoon getting the bar exactly right. Alt and Super swapped the way your
hands expect. Ctrl+V pasting images into the terminal. Twenty-odd widgets in the order you
chose. Then an update lands, or an agent "helpfully" tidies a config file, or you try
something and forget to undo it — and a week later something feels off and you cannot
say what.

**OmaGuard answers two questions from the bar:** *what changed?* and *does what I chose on
purpose still hold?* And because you rarely want just one bar, it keeps named **profiles**
you can switch between with one click.

## What it looks like

<p align="center">
  <img src="docs/panel.png" alt="The OmaGuard panel open on a live Omarchy desktop, showing the Desk profile starred in the quick switch" width="760">
</p>

The shield sits on the left of the bar. Its colour is the verdict:

| Shield | State | Means |
|:---:|---|---|
| 🟢 | **holding** | Every preference you protect still reads the way you left it |
| 🟡 | **drift** | Something changed since the reference you accepted |
| 🔴 | **broken** | A protected preference is gone, or Hyprland is reporting config errors |
| ⚪ | **unknown** | OmaGuard has not been told what "correct" is yet — never shown as a pass |

Click it for three views: **Profiles**, **Preferences** and **Timeline**.

## Profiles: one click between bar layouts

<p align="center">
  <img src="docs/profiles.svg" alt="Starred profiles in the quick switch; switching moves widgets through the shell's own IPC" width="100%">
</p>

A profile remembers which widgets are on the bar, in which section, and in what order.
Arrange the bar, type a name — *Work*, *Focus*, *Present* — and press **Save current bar**.
Star it (☆ → ★) and it appears under **SWITCH TO** at the top of the panel.

Switching is deliberately conservative:

- **It never installs anything.** A profile that needs a plugin this machine does not have
  is marked ⚠, names the missing plugin, and refuses to switch.
- **It never rewrites `shell.json`.** Each widget is removed, placed or moved through the
  shell's own IPC — `setPluginEnabled`, `putBarWidget`, `moveBarWidget` — inside the process
  that owns the file. Other tools editing the bar at the same time keep their changes.
- **It never switches the bar plugin itself.** A profile saved under a different bar is
  refused rather than half-applied.
- **A failure is never reported as success.** OmaGuard stops at the first refused step and
  shows exactly which widgets moved and which were not attempted.
- **Renaming keeps identity.** Profiles have stable IDs, so a renamed favourite stays a
  favourite.

## Preferences: evidence, not guesses

OmaGuard reads six files — and only these six:

```
~/.config/hypr/hyprland.lua        ~/.config/hypr/clipboard.lua
~/.config/hypr/bindings.lua        ~/.config/hypr/keyboard-policy.lua
~/.config/hypr/input.lua           ~/.config/omarchy/shell.json
```

…and asks the running system what it is actually doing (`hyprctl -j binds / devices /
configerrors`, `systemctl --user show omarchy-selection-copy.service`). Every check says
where its answer came from:

- **evidence** — OmaGuard read it in a file
- **observed** — OmaGuard asked the live compositor or systemd
- **unknown** — OmaGuard could not tell, and says so

OmaGuard **never executes Lua**. It strips comments lexically and matches exact literals, so
it can tell you `altwin:swap_alt_win` is written in every `kb_options` it found — not what
Hyprland would compute after loading every file. Dynamically built binds are invisible to
a text scan, and OmaGuard's own output says that.

## Timeline: every capture, kept until you say otherwise

Press **Capture now** and OmaGuard stores a snapshot. Nothing expires automatically; storage
used is shown in the panel header, and **Forget** removes one capture on purpose.

A first capture is a *candidate*, not a clean bill of health. You decide which capture is
your **reference** — the state you accept — and OmaGuard measures drift from there.

Open any capture to see what differs from your reference as a unified diff, and preview
putting a single value back:

```text
PREVIEW ONLY — nothing was written
Bar & plugins  ·  current hash 3f9a1c07b2e4…

-  "seconds": false
+  "seconds": true

Only the one value you picked differs. Everything else in the current file is kept.
```

OmaGuard refuses to preview a whole `shell.json`, a whole section, or an array position
(entries may have moved) — because restoring those silently reverts changes you made
since. The hash is the precondition for any manual restore: if the file has changed
since the preview, the preview no longer describes it.

## Install

OmaGuard needs nothing beyond a stock Omarchy install: `python3` (Omarchy depends on it
through `uwsm` and `kitty`) and the shell's own `omarchy-shell`. No bun, no node, no pip.

```bash
git clone https://github.com/nixfred/omaguard ~/.config/omarchy/plugins/nixfred.omaguard
omarchy-shell shell rescanPlugins
omarchy-shell shell putBarWidget nixfred.omaguard '{"section":"left","index":3}'
```

Or add it from **Settings → Plugins**. If the widget does not appear after a plugin
change, `omarchy restart shell` (never `omarchy refresh shell`, which resets the bar to
defaults).

## Use it from a terminal

Everything the panel does is `omaguard.py`, and every command prints one JSON object:

```bash
cd ~/.config/omarchy/plugins/nixfred.omaguard

python3 omaguard.py scan                          # capture now
python3 omaguard.py status                        # timeline, reference, newest capture
python3 omaguard.py baseline --id=<capture>       # accept a reference
python3 omaguard.py preview  --id=<capture> --file=shell \
                          --path='["plugins","omarchy.clock","seconds"]'

python3 omaguard.py profile-save --name=Focus     # save the bar as it is now
python3 omaguard.py profile-favorite --id=<profile> --value=true
python3 omaguard.py profile-plan  --id=<profile>  # what a switch would do
python3 omaguard.py profile-apply --id=<profile>  # do it
```

Field paths are JSON arrays, not dotted strings: every Omarchy plugin key is itself dotted
(`omarchy.clock`), so a `.` separator could never reach the settings OmaGuard exists to
restore.

The widget has IPC too:

```bash
omarchy-shell nixfred.omaguard toggle
omarchy-shell nixfred.omaguard scan
omarchy-shell nixfred.omaguard switchTo Focus
omarchy-shell nixfred.omaguard status
```

Bind `switchTo` to a key and your profiles are one chord away.

## How it is built

```mermaid
flowchart LR
    subgraph Bar["Omarchy shell"]
      W["OmaGuardPanel.qml<br/>shield · panel · IPC"]
    end
    W -- "python3 omaguard.py …<br/>(argv list, no shell)" --> G["omaguard.py<br/>stdlib only"]
    G -- "read, no symlinks,<br/>1 MiB cap" --> C["six allowlisted<br/>config files"]
    G -- "hyprctl -j · systemctl --user<br/>2 s timeout each" --> R["live system"]
    G -- "0700 dir · 0600 files<br/>atomic rename" --> S["~/.local/state/omaguard"]
    G -- "setPluginEnabled<br/>putBarWidget · moveBarWidget" --> I["omarchy-shell IPC"]
    I --> Bar
```

- **The widget owns its data.** There is no `service` entry point. Under a third-party
  bar, `bar.shell.serviceFor()` returns `null` for every plugin — including a widget's own
  service — and nothing logs it. OmaGuard runs its helper directly so it works under any bar.
- **No command strings.** Every subprocess is a fixed argv list; a plugin id or profile
  name is never interpolated into a shell.
- **A silent outage is not allowed to look calm.** A missing `python3` (exit 127), an empty
  reply or a timeout turns the shield red with the reason in the panel.

## Safety limits, stated plainly

- OmaGuard **writes only its own state**: `~/.local/state/omaguard` (0700), files 0600, atomic.
- OmaGuard **never writes desktop config** during capture or preview. Restores are previews.
- Profile switching **does** change the bar — through the shell's supported IPC, one widget
  at a time, and only when you click a profile.
- Captures can include anything you put in those six files. They stay on this machine;
  OmaGuard makes no network calls.
- A reference is a choice, not a certification. *Different* is not automatically *wrong*.

## Tests

```bash
./tests/test.sh
```

65 checks against a throwaway `HOME` with a fake `omarchy-shell` on `PATH`, including 300
random profile switches that must each land in exact order. The suite
fingerprints your real OmaGuard state and `shell.json` before it starts and fails if either
changes.

## Remove OmaGuard

```bash
omarchy plugin disable nixfred.omaguard
rm -rf ~/.config/omarchy/plugins/nixfred.omaguard
rm -rf ~/.local/state/omaguard        # your captures and profiles — only if you want them gone
```

## License

MIT © Fred Nix
