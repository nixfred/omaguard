import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaGuard — a shield in the bar that remembers your good setup.
//
//   󰕥 all good     nothing changed since you marked this setup good
//   󰻌 changed      something changed since then (the number says how many)
//   󰦝 broken       something you rely on is gone, or Hyprland is erroring
//   󰞀 not set up   OmaGuard has not been told what "good" looks like yet
//
// Every state comes with a sentence that says what happened and a button
// that does the obvious next thing. A warning you cannot clear is a warning
// you learn to ignore.
//
// The widget owns its data: it runs omaguard.py itself. Under a third-party
// bar `bar.shell.serviceFor()` returns null for every id, silently.
Panel {
    id: root
    moduleName: "nixfred.omaguard"
    manageIpc: false
    implicitWidth: barButton.implicitWidth
    implicitHeight: barButton.implicitHeight

    readonly property string version: "1.3.0"
    property var state: ({})
    property var profileState: ({profiles: []})
    property string lastError: ""
    property bool busy: false
    property string view: "layouts"
    property string selectedId: ""
    property var detail: null
    property bool showLines: false
    property var lastSwitch: null
    property string notice: ""

    readonly property var timeline: state.timeline || []
    readonly property var latest: state.latest || null
    readonly property var comparison: state.comparison || null
    readonly property var checks: latest ? (latest.checks || []) : []
    readonly property bool hasReference: !!state.baseline
    readonly property var changes: comparison ? (comparison.changes || []) : []
    readonly property var goodRow: timeline.find(function (r) { return r.id === root.state.baseline }) || null
    readonly property var profiles: profileState.profiles || []
    readonly property var favorites: profiles.filter(function (p) { return p.favorite })
    readonly property var activeProfile: profiles.find(function (p) { return p.active }) || null

    // ── What the shield says ──────────────────────────────────────────────
    readonly property var broken: checks.filter(function (c) { return c.status === "broken" })
    readonly property var drifted: checks.filter(function (c) { return c.status === "drift" })
    readonly property string verdict: {
        if (lastError && !latest) return "fault"
        if (!latest) return "unknown"
        if (broken.length) return "broken"
        if (!hasReference) return "unknown"
        if (drifted.length || changes.length) return "drift"
        return "holding"
    }
    readonly property int attention: verdict === "broken" ? broken.length
                                   : verdict === "drift" ? changes.length + drifted.length : 0
    readonly property string glyph: ({
        holding: "󰕥", drift: "󰻌", broken: "󰦝", unknown: "󰞀", fault: "󰦝"
    })[verdict]
    readonly property color ink: Color.popups.text
    readonly property color muted: Qt.alpha(ink, 0.62)
    // The palette has accent and urgent and no warning role; drift sits between.
    readonly property color warn: Qt.tint(Color.accent, Qt.alpha(Color.urgent, 0.55))
    readonly property color tint: ({
        holding: Color.accent, drift: warn, broken: Color.urgent,
        unknown: Qt.alpha(Color.popups.text, 0.55), fault: Color.urgent
    })[verdict]

    readonly property string headline: {
        if (verdict === "fault") return "OmaGuard could not run"
        if (verdict === "broken") return broken.length === 1 ? broken[0].name + " is broken" : broken.length + " things are broken"
        if (verdict === "drift") return "Your setup changed since you marked it good"
        if (verdict === "unknown") return latest ? "OmaGuard doesn't know your good setup yet" : "OmaGuard hasn't looked at this machine yet"
        return "All good — nothing changed"
    }
    readonly property string explanation: {
        if (verdict === "fault") return lastError
        if (verdict === "broken")
            return broken.map(function (c) { return c.name + ": " + String(c.detail).split("\n")[0] }).join("\n")
        if (verdict === "drift")
            return "Here is what changed since " + (goodRow ? shortTime(goodRow.time) : "you marked your setup good")
                   + ". If you did this on purpose, keep the changes and the warning goes away."
        if (verdict === "unknown")
            return latest ? "When your desktop is set up the way you like it, tell OmaGuard. From then on the shield warns you if anything changes."
                          : "Take a snapshot to get started."
        return "Everything matches the setup you marked good" + (goodRow ? " on " + shortTime(goodRow.time) : "") + "."
    }
    readonly property var changeLines: {
        var out = []
        for (var i = 0; i < changes.length; i++) {
            var c = changes[i], parts = c.summary && c.summary.length ? c.summary : ["changed"]
            for (var j = 0; j < parts.length; j++) out.push(c.label + ": " + parts[j])
        }
        for (var k = 0; k < drifted.length; k++) out.push(drifted[k].name + ": " + String(drifted[k].detail).split("\n")[0])
        return out
    }

    function shortTime(iso) {
        var d = new Date(iso)
        return isNaN(d.getTime()) ? "" : Qt.formatDateTime(d, "ddd d MMM, h:mm ap")
    }
    function dayOf(iso) {
        var d = new Date(iso)
        return isNaN(d.getTime()) ? "" : Qt.formatDate(d, "dddd d MMMM yyyy")
    }
    function statusWord(s) {
        return ({ok: "OK", drift: "CHANGED", broken: "BROKEN", unknown: "CAN'T TELL", "n/a": "NOT USED"})[s] || String(s).toUpperCase()
    }
    function statusColor(s) {
        return s === "broken" ? Color.urgent : s === "drift" ? warn : s === "ok" ? Color.accent : Qt.alpha(ink, 0.55)
    }
    function layoutStatus(p) {
        if (p.active) return "✓ This is your bar right now"
        if (p.blocked) return "Can't switch: " + p.reason
        if (!p.changes) return "Matches your bar"
        return "Switching will " + p.changes
    }

    // ── The engine: one helper call at a time, clicks queued, never dropped
    property string helper: decodeURIComponent(String(Qt.resolvedUrl("omaguard.py")).replace(/^file:\/\/(localhost)?/, ""))
    property var queue: []
    property string runningKind: ""
    property string runningLabel: ""
    property string outText: ""
    property string errText: ""
    property int exitCode: 0
    property bool outDone: false
    property bool exited: false
    property bool timedOut: false

    function call(kind, args, label) {
        // A click while a background read is running used to be dropped
        // silently, which read as "switching does nothing". Queue it instead.
        if (busy) { queue = queue.concat([{kind: kind, args: args, label: label || ""}]); return }
        start(kind, args, label || "")
    }
    function start(kind, args, label) {
        busy = true
        runningKind = kind
        runningLabel = label
        outText = ""; errText = ""; exitCode = 0
        outDone = false; exited = false; timedOut = false
        worker.command = ["python3", helper].concat(args)
        worker.running = true
        watchdog.restart()
    }
    function refresh() { call("status", ["status"]) }
    function takeSnapshot() { notice = ""; call("status", ["scan"]) }
    function keepChanges() { notice = ""; call("accept", ["accept-current"]) }
    function markGood(id) { notice = ""; call("accept", ["baseline", "--id=" + id]) }
    function deleteSnapshot(id) { selectedId = ""; call("status", ["forget", "--id=" + id]) }
    function openSnapshot(id) { selectedId = id; showLines = false; call("detail", ["snapshot", "--id=" + id]) }
    function loadProfiles() { call("profiles", ["profiles"]) }
    function saveProfile(name, id) {
        var args = ["profile-save", "--name=" + name]
        if (id) args.push("--id=" + id)
        call("profiles", args)
    }
    function favoriteProfile(id, on) { call("profiles", ["profile-favorite", "--id=" + id, "--value=" + (on ? "true" : "false")]) }
    function deleteProfile(id) { call("profiles", ["profile-forget", "--id=" + id]) }
    function switchProfile(p) {
        lastSwitch = {pending: true, applied: false, profile: {name: p.name}, note: "Switching to " + p.name + "…", steps: []}
        call("switch", ["profile-apply", "--id=" + p.id], p.name)
    }

    function settle() {
        if (!exited || !outDone) return
        watchdog.stop()
        var kind = runningKind, label = runningLabel
        try {
            if (timedOut) throw new Error("omaguard.py timed out. Nothing was changed.")
            if (!outText.trim())
                throw new Error(exitCode === 127 ? "python3 was not found on PATH, so OmaGuard cannot read anything."
                                                 : (errText.trim() || "omaguard.py produced no output (exit " + exitCode + ")"))
            var result = JSON.parse(outText)
            if (result.error) throw new Error(result.error)
            if (kind !== "switch") lastError = ""
            if (kind === "detail") detail = result
            else if (kind === "profiles") profileState = result
            else if (kind === "switch") lastSwitch = result
            else {
                state = result
                if (kind === "accept") notice = "Saved. This is now your good setup, and the shield will warn you if it changes."
            }
        } catch (e) {
            var problem = String(e.message || e).slice(0, 400)
            if (kind === "switch") lastSwitch = {applied: false, profile: {name: label}, note: problem, steps: []}
            else lastError = problem
        }
        busy = false
        runningKind = ""
        if (kind === "switch") {
            // A switch changes shell.json, so both the layouts and the
            // change list are stale the moment it returns.
            call("profiles", ["profiles"])
            call("status", ["status"])
        }
        if (kind === "status" && !profilesLoaded) { profilesLoaded = true; call("profiles", ["profiles"]) }
        if (queue.length) {
            var next = queue[0]
            queue = queue.slice(1)
            start(next.kind, next.args, next.label)
        }
    }
    property bool profilesLoaded: false
    onOpenedChanged: if (opened) { refresh(); loadProfiles() }

    readonly property int pollMs: Math.max(15, Math.min(3600, parseInt(setting("pollSeconds", 60), 10) || 60)) * 1000
    readonly property int helperTimeoutMs: Math.max(2000, Math.min(120000, parseInt(setting("helperTimeoutMs", 20000), 10) || 20000))
    Timer { interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true
            onTriggered: if (!root.busy && root.queue.length === 0) root.refresh() }
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
        function scan(): void { root.takeSnapshot() }
        function keepChanges(): void { root.keepChanges() }
        function switchTo(name: string): string {
            var p = root.profiles.find(function (x) { return x.name.toLowerCase() === name.toLowerCase() })
            if (!p) return "no layout named " + name
            root.switchProfile(p)
            return "switching to " + p.name
        }
        function status(): string {
            return JSON.stringify({
                opened: root.opened, version: root.version, verdict: root.verdict,
                headline: root.headline, explanation: root.explanation, changes: root.changeLines,
                busy: root.busy, queued: root.queue.length, error: root.lastError,
                reference: root.state.baseline || null, captures: root.timeline.length,
                checks: root.checks.map(function (c) { return {name: c.name, status: c.status} }),
                activeProfile: root.activeProfile ? root.activeProfile.name : null,
                favorites: root.favorites.map(function (p) { return p.name }),
                profiles: root.profiles.map(function (p) {
                    return {name: p.name, favorite: p.favorite, active: p.active, canSwitch: p.canSwitch,
                            status: root.layoutStatus(p), incomplete: p.incomplete, sameAs: p.sameAs}
                }),
                lastSwitch: root.lastSwitch
            })
        }
    }

    WidgetButton {
        id: barButton
        bar: root.bar
        anchors.fill: parent
        text: root.glyph + (root.attention ? " " + root.attention : "")
        foreground: root.tint
        tooltipText: "OmaGuard · " + root.headline
                     + (root.attention ? "\nClick to see what changed and clear the warning" : "")
                     + (root.activeProfile ? "\nBar layout: " + root.activeProfile.name : "")
        onPressed: root.toggle()
    }

    // KeyboardPanel, not PopupCard: a PopupCard is an xdg-popup and its text
    // fields never receive keys.
    KeyboardPanel {
        id: popup
        bar: root.bar
        anchorItem: root
        owner: root
        open: root.opened
        focusTarget: root.view === "layouts" ? layoutName : null
        contentWidth: fittedContentWidth(720)
        contentHeight: cappedContentHeight(760)

        Item {
            anchors.fill: parent

            Column {
                id: header
                width: parent.width
                spacing: 9

                // ── Title row ─────────────────────────────────────────────
                Row {
                    width: parent.width
                    spacing: 10
                    Text { text: root.glyph; color: root.tint; font.family: Style.font.family; font.pixelSize: 28; anchors.verticalCenter: parent.verticalCenter }
                    Column {
                        width: parent.width - 40 - snapButton.width - 20
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: "OMAGUARD"; color: root.ink; font.family: Style.font.family; font.pixelSize: 17; font.bold: true; font.letterSpacing: 1.4 }
                        Text { width: parent.width; text: root.headline; color: root.tint; font.pixelSize: 15; font.bold: true; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                    }
                    Button { id: snapButton; anchors.verticalCenter: parent.verticalCenter; text: root.busy ? "Working…" : "Take snapshot"; enabled: !root.busy; onClicked: root.takeSnapshot() }
                }

                // ── What happened, and the obvious next step ─────────────
                Rectangle {
                    width: parent.width
                    height: card.implicitHeight + 24
                    radius: Math.max(4, Style.cornerRadius)
                    color: Qt.alpha(root.tint, 0.08)
                    border.width: 1
                    border.color: Qt.alpha(root.tint, 0.45)
                    Column {
                        id: card
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 14 }
                        spacing: 6
                        Text { width: parent.width; text: root.explanation; color: root.ink; font.pixelSize: 13; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        Repeater {
                            model: root.verdict === "drift" ? root.changeLines : []
                            delegate: Text {
                                required property var modelData
                                width: card.width
                                text: "•  " + modelData
                                color: root.ink
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                            }
                        }
                        Flow {
                            width: parent.width
                            spacing: 6
                            visible: root.verdict === "drift" || root.verdict === "unknown" || root.verdict === "broken"
                            Button { visible: root.verdict === "drift"; text: "Keep these changes"; enabled: !root.busy; onClicked: root.keepChanges() }
                            Button { visible: root.verdict === "drift"; text: "Show me the details"
                                     onClicked: { root.view = "history"; if (root.latest) root.openSnapshot(root.latest.id) } }
                            Button { visible: root.verdict === "unknown" && root.latest !== null; text: "This setup is good — remember it"; enabled: !root.busy; onClicked: root.keepChanges() }
                            Button { visible: root.verdict === "unknown" && root.latest === null; text: "Take the first snapshot"; enabled: !root.busy; onClicked: root.takeSnapshot() }
                            Button { visible: root.verdict === "broken"; text: "Show the checks"; onClicked: root.view = "checks" }
                        }
                    }
                }
                Text { width: parent.width; visible: root.notice.length > 0; text: root.notice; color: Color.accent; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                Text { width: parent.width; visible: root.lastError.length > 0 && root.verdict !== "fault"; text: root.lastError; color: Color.urgent; font.pixelSize: 12; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; textFormat: Text.PlainText }

                // ── Quick switch: starred layouts ────────────────────────
                Column {
                    width: parent.width
                    spacing: 5
                    visible: root.profiles.length > 0
                    Text { text: "SWITCH BAR LAYOUT"; color: root.muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2 }
                    Flow {
                        width: parent.width
                        spacing: 6
                        Repeater {
                            model: root.favorites
                            delegate: Button {
                                required property var modelData
                                text: modelData.active ? "✓ " + modelData.name + " (now)" : modelData.name
                                selected: modelData.active
                                enabled: !modelData.active && modelData.canSwitch
                                onClicked: root.switchProfile(modelData)
                            }
                        }
                    }
                    Text {
                        width: parent.width
                        visible: text.length > 0
                        text: root.favorites.length === 0
                              ? "Star ☆ a layout in Bar layouts below to add a one-click button here."
                              : (root.favorites.every(function (p) { return p.active || !p.canSwitch })
                                 ? "The only starred layout is the one you're using. Star another layout to switch to it." : "")
                        color: root.muted
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Text {
                        width: parent.width
                        visible: root.lastSwitch !== null
                        text: root.lastSwitch
                              ? (root.lastSwitch.pending ? "" : (root.lastSwitch.applied && root.lastSwitch.exact !== false ? "✓ " : "✗ "))
                                + root.lastSwitch.note
                                + (root.lastSwitch.steps || []).filter(function (st) { return st.ok === false || st.result === "not attempted" })
                                    .map(function (st) { return "\n   " + st.action + " " + st.id + ": " + st.result }).join("")
                              : ""
                        color: root.lastSwitch && !root.lastSwitch.pending && !(root.lastSwitch.applied && root.lastSwitch.exact !== false) ? Color.urgent : Color.accent
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                    }
                }

                Row {
                    spacing: 6
                    Button { text: "Bar layouts"; selected: root.view === "layouts"; onClicked: { root.view = "layouts"; Qt.callLater(function () { layoutName.forceActiveFocus() }) } }
                    Button { text: "Checks"; selected: root.view === "checks"; onClicked: root.view = "checks" }
                    Button { text: "History"; selected: root.view === "history"; onClicked: root.view = "history" }
                }
            }

            // ── Bar layouts ──────────────────────────────────────────────
            Flickable {
                visible: root.view === "layouts"
                anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: footer.top; topMargin: 12; bottomMargin: 8 }
                contentWidth: width
                contentHeight: layoutColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                Column {
                    id: layoutColumn
                    width: parent.width - 14
                    spacing: 8
                    Row {
                        width: parent.width
                        spacing: 8
                        TextField {
                            id: layoutName
                            width: parent.width - saveButton.width - parent.spacing
                            placeholderText: "Name your current bar, e.g. Work or Focus"
                            TapHandler { onTapped: layoutName.forceActiveFocus() }
                            onAccepted: if (text.trim().length) { root.saveProfile(text.trim(), ""); text = "" }
                        }
                        Button {
                            id: saveButton
                            text: "Save my current bar"
                            enabled: layoutName.text.trim().length > 0
                            onClicked: { root.saveProfile(layoutName.text.trim(), ""); layoutName.text = "" }
                        }
                    }
                    Text {
                        width: parent.width
                        text: "A bar layout remembers which widgets are on the bar, their order, and which are pinned. "
                              + "Switching moves widgets using the shell's own controls and never installs anything."
                        color: root.muted
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Text {
                        width: parent.width
                        visible: root.profileState.liveError !== undefined && root.profileState.liveError.length > 0
                        text: root.profileState.liveError || ""
                        color: Color.urgent
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                    Repeater {
                        model: root.profiles
                        delegate: Rectangle {
                            required property var modelData
                            width: layoutColumn.width
                            height: rowBody.implicitHeight + 20
                            radius: Math.max(4, Style.cornerRadius)
                            color: Qt.alpha(root.ink, modelData.active ? 0.09 : 0.035)
                            border.width: 1
                            border.color: modelData.active ? Qt.alpha(Color.accent, 0.7) : Qt.alpha(root.ink, 0.10)
                            Column {
                                id: rowBody
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                spacing: 5
                                Row {
                                    width: parent.width
                                    spacing: 10
                                    Text {
                                        text: modelData.favorite ? "★" : "☆"
                                        color: modelData.favorite ? Color.accent : root.muted
                                        font.pixelSize: 20
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.favoriteProfile(modelData.id, !modelData.favorite)
                                        }
                                    }
                                    Column {
                                        width: parent.width - 32
                                        spacing: 3
                                        Text { text: modelData.name; color: root.ink; font.pixelSize: 15; font.bold: true; textFormat: Text.PlainText }
                                        Text {
                                            width: parent.width
                                            text: root.layoutStatus(modelData)
                                            color: modelData.active ? Color.accent : modelData.blocked ? Color.urgent : root.ink
                                            font.pixelSize: 12
                                            wrapMode: Text.Wrap
                                            textFormat: Text.PlainText
                                        }
                                        Text {
                                            width: parent.width
                                            visible: modelData.sameAs.length > 0
                                            text: "Same layout as " + modelData.sameAs.join(", ") + " — you can delete the extras."
                                            color: root.muted
                                            font.pixelSize: 11
                                            wrapMode: Text.Wrap
                                            textFormat: Text.PlainText
                                        }
                                        Text {
                                            width: parent.width
                                            visible: modelData.incomplete
                                            text: "Saved before OmaGuard remembered pinned widgets, so switching can't restore pins. "
                                                  + "Set the bar up the way you want and press Update to fix it."
                                            color: root.warn
                                            font.pixelSize: 11
                                            wrapMode: Text.Wrap
                                        }
                                        Text {
                                            width: parent.width
                                            text: modelData.widgets + " widgets, " + modelData.pinned + " pinned · saved " + root.shortTime(modelData.updated)
                                            color: root.muted
                                            font.pixelSize: 10
                                        }
                                    }
                                }
                                Flow {
                                    width: parent.width
                                    spacing: 6
                                    Button { text: "Switch to this layout"; enabled: modelData.canSwitch; onClicked: root.switchProfile(modelData) }
                                    Button { text: "Update to my current bar"; enabled: !modelData.active || modelData.incomplete; onClicked: root.saveProfile(modelData.name, modelData.id) }
                                    Button { text: "Delete"; onClicked: root.deleteProfile(modelData.id) }
                                }
                            }
                        }
                    }
                    Text {
                        width: layoutColumn.width
                        visible: root.profiles.length === 0
                        text: "No layouts yet. Arrange the bar the way you like it, give it a name above, and save."
                        color: root.muted
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                }
            }

            // ── Checks ───────────────────────────────────────────────────
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
                    Text {
                        width: parent.width
                        text: "OmaGuard reads your config files and asks the running desktop what it is doing. CAN'T TELL means it could not check — never that something passed."
                        color: root.muted
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Repeater {
                        model: root.checks
                        delegate: Rectangle {
                            required property var modelData
                            width: checkColumn.width
                            height: checkBody.implicitHeight + 20
                            radius: Math.max(4, Style.cornerRadius)
                            color: Qt.alpha(root.ink, 0.04)
                            border.width: 1
                            border.color: Qt.alpha(root.statusColor(modelData.status), 0.35)
                            Column {
                                id: checkBody
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                spacing: 4
                                Row {
                                    spacing: 8
                                    Text { text: root.statusWord(modelData.status); color: root.statusColor(modelData.status); font.pixelSize: 10; font.bold: true; font.letterSpacing: 1 }
                                    Text { text: modelData.name; color: root.ink; font.pixelSize: 14; font.bold: true; textFormat: Text.PlainText }
                                }
                                Text { width: checkBody.width; text: modelData.detail; color: root.muted; font.pixelSize: 11; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                            }
                        }
                    }
                }
            }

            // ── History ──────────────────────────────────────────────────
            Flickable {
                visible: root.view === "history"
                anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: footer.top; topMargin: 12; bottomMargin: 8 }
                contentWidth: width
                contentHeight: historyColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                Column {
                    id: historyColumn
                    width: parent.width - 14
                    spacing: 6
                    Text {
                        width: parent.width
                        text: "Each snapshot is a copy of your desktop config at that moment. The one marked “your good setup” is what the shield compares against. Click a snapshot to see what was different."
                        color: root.muted
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Repeater {
                        model: root.rows
                        delegate: Column {
                            required property var modelData
                            width: historyColumn.width
                            spacing: 6
                            Text { visible: modelData.dayHeader.length > 0; text: modelData.dayHeader; color: root.muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2; topPadding: 6 }
                            Rectangle {
                                width: parent.width
                                height: snapRow.implicitHeight + 18
                                radius: Math.max(4, Style.cornerRadius)
                                color: Qt.alpha(root.ink, modelData.id === root.selectedId ? 0.11 : hover.containsMouse ? 0.07 : 0.035)
                                border.width: 1
                                border.color: modelData.id === root.state.baseline ? Qt.alpha(Color.accent, 0.7) : Qt.alpha(root.ink, 0.10)
                                MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openSnapshot(modelData.id) }
                                Column {
                                    id: snapRow
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                    spacing: 3
                                    Text {
                                        text: root.shortTime(modelData.time) + (modelData.id === root.state.baseline ? "   ✓ your good setup" : "")
                                        color: modelData.id === root.state.baseline ? Color.accent : root.ink
                                        font.pixelSize: 13
                                        font.bold: true
                                    }
                                    Text { width: snapRow.width; text: modelData.summary; color: root.muted; font.pixelSize: 11; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                                }
                            }
                            Column {
                                visible: modelData.id === root.selectedId
                                width: parent.width
                                spacing: 6
                                leftPadding: 14
                                Flow {
                                    width: parent.width - 14
                                    spacing: 6
                                    Button { text: "Mark this as my good setup"; visible: modelData.id !== root.state.baseline; onClicked: root.markGood(modelData.id) }
                                    Button { text: root.showLines ? "Hide exact lines" : "Show exact lines"; onClicked: root.showLines = !root.showLines }
                                    Button { text: "Delete snapshot"; visible: modelData.id !== root.state.baseline; onClicked: root.deleteSnapshot(modelData.id) }
                                }
                                Text {
                                    width: parent.width - 14
                                    visible: root.detail !== null && root.detail.id === modelData.id
                                    text: {
                                        if (!root.detail || root.detail.id !== modelData.id) return ""
                                        var c = root.detail.comparison || {}
                                        if (!c.baseline) return "No good setup marked yet, so there is nothing to compare this snapshot with."
                                        if (c.baseline === modelData.id) return "This is your good setup."
                                        if (!c.changes || !c.changes.length) return "Identical to your good setup."
                                        return "Compared with your good setup:\n" + c.changes.map(function (x) {
                                            return (x.summary || ["changed"]).map(function (line) { return "•  " + x.label + ": " + line }).join("\n")
                                        }).join("\n")
                                    }
                                    color: root.ink
                                    font.pixelSize: 12
                                    wrapMode: Text.Wrap
                                    textFormat: Text.PlainText
                                }
                                Repeater {
                                    model: root.showLines && root.detail && root.detail.id === modelData.id && root.detail.comparison
                                           ? (root.detail.comparison.changes || []) : []
                                    delegate: Text {
                                        required property var modelData
                                        width: historyColumn.width - 14
                                        text: modelData.label + "\n" + modelData.diff
                                        color: root.muted
                                        font.family: Style.font.family
                                        font.pixelSize: 10
                                        wrapMode: Text.WrapAnywhere
                                        maximumLineCount: 60
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                    }
                                }
                            }
                        }
                    }
                    Text { width: historyColumn.width; visible: root.rows.length === 0; text: "No snapshots yet."; color: root.muted; font.pixelSize: 13 }
                }
            }

            Text {
                id: footer
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                text: "OmaGuard " + root.version + " · reads six config files, keeps its own history · only switching a bar layout changes your bar"
                color: root.muted
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }
        }
    }

    // Newest first, with a day header on the first snapshot of each day.
    readonly property var rows: {
        var out = [], seen = ""
        for (var i = timeline.length - 1; i >= 0; i--) {
            var r = timeline[i], day = dayOf(r.time)
            out.push({id: r.id, time: r.time, summary: r.summary, dayHeader: day === seen ? "" : day})
            seen = day
        }
        return out
    }
}
