import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaGuard — a shield in the bar that knows what your desktop used to look like.
//
//   󰕥 holding     every preference you marked still reads the way you left it
//   󰻌 drift       something moved since the reference you accepted
//   󰦝 broken      a preference you protect is gone, or Hyprland is erroring
//   󰞀 unknown     OmaGuard has not been told what "correct" is yet
//
// The shield is the glance; the panel is the record. OmaGuard owns its own data:
// it runs omaguard.py itself rather than going through a service, because under a
// third-party bar `bar.shell.serviceFor()` returns null for every id — a
// plugin's own service included — and nothing logs when it does.
//
// OmaGuard never writes desktop config. Restores are previews: a before, an
// after, and the hash the current file must still have for that plan to mean
// anything. Applying it stays a human decision.
Panel {
    id: root
    moduleName: "nixfred.omaguard"
    manageIpc: false
    implicitWidth: barButton.implicitWidth
    implicitHeight: barButton.implicitHeight

    readonly property string version: "1.2.0"
    property var state: ({})
    property string lastError: ""
    property bool busy: false
    property string selectedId: ""
    property var detail: null
    property var previewResult: null

    readonly property var timeline: state.timeline || []
    readonly property var latest: state.latest || null
    readonly property var comparison: state.comparison || null
    readonly property var checks: latest ? (latest.checks || []) : []
    readonly property bool hasReference: !!state.baseline

    // ── What the shield says ──────────────────────────────────────────────
    // Only a check OmaGuard actually resolved can change the verdict. "unknown"
    // never reads as healthy, and it never reads as an alarm either.
    readonly property var broken: checks.filter(function (c) { return c.status === "broken" })
    readonly property var drifted: checks.filter(function (c) { return c.status === "drift" })
    readonly property int changedFiles: comparison ? (comparison.changes || []).length : 0
    readonly property string verdict: {
        if (lastError && !latest) return "fault"
        if (!latest) return "unknown"
        if (broken.length) return "broken"
        if (!hasReference) return "unknown"
        if (drifted.length || changedFiles) return "drift"
        return "holding"
    }
    readonly property string glyph: ({
        holding: "󰕥", drift: "󰻌", broken: "󰦝", unknown: "󰞀", fault: "󰦝"
    })[verdict]
    readonly property color tint: ({
        holding: Color.accent,
        drift: warn,
        broken: Color.urgent,
        unknown: Qt.alpha(Color.popups.text, 0.55),
        fault: Color.urgent
    })[verdict]
    readonly property string headline: {
        if (verdict === "fault") return "OmaGuard could not run"
        if (verdict === "broken") return broken.length + " protected preference" + (broken.length === 1 ? "" : "s") + " broken"
        if (verdict === "drift") return (changedFiles || drifted.length) + " change" + ((changedFiles || drifted.length) === 1 ? "" : "s") + " since your reference"
        if (verdict === "unknown") return latest ? "No reference accepted yet" : "No capture yet"
        return "Everything you protect still holds"
    }

    readonly property color ink: Color.popups.text
    readonly property color muted: Qt.alpha(ink, 0.62)
    // The Omarchy palette has accent and urgent, and no third "warning" role.
    // Drift is genuinely between the two, so it is mixed from them and follows
    // whatever theme is loaded instead of a hardcoded amber.
    readonly property color warn: Qt.tint(Color.accent, Qt.alpha(Color.urgent, 0.55))

    function shortTime(iso) {
        var d = new Date(iso)
        return isNaN(d.getTime()) ? iso : Qt.formatDateTime(d, "ddd d MMM · HH:mm:ss")
    }
    function dayOf(iso) {
        var d = new Date(iso)
        return isNaN(d.getTime()) ? "" : Qt.formatDate(d, "dddd d MMMM yyyy")
    }
    function kb(bytes) {
        if (!bytes) return "0 KB"
        return bytes < 1048576 ? Math.round(bytes / 1024) + " KB"
                               : (bytes / 1048576).toFixed(1) + " MB"
    }
    function statusColor(s) {
        return s === "broken" ? Color.urgent
             : s === "drift" ? warn
             : s === "ok" ? Color.accent
             : Qt.alpha(ink, 0.55)
    }

    // ── The engine ────────────────────────────────────────────────────────
    property string helper: decodeURIComponent(String(Qt.resolvedUrl("omaguard.py")).replace(/^file:\/\/(localhost)?/, ""))
    property string pendingKind: ""
    property string outText: ""
    property string errText: ""
    property int exitCode: 0
    property bool outDone: false
    property bool exited: false
    property bool timedOut: false

    function call(kind, args) {
        if (busy) return
        busy = true
        pendingKind = kind
        outText = ""; errText = ""; exitCode = 0
        outDone = false; exited = false; timedOut = false
        worker.command = ["python3", helper].concat(args)
        worker.running = true
        watchdog.restart()
    }
    function refresh() { call("status", ["status"]) }
    function rescan() { call("status", ["scan"]) }
    function acceptReference(id) { call("status", ["baseline", "--id=" + id]) }
    function forget(id) { call("status", ["forget", "--id=" + id]) }

    // ── Profiles ──────────────────────────────────────────────────────────
    property var profileState: ({profiles: []})
    property var lastSwitch: null
    readonly property var profiles: profileState.profiles || []
    readonly property var favorites: profiles.filter(function (p) { return p.favorite })
    readonly property var activeProfile: profiles.find(function (p) { return p.active }) || null
    function loadProfiles() { call("profiles", ["profiles"]) }
    function saveProfile(name, id) {
        var args = ["profile-save", "--name=" + name]
        if (id) args.push("--id=" + id)
        call("profiles", args)
    }
    function favoriteProfile(id, on) { call("profiles", ["profile-favorite", "--id=" + id, "--value=" + (on ? "true" : "false")]) }
    function forgetProfile(id) { call("profiles", ["profile-forget", "--id=" + id]) }
    // One click from the bar. The helper refuses anything it cannot do
    // honestly — a missing plugin, a different bar — and says which.
    function switchProfile(id) { lastSwitch = null; call("switch", ["profile-apply", "--id=" + id]) }
    function openCapture(id) {
        selectedId = id
        previewResult = null
        call("detail", ["snapshot", "--id=" + id])
    }
    function previewField(id, file, path) {
        previewResult = null
        var args = ["preview", "--id=" + id, "--file=" + file]
        if (path && path.length) args.push("--path=" + JSON.stringify(path))
        call("preview", args)
    }

    function settle() {
        // The exit signal and the stdout drain race; neither alone is the end.
        if (!exited || !outDone) return
        watchdog.stop()
        var kind = pendingKind
        try {
            if (timedOut) throw new Error("omaguard.py timed out. Nothing was changed.")
            if (!outText.trim()) {
                // A missing python3 is exit 127 with no stdout — the silent
                // outage that makes a widget look calm while it is dead.
                throw new Error(exitCode === 127
                    ? "python3 was not found on PATH, so OmaGuard cannot read anything."
                    : (errText.trim() || "omaguard.py produced no output (exit " + exitCode + ")"))
            }
            var result = JSON.parse(outText)
            if (result.error) throw new Error(result.error)
            lastError = ""
            if (kind === "preview") previewResult = result
            else if (kind === "detail") detail = result
            else if (kind === "profiles") profileState = result
            else if (kind === "switch") { lastSwitch = result; profilesLater.restart() }
            else { state = result; if (selectedId) openCaptureLater.restart() }
        } catch (e) {
            lastError = String(e.message || e).slice(0, 400)
        }
        pendingKind = ""
        busy = false
        // A failed switch still changes what "active" means, so re-read
        // profiles after any switch attempt, not only a successful one.
        if (kind === "switch" && !lastSwitch) profilesLater.restart()
        if (kind === "status" && !profilesLoaded) { profilesLoaded = true; profilesLater.restart() }
    }
    property bool profilesLoaded: false
    // Profiles can change from outside the panel (the CLI, another session),
    // so opening the panel is always a fresh read, never a stale list.
    onOpenedChanged: if (opened) profilesLater.restart()

    Timer { id: profilesLater; interval: 1; onTriggered: if (!root.busy) root.loadProfiles(); else restart() }
    Timer { id: openCaptureLater; interval: 1; onTriggered: root.call("detail", ["snapshot", "--id=" + root.selectedId]) }
    // Both clamped here, so a hand-edited shell.json cannot turn the shield
    // into a spin loop or a widget that never reports a stuck helper.
    readonly property int pollMs: Math.max(15, Math.min(3600, parseInt(setting("pollSeconds", 60), 10) || 60)) * 1000
    readonly property int helperTimeoutMs: Math.max(2000, Math.min(120000, parseInt(setting("helperTimeoutMs", 20000), 10) || 20000))
    Timer { id: poll; interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!root.busy) root.refresh() }
    Timer {
        id: watchdog
        interval: root.helperTimeoutMs
        onTriggered: {
            root.timedOut = true
            if (worker.running) worker.signal(9)
            else { root.outDone = true; root.exited = true; root.settle() }
        }
    }
    Process {
        id: worker
        stdout: StdioCollector { onStreamFinished: { root.outText = text; root.outDone = true; root.settle() } }
        stderr: StdioCollector { onStreamFinished: root.errText = text }
        onExited: function (code) { root.exitCode = code; root.exited = true; root.settle() }
    }

    IpcHandler {
        target: "nixfred.omaguard"
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.toggle() }
        function scan(): void { root.rescan() }
        function switchTo(name: string): string {
            var p = root.profiles.find(function (x) { return x.name.toLowerCase() === name.toLowerCase() })
            if (!p) return "no profile named " + name
            root.switchProfile(p.id)
            return "switching to " + p.name
        }
        function status(): string {
            return JSON.stringify({
                opened: root.opened, version: root.version, verdict: root.verdict,
                headline: root.headline, busy: root.busy, error: root.lastError,
                reference: root.state.baseline || null, captures: root.timeline.length,
                storage: root.state.storage || null,
                checks: root.checks.map(function (c) { return {name: c.name, status: c.status} }),
                activeProfile: root.activeProfile ? root.activeProfile.name : null,
                favorites: root.favorites.map(function (p) { return p.name }),
                profiles: root.profiles.map(function (p) { return {name: p.name, favorite: p.favorite, active: p.active, missing: p.missing} }),
                lastSwitch: root.lastSwitch
            })
        }
    }

    WidgetButton {
        id: barButton
        bar: root.bar
        anchors.fill: parent
        text: root.glyph + (root.verdict === "drift" || root.verdict === "broken"
                            ? " " + Math.max(root.changedFiles, root.broken.length + root.drifted.length) : "")
        foreground: root.tint
        tooltipText: "OmaGuard · " + root.headline + "\n"
                     + (root.latest ? "Last capture " + root.shortTime(root.latest.time) : "Never captured")
                     + (root.activeProfile ? "\nProfile: " + root.activeProfile.name : "")
                     + "\nClick for profiles and the timeline"
        onPressed: root.toggle()
    }

    // KeyboardPanel, not PopupCard. A PopupCard is an xdg-popup, and those only
    // receive keys when focus is routed through their parent surface — so the
    // profile name field rendered, took the click, and swallowed every
    // keystroke. KeyboardPanel is a layer-shell surface that primes keyboard
    // focus on open.
    KeyboardPanel {
        id: popup
        bar: root.bar
        anchorItem: root
        owner: root
        open: root.opened
        focusTarget: root.view === "profiles" ? newProfileName : null
        contentWidth: fittedContentWidth(720)
        contentHeight: cappedContentHeight(680)

        Item {
            anchors.fill: parent

            // ── Header: the verdict, in words, with the two real actions ──
            Column {
                id: header
                width: parent.width
                spacing: 7
                Row {
                    width: parent.width
                    spacing: 10
                    Text {
                        text: root.glyph
                        color: root.tint
                        font.family: Style.font.family
                        font.pixelSize: 26
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Column {
                        width: parent.width - 36 - scanButton.width - 20
                        spacing: 2
                        Text {
                            text: "OMAGUARD"
                            color: root.ink
                            font.family: Style.font.family
                            font.pixelSize: 19
                            font.bold: true
                            font.letterSpacing: 1.4
                        }
                        Text {
                            width: parent.width
                            text: root.headline
                            color: root.tint
                            font.pixelSize: 13
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                        }
                    }
                    Button {
                        id: scanButton
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.busy ? "Working…" : "Capture now"
                        enabled: !root.busy
                        onClicked: root.rescan()
                    }
                }
                Text {
                    width: parent.width
                    text: root.latest
                        ? "Last capture " + root.shortTime(root.latest.time)
                          + "  ·  " + root.timeline.length + " kept"
                          + "  ·  " + root.kb(root.state.storage ? root.state.storage.bytes : 0) + " on disk"
                          + (root.hasReference ? "" : "  ·  no reference accepted")
                        : "OmaGuard has not captured this machine yet."
                    color: root.muted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Text {
                    width: parent.width
                    visible: root.lastError.length > 0
                    text: root.lastError
                    color: Color.urgent
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                // ── Quick switch: favourite profiles, one click each ──────
                Flow {
                    width: parent.width
                    spacing: 6
                    visible: root.favorites.length > 0
                    Text {
                        text: "SWITCH TO"
                        color: root.muted
                        font.pixelSize: 10
                        font.bold: true
                        font.letterSpacing: 1.2
                        height: 28
                        verticalAlignment: Text.AlignVCenter
                        rightPadding: 4
                    }
                    Repeater {
                        model: root.favorites
                        delegate: Button {
                            required property var modelData
                            text: (modelData.active ? "● " : "") + modelData.name
                                  + (modelData.missing.length ? "  ⚠" : "")
                            selected: modelData.active
                            enabled: !root.busy && !modelData.active
                            onClicked: root.switchProfile(modelData.id)
                        }
                    }
                }
                Text {
                    width: parent.width
                    visible: root.lastSwitch !== null
                    text: root.lastSwitch
                        ? root.lastSwitch.profile.name + " — " + root.lastSwitch.note
                          + root.lastSwitch.steps.filter(function (st) { return st.ok === false || st.result === "not attempted" })
                                .map(function (st) { return "\n  " + st.action + " " + st.id + ": " + st.result }).join("")
                        : ""
                    color: root.lastSwitch && !root.lastSwitch.applied ? Color.urgent : root.muted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Row {
                    spacing: 6
                    Button { text: "Profiles"; selected: root.view === "profiles"; onClicked: { root.view = "profiles"; Qt.callLater(function () { newProfileName.forceActiveFocus() }) } }
                    Button { text: "Preferences"; selected: root.view === "checks"; onClicked: root.view = "checks" }
                    Button { text: "Timeline"; selected: root.view === "timeline"; onClicked: root.view = "timeline" }
                    Button {
                        visible: root.latest !== null && !root.busy
                        text: root.hasReference ? "Move reference to newest" : "Accept this as my reference"
                        onClicked: root.acceptReference(root.latest.id)
                    }
                }
            }

            // ── Profiles: save the bar as it is, star favourites, switch ──
            Flickable {
                visible: root.view === "profiles"
                anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: footer.top; topMargin: 12; bottomMargin: 8 }
                contentWidth: width
                contentHeight: profileColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                Column {
                    id: profileColumn
                    width: parent.width - 14
                    spacing: 8
                    Row {
                        width: parent.width
                        spacing: 8
                        TextField {
                            id: newProfileName
                            width: parent.width - saveProfileButton.width - parent.spacing
                            // The layer surface owns the keyboard; Qt still needs an
                            // active-focus item inside it before keys reach the field.
                            TapHandler { onTapped: newProfileName.forceActiveFocus() }
                            placeholderText: "Name this bar layout — Work, Focus, Present…"
                            onAccepted: if (text.trim().length && !root.busy) { root.saveProfile(text.trim(), ""); text = "" }
                        }
                        Button {
                            id: saveProfileButton
                            text: "Save current bar"
                            enabled: newProfileName.text.trim().length > 0 && !root.busy
                            onClicked: { root.saveProfile(newProfileName.text.trim(), ""); newProfileName.text = "" }
                        }
                    }
                    Text {
                        width: parent.width
                        text: "A profile remembers which widgets are on the bar, in which section, in what order. "
                              + "Star one to put it in the quick switch. Switching moves widgets through the shell's own "
                              + "controls and never installs a plugin."
                        color: root.muted
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Repeater {
                        model: root.profiles
                        delegate: Rectangle {
                            required property var modelData
                            width: profileColumn.width
                            height: profileBody.implicitHeight + 18
                            radius: Math.max(4, Style.cornerRadius)
                            color: Qt.alpha(root.ink, modelData.active ? 0.09 : 0.035)
                            border.width: 1
                            border.color: modelData.active ? Qt.alpha(Color.accent, 0.7) : Qt.alpha(root.ink, 0.10)
                            Column {
                                id: profileBody
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                spacing: 6
                                Row {
                                    width: parent.width
                                    spacing: 8
                                    Text {
                                        text: modelData.favorite ? "★" : "☆"
                                        color: modelData.favorite ? Color.accent : root.muted
                                        font.pixelSize: 18
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            cursorShape: Qt.PointingHandCursor
                                            enabled: !root.busy
                                            onClicked: root.favoriteProfile(modelData.id, !modelData.favorite)
                                        }
                                    }
                                    Column {
                                        width: parent.width - 30
                                        spacing: 2
                                        Text {
                                            text: modelData.name + (modelData.active ? "   · on the bar now" : "")
                                            color: modelData.active ? Color.accent : root.ink
                                            font.pixelSize: 14
                                            font.bold: true
                                            textFormat: Text.PlainText
                                        }
                                        Text {
                                            width: parent.width
                                            text: modelData.widgets + " widgets · saved " + root.shortTime(modelData.updated)
                                                  + (modelData.missing.length ? "\nNot installed here: " + modelData.missing.join(", ") : "")
                                            color: modelData.missing.length ? Color.urgent : root.muted
                                            font.pixelSize: 11
                                            wrapMode: Text.Wrap
                                            textFormat: Text.PlainText
                                        }
                                    }
                                }
                                Row {
                                    spacing: 6
                                    Button { text: "Switch"; enabled: !root.busy && !modelData.active; onClicked: root.switchProfile(modelData.id) }
                                    Button { text: "Replace with current bar"; enabled: !root.busy && !modelData.active; onClicked: root.saveProfile(modelData.name, modelData.id) }
                                    Button { text: "Forget"; enabled: !root.busy; onClicked: root.forgetProfile(modelData.id) }
                                }
                            }
                        }
                    }
                    Text {
                        width: profileColumn.width
                        visible: root.profiles.length === 0
                        text: "No profiles yet. Arrange the bar the way you want it, name it above, and save."
                        color: root.muted
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                }
            }

            // ── Preferences: every check, with its own certainty ──────────
            Flickable {
                visible: root.view === "checks"
                anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: footer.top; topMargin: 12; bottomMargin: 8 }
                contentWidth: width
                contentHeight: checkColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                Column {
                    id: checkColumn
                    width: parent.width - 14
                    spacing: 8
                    Repeater {
                        model: root.checks
                        delegate: Rectangle {
                            required property var modelData
                            width: checkColumn.width
                            height: body.implicitHeight + 20
                            radius: Math.max(4, Style.cornerRadius)
                            color: Qt.alpha(root.ink, 0.04)
                            border.width: 1
                            border.color: Qt.alpha(root.statusColor(modelData.status), 0.35)
                            Column {
                                id: body
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                spacing: 4
                                Row {
                                    spacing: 8
                                    Text {
                                        text: modelData.status.toUpperCase()
                                        color: root.statusColor(modelData.status)
                                        font.pixelSize: 10
                                        font.bold: true
                                        font.letterSpacing: 1
                                    }
                                    Text {
                                        text: modelData.name + (modelData.protected ? "  · protected" : "")
                                        color: root.ink
                                        font.pixelSize: 14
                                        font.bold: true
                                        textFormat: Text.PlainText
                                    }
                                }
                                Text {
                                    width: body.width
                                    text: modelData.detail
                                    color: root.muted
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                    Text {
                        width: checkColumn.width
                        visible: root.checks.length === 0
                        text: "Nothing captured yet. Press Capture now."
                        color: root.muted
                        font.pixelSize: 13
                    }
                }
            }

            // ── Timeline: captures, newest first, grouped by day ──────────
            Flickable {
                visible: root.view === "timeline"
                anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: footer.top; topMargin: 12; bottomMargin: 8 }
                contentWidth: width
                contentHeight: timeColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                Column {
                    id: timeColumn
                    width: parent.width - 14
                    spacing: 6
                    Repeater {
                        model: root.rows
                        delegate: Column {
                            required property var modelData
                            width: timeColumn.width
                            spacing: 6
                            Text {
                                visible: modelData.dayHeader.length > 0
                                text: modelData.dayHeader
                                color: root.muted
                                font.pixelSize: 10
                                font.bold: true
                                font.letterSpacing: 1.2
                                topPadding: 6
                            }
                            Rectangle {
                                width: parent.width
                                height: row.implicitHeight + 18
                                radius: Math.max(4, Style.cornerRadius)
                                color: Qt.alpha(root.ink, modelData.id === root.selectedId ? 0.11 : hover.containsMouse ? 0.07 : 0.035)
                                border.width: 1
                                border.color: modelData.id === root.state.baseline
                                              ? Qt.alpha(Color.accent, 0.65) : Qt.alpha(root.ink, 0.10)
                                MouseArea {
                                    id: hover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: !root.busy
                                    onClicked: root.openCapture(modelData.id)
                                }
                                Column {
                                    id: row
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                    spacing: 3
                                    Text {
                                        text: root.shortTime(modelData.time)
                                              + (modelData.id === root.state.baseline ? "   · your reference" : "")
                                        color: modelData.id === root.state.baseline ? Color.accent : root.ink
                                        font.pixelSize: 13
                                        font.bold: true
                                        textFormat: Text.PlainText
                                    }
                                    Text {
                                        width: row.width
                                        text: modelData.summary
                                        color: modelData.changes.length ? root.tint : root.muted
                                        font.pixelSize: 11
                                        wrapMode: Text.Wrap
                                        textFormat: Text.PlainText
                                    }
                                    Text {
                                        width: row.width
                                        visible: modelData.broken.length > 0
                                        text: "Broken here: " + modelData.broken.join(", ")
                                        color: Color.urgent
                                        font.pixelSize: 11
                                        wrapMode: Text.Wrap
                                        textFormat: Text.PlainText
                                    }
                                }
                            }
                            // ── The opened capture: what differs, and a preview
                            Column {
                                visible: modelData.id === root.selectedId
                                width: parent.width
                                spacing: 6
                                leftPadding: 14
                                Row {
                                    spacing: 6
                                    Button {
                                        text: "Make this my reference"
                                        enabled: !root.busy && modelData.id !== root.state.baseline
                                        onClicked: root.acceptReference(modelData.id)
                                    }
                                    Button {
                                        text: "Preview restoring the bar layout"
                                        enabled: !root.busy
                                        onClicked: root.previewField(modelData.id, "shell", ["bar", "id"])
                                    }
                                    Button {
                                        text: "Forget"
                                        enabled: !root.busy && modelData.id !== root.state.baseline
                                        onClicked: { root.selectedId = ""; root.forget(modelData.id) }
                                    }
                                }
                                Repeater {
                                    model: root.detail && root.detail.id === modelData.id
                                           ? (root.detail.comparison ? root.detail.comparison.changes : []) : []
                                    delegate: Column {
                                        required property var modelData
                                        width: timeColumn.width - 14
                                        spacing: 3
                                        Text {
                                            text: modelData.label + " differs from your reference"
                                            color: root.ink
                                            font.pixelSize: 12
                                            font.bold: true
                                            textFormat: Text.PlainText
                                        }
                                        Text {
                                            width: parent.width
                                            text: modelData.diff
                                            color: root.muted
                                            font.family: Style.font.family
                                            font.pixelSize: 10
                                            wrapMode: Text.WrapAnywhere
                                            maximumLineCount: 40
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                        }
                                    }
                                }
                                Text {
                                    width: parent.width - 14
                                    visible: root.previewResult !== null
                                    text: root.previewResult
                                        ? root.previewResult.label + "\n"
                                          + root.previewResult.fileLabel + "  ·  current hash "
                                          + String(root.previewResult.currentHash).slice(0, 12) + "…\n\n"
                                          + root.previewResult.diff + "\n\n" + root.previewResult.note
                                        : ""
                                    color: root.ink
                                    font.family: Style.font.family
                                    font.pixelSize: 10
                                    wrapMode: Text.WrapAnywhere
                                    maximumLineCount: 40
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                    Text {
                        width: timeColumn.width
                        visible: root.rows.length === 0
                        text: "No captures kept yet."
                        color: root.muted
                        font.pixelSize: 13
                    }
                }
            }

            Text {
                id: footer
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                text: "OmaGuard " + root.version + " · reads six config files, writes only its own state · "
                      + "every restore is a preview, never applied"
                color: root.muted
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }
        }
    }

    property string view: "profiles"

    // Newest first, with a day header on the first capture of each day.
    readonly property var rows: {
        var out = [], seen = ""
        for (var i = timeline.length - 1; i >= 0; i--) {
            var r = timeline[i], day = dayOf(r.time)
            out.push({
                id: r.id, time: r.time, summary: r.summary,
                changes: r.changes || [], broken: r.broken || [],
                dayHeader: day === seen ? "" : day
            })
            seen = day
        }
        return out
    }
}
