import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaGuard — your bar layouts, one click each, and a shield that only warns
// about problems the running desktop confirms.
//
//   󰕥 all good    the live desktop confirms nothing is wrong
//   󰦝 N           N confirmed problems, each with how to fix it
//   󰞀 starting    OmaGuard has not answered yet
//
// One idea for the bar: the loaded layout. Load one and it is loaded; change
// the bar afterwards and the panel says "<name> has unsaved changes" with
// Save, Undo and Save as new. Bar edits never add a number to the shield.
//
// The widget owns its data: it runs omaguard.py itself. Under a third-party
// bar `bar.shell.serviceFor()` returns null for every id, silently.
Panel {
    id: root
    moduleName: "nixfred.omaguard"
    manageIpc: false
    implicitWidth: barButton.implicitWidth
    implicitHeight: barButton.implicitHeight

    readonly property string version: "1.5.2"
    // New widgets on the bar join the loaded layout (additions only).
    readonly property bool autoAdd: setting("autoAddNewWidgets", true) !== false
    property var layoutState: ({layouts: [], problems: [], checks: [], unsavedChanges: []})
    property var historyState: ({timeline: []})
    property bool answered: false
    property string lastError: ""
    // What you just clicked, until the helper's own record of it arrives.
    property string localPending: ""
    property real pendingSince: 0
    property bool busy: false
    property string view: "main"
    property bool saveAsOpen: false
    property string renameId: ""
    // The shell builds each panel more than once and routes IPC to the first
    // one registered, so scripted checks must be able to tell copies apart.
    readonly property string instanceId: Math.random().toString(36).slice(2, 8)
    property int loadCalls: 0

    readonly property var layouts: layoutState.layouts || []
    readonly property var problems: layoutState.problems || []
    readonly property var checks: layoutState.checks || []
    readonly property bool unsaved: layoutState.unsaved === true
    readonly property string loadedName: layoutState.loadedName || ""

    readonly property string verdict: !answered ? (lastError ? "fault" : "starting")
                                     : problems.length ? "broken" : "holding"
    readonly property string glyph: ({holding: "󰕥", broken: "󰦝", fault: "󰦝", starting: "󰞀"})[verdict]
    readonly property color ink: Color.popups.text
    readonly property color muted: Qt.alpha(ink, 0.62)
    readonly property color tint: ({
        holding: Color.accent, broken: Color.urgent, fault: Color.urgent,
        starting: Qt.alpha(Color.popups.text, 0.55)
    })[verdict]
    readonly property string headline: {
        if (verdict === "fault") return "OmaGuard could not run"
        if (verdict === "starting") return "Checking…"
        if (problems.length === 1) return problems[0].name + " needs attention"
        if (problems.length > 1) return problems.length + " things need attention"
        return "All good"
    }

    function shortTime(iso) {
        var d = new Date(iso)
        return isNaN(d.getTime()) ? "" : Qt.formatDateTime(d, "ddd d MMM, h:mm ap")
    }
    function statusWord(s) {
        return ({ok: "OK", broken: "PROBLEM", unknown: "CAN'T TELL", "n/a": "NOT USED"})[s] || String(s).toUpperCase()
    }
    function statusColor(s) {
        return s === "broken" ? Color.urgent : s === "ok" ? Color.accent : Qt.alpha(ink, 0.55)
    }
    function rowNote(p) {
        if (p.loaded) return unsaved ? "loaded · unsaved changes" : "loaded"
        if (p.blocked) return "can't load: " + p.reason
        if (p.active) return "same as the bar right now"
        var note = p.changes ? "differs: " + p.changes : ""
        if (p.incomplete) note += (note ? " · " : "") + "saved before pins were recorded"
        return note
    }
    function resultOk(r) {
        return r && (r.ok === true || (r.applied === true && r.exact !== false))
    }

    // ── Engine: one helper call at a time, clicks queued, never dropped ─────
    property string helper: decodeURIComponent(String(Qt.resolvedUrl("omaguard.py")).replace(/^file:\/\/(localhost)?/, ""))
    property var queue: []
    property string runningKind: ""
    property string outText: ""
    property string errText: ""
    property int exitCode: 0
    property bool outDone: false
    property bool exited: false
    property bool timedOut: false

    function call(kind, args) {
        if (busy) { queue = queue.concat([{kind: kind, args: args}]); return }
        start(kind, args)
    }
    function start(kind, args) {
        busy = true
        runningKind = kind
        outText = ""; errText = ""; exitCode = 0
        outDone = false; exited = false; timedOut = false
        worker.command = ["python3", helper].concat(args)
        worker.running = true
        watchdog.restart()
    }
    function refresh() { call("layouts", autoAdd ? ["layouts", "--adopt"] : ["layouts"]) }
    // Detached, never through `worker`: the first widget a layout moves makes
    // the bar rebuild this whole section, destroying this instance and any
    // process it owns. The helper records its outcome in its state file, and
    // whichever instance exists next shows it.
    function act(args, pendingNote) {
        localPending = pendingNote
        pendingSince = Date.now()
        Quickshell.execDetached(["python3", helper].concat(args))
        fastTicks = 0
        fastPoll.restart()
    }
    function loadLayout(p) { act(["layout-load", "--id=" + p.id], "Loading " + p.name + "…") }
    function saveLayout() { act(["layout-save"], "Saving…") }
    function undoChanges() { act(["layout-undo"], "Putting the bar back…") }
    function saveAs(name) { saveAsOpen = false; act(["layout-save-as", "--name=" + name], "Saving…") }
    function renameLayout(id, name) { renameId = ""; act(["layout-rename", "--id=" + id, "--name=" + name], "Renaming…") }
    function updateLayout(p) { act(["layout-update", "--id=" + p.id], "Updating " + p.name + "…") }
    function favoriteLayout(p) { act(["layout-favorite", "--id=" + p.id, "--value=" + (p.favorite ? "false" : "true")], p.favorite ? "Unstarring…" : "Starring…") }
    function deleteLayout(p) { act(["layout-delete", "--id=" + p.id], "Deleting " + p.name + "…") }
    function loadHistory() { call("history", ["status"]) }
    function takeSnapshot() { call("history", ["scan"]) }

    function settle() {
        if (!exited || !outDone) return
        watchdog.stop()
        var kind = runningKind
        try {
            if (timedOut) throw new Error("omaguard.py timed out. Nothing was changed.")
            if (!outText.trim())
                throw new Error(exitCode === 127 ? "python3 was not found on PATH, so OmaGuard cannot run."
                                                 : (errText.trim() || "omaguard.py produced no output (exit " + exitCode + ")"))
            var result = JSON.parse(outText)
            if (result.error) throw new Error(result.error)
            lastError = ""
            if (kind === "history") historyState = result
            else {
                layoutState = result
                answered = true
                var a = result.lastAction
                if (root.localPending && a && !a.pending && a.epoch * 1000 >= root.pendingSince - 1000) root.localPending = ""
                if (a && a.pending) { root.fastTicks = 0; fastPoll.restart() }
            }
        } catch (e) {
            var problem = String(e.message || e).slice(0, 400)
            lastError = problem
        }
        busy = false
        runningKind = ""
        if (queue.length) {
            var next = queue[0]
            queue = queue.slice(1)
            start(next.kind, next.args)
        }
    }
    onOpenedChanged: if (opened) { refresh(); if (view === "details") loadHistory() } else { saveAsOpen = false; renameId = "" }

    // The outcome to show: your click while it is on its way, then the helper's
    // record (which survives this widget being rebuilt), for ten minutes.
    readonly property var shownAction: {
        var a = layoutState.lastAction
        if (localPending) return {pending: true, note: localPending}
        if (!a) return null
        if (a.pending) return {pending: true, note: (a.label || "Working") + "…"}
        if (Date.now() - a.epoch * 1000 > 600000) return null
        return a
    }
    property int fastTicks: 0
    Timer {
        id: fastPoll
        interval: 1000
        repeat: true
        onTriggered: {
            root.fastTicks += 1
            var a = root.layoutState.lastAction
            var waiting = root.localPending || (a && a.pending)
            if (!waiting || root.fastTicks > 30) { stop(); if (root.fastTicks > 30) root.localPending = ""; return }
            if (!root.busy) root.refresh()
        }
    }
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
        function load(name: string): string {
            var p = root.layouts.find(function (x) { return x.name.toLowerCase() === name.toLowerCase() })
            if (!p) return "no layout named " + name
            root.loadCalls += 1
            root.loadLayout(p)
            return "instance " + root.instanceId + ": started " + p.name
        }
        function save(): void { root.saveLayout() }
        function undo(): void { root.undoChanges() }
        function status(): string {
            return JSON.stringify({
                instance: root.instanceId, loadCalls: root.loadCalls,
                opened: root.opened, version: root.version, view: root.view, verdict: root.verdict,
                headline: root.headline, problems: root.problems.map(function (c) { return {name: c.name, detail: c.detail, fix: c.fix} }),
                loaded: root.loadedName || null, unsaved: root.unsaved, unsavedChanges: root.layoutState.unsavedChanges || [],
                layouts: root.layouts.map(function (p) { return {name: p.name, loaded: p.loaded, note: root.rowNote(p), canSwitch: p.canSwitch} }),
                lastResult: root.shownAction, error: root.lastError, busy: root.busy, queued: root.queue.length
            })
        }
    }

    WidgetButton {
        id: barButton
        bar: root.bar
        anchors.fill: parent
        text: root.glyph + (root.problems.length ? " " + root.problems.length : "")
        foreground: root.tint
        tooltipText: "OmaGuard · " + root.headline
                     + (root.problems.length ? "\nClick to see how to fix it" : "")
                     + (root.loadedName ? "\nLayout: " + root.loadedName + (root.unsaved ? " (unsaved changes)" : "") : "")
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
        focusTarget: root.saveAsOpen ? saveAsField : null
        contentWidth: fittedContentWidth(680)
        // LAW 17: the panel fits its content; only lists scroll, in place.
        // fittedContentHeight adds the card's padding and border; the capped
        // variant expects them already included, and the footer spilled out.
        contentHeight: fittedContentHeight(body.implicitHeight)

        Column {
            id: body
            width: parent.width
            spacing: 10

            // ── Title + verdict ──────────────────────────────────────────
            Row {
                width: parent.width
                spacing: 10
                Text { text: root.glyph; color: root.tint; font.family: Style.font.family; font.pixelSize: 26; anchors.verticalCenter: parent.verticalCenter }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text { text: "OMAGUARD"; color: root.ink; font.family: Style.font.family; font.pixelSize: 15; font.bold: true; font.letterSpacing: 1.4 }
                    Text { text: (root.verdict === "holding" ? "✓ " : "") + root.headline; color: root.tint; font.pixelSize: 14; font.bold: true; textFormat: Text.PlainText }
                }
            }

            // ── Problems: only confirmed ones, each with how to fix it ───
            Rectangle {
                visible: root.problems.length > 0 || root.verdict === "fault"
                width: parent.width
                height: problemColumn.implicitHeight + 20
                radius: Math.max(4, Style.cornerRadius)
                color: Qt.alpha(Color.urgent, 0.08)
                border.width: 1
                border.color: Qt.alpha(Color.urgent, 0.45)
                Column {
                    id: problemColumn
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                    spacing: 6
                    Text { visible: root.verdict === "fault"; width: parent.width; text: root.lastError; color: Color.urgent; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                    Repeater {
                        model: root.problems
                        delegate: Column {
                            required property var modelData
                            width: problemColumn.width
                            spacing: 2
                            Text { width: parent.width; text: modelData.name; color: Color.urgent; font.pixelSize: 13; font.bold: true; textFormat: Text.PlainText }
                            Text { width: parent.width; text: modelData.detail; color: root.ink; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                            Text { width: parent.width; visible: modelData.fix.length > 0; text: "How to fix: " + modelData.fix; color: root.muted; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        }
                    }
                    Button { text: root.busy ? "Checking…" : "Check again"; enabled: !root.busy; onClicked: root.refresh() }
                }
            }

            // ── The last thing you asked for, and how it went ────────────
            Text {
                width: parent.width
                visible: root.shownAction !== null
                text: root.shownAction
                      ? (root.shownAction.pending ? "" : (root.resultOk(root.shownAction) ? "✓ " : "✗ ")) + root.shownAction.note
                        + (root.shownAction.steps || []).filter(function (st) { return st.ok === false || st.result === "not attempted" })
                            .map(function (st) { return "\n   " + st.action + " " + st.id + ": " + st.result }).join("")
                      : ""
                color: root.shownAction && !root.shownAction.pending && !root.resultOk(root.shownAction) ? Color.urgent : Color.accent
                font.pixelSize: 12
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }

            // ════════════════════ MAIN: your layouts ═════════════════════
            Column {
                visible: root.view === "main"
                width: parent.width
                spacing: 8

                Text { text: "BAR LAYOUTS"; color: root.muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2 }
                Text {
                    width: parent.width
                    visible: (root.layoutState.liveError || "").length > 0
                    text: root.layoutState.liveError || ""
                    color: Color.urgent
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                ListView {
                    id: layoutList
                    width: parent.width
                    height: Math.min(count, 6) * 52
                    visible: count > 0
                    model: root.layouts
                    spacing: 4
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: layoutList.count > 6 ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff }
                    delegate: Rectangle {
                        required property var modelData
                        width: layoutList.width - (layoutList.count > 6 ? 12 : 0)
                        height: 48
                        radius: Math.max(4, Style.cornerRadius)
                        color: Qt.alpha(root.ink, modelData.loaded ? 0.09 : 0.035)
                        border.width: 1
                        border.color: modelData.loaded ? Qt.alpha(root.unsaved ? Color.urgent : Color.accent, 0.6) : Qt.alpha(root.ink, 0.10)

                        Text {
                            id: dot
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            text: modelData.loaded ? "●" : "○"
                            color: modelData.loaded ? Color.accent : root.muted
                            font.pixelSize: 16
                        }
                        Text {
                            id: star
                            anchors { left: dot.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                            text: modelData.favorite ? "★" : "☆"
                            color: modelData.favorite ? Color.accent : root.muted
                            font.pixelSize: 18
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.favoriteLayout(modelData)
                            }
                        }
                        Column {
                            visible: root.renameId !== modelData.id
                            anchors { left: star.right; leftMargin: 10; right: actions.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            spacing: 1
                            Text { width: parent.width; text: modelData.name; color: root.ink; font.pixelSize: 14; font.bold: true; elide: Text.ElideRight; textFormat: Text.PlainText }
                            Text {
                                width: parent.width
                                text: root.rowNote(modelData)
                                color: modelData.blocked ? Color.urgent : modelData.loaded && root.unsaved ? Color.urgent : root.muted
                                font.pixelSize: 11
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                        }
                        TextField {
                            id: renameField
                            visible: root.renameId === modelData.id
                            anchors { left: star.right; leftMargin: 10; right: actions.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: modelData.name
                            onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() }
                            onAccepted: if (text.trim().length) root.renameLayout(modelData.id, text.trim())
                        }
                        Row {
                            id: actions
                            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            spacing: 4
                            // Always shown, so you never have to hunt for it. Greyed out
                            // when loading would change nothing (the row note says why).
                            Button {
                                visible: root.renameId !== modelData.id
                                text: "Load"
                                // Not tied to busy: that flips every poll and would flicker
                                // the button. A click while busy is queued, never dropped.
                                enabled: modelData.canSwitch
                                opacity: enabled ? 1 : 0.35
                                onClicked: root.loadLayout(modelData)
                            }
                            // Take the bar as it is now into this layout, whichever one is
                            // loaded. Hidden when the layout already matches the bar.
                            Button {
                                visible: root.renameId !== modelData.id && !modelData.active
                                text: "Update"
                                onClicked: root.updateLayout(modelData)
                            }
                            Button { visible: root.renameId !== modelData.id; text: "Rename"; onClicked: root.renameId = modelData.id }
                            Button { visible: root.renameId !== modelData.id; text: "Delete"; onClicked: root.deleteLayout(modelData) }
                            Button { visible: root.renameId === modelData.id; text: "Save"; onClicked: if (renameField.text.trim().length) root.renameLayout(modelData.id, renameField.text.trim()) }
                            Button { visible: root.renameId === modelData.id; text: "Cancel"; onClicked: root.renameId = "" }
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: root.answered && root.layouts.length === 0
                    text: "No layouts yet. Arrange the bar the way you like it, then Save as new."
                    color: root.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                // ── Unsaved changes to the loaded layout ────────────────
                Rectangle {
                    visible: root.unsaved
                    width: parent.width
                    height: unsavedColumn.implicitHeight + 20
                    radius: Math.max(4, Style.cornerRadius)
                    color: Qt.alpha(root.ink, 0.05)
                    border.width: 1
                    border.color: Qt.alpha(root.ink, 0.18)
                    Column {
                        id: unsavedColumn
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                        spacing: 4
                        Text { width: parent.width; text: root.loadedName + " has unsaved changes"; color: root.ink; font.pixelSize: 13; font.bold: true; textFormat: Text.PlainText }
                        Repeater {
                            model: (root.layoutState.unsavedChanges || []).slice(0, 3)
                            delegate: Text {
                                required property var modelData
                                width: unsavedColumn.width
                                text: "•  " + modelData
                                color: root.muted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                        }
                        Text {
                            visible: (root.layoutState.unsavedChanges || []).length > 3
                            text: "   and " + ((root.layoutState.unsavedChanges || []).length - 3) + " more"
                            color: root.muted
                            font.pixelSize: 12
                        }
                        Flow {
                            width: parent.width
                            spacing: 6
                            topPadding: 4
                            Button { text: "Save to " + root.loadedName; enabled: !root.busy; onClicked: root.saveLayout() }
                            Button { text: "Undo"; enabled: !root.busy && root.layoutState.canUndo === true; onClicked: root.undoChanges() }
                            Button { text: "Save as new…"; visible: !root.saveAsOpen; onClicked: root.saveAsOpen = true }
                        }
                        Text {
                            width: parent.width
                            visible: (root.layoutState.undoReason || "").length > 0
                            text: "Undo isn't possible: " + root.layoutState.undoReason
                            color: Color.urgent
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }
                }

                // ── The bar isn't any saved layout ──────────────────────
                Text {
                    width: parent.width
                    visible: root.answered && !root.layoutState.loaded && root.layouts.length > 0
                    text: "Your bar right now isn't saved as a layout."
                    color: root.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                // ── Save as new ─────────────────────────────────────────
                Row {
                    visible: root.saveAsOpen
                    width: parent.width
                    spacing: 6
                    TextField {
                        id: saveAsField
                        width: parent.width - saveAsButton.width - cancelButton.width - 12
                        placeholderText: "Name this layout, e.g. Work or Focus"
                        onVisibleChanged: if (visible) { text = ""; Qt.callLater(function () { saveAsField.forceActiveFocus() }) }
                        TapHandler { onTapped: saveAsField.forceActiveFocus() }
                        onAccepted: if (text.trim().length) root.saveAs(text.trim())
                    }
                    Button { id: saveAsButton; text: "Save"; enabled: saveAsField.text.trim().length > 0; onClicked: root.saveAs(saveAsField.text.trim()) }
                    Button { id: cancelButton; text: "Cancel"; onClicked: root.saveAsOpen = false }
                }

                Row {
                    spacing: 6
                    Button { text: "Save as new…"; visible: !root.saveAsOpen && !root.unsaved; onClicked: root.saveAsOpen = true }
                    Button { text: "Details: checks · history ›"; onClicked: { root.view = "details"; root.loadHistory() } }
                }
            }

            // ════════════════════ DETAILS ════════════════════════════════
            Column {
                visible: root.view === "details"
                width: parent.width
                spacing: 8

                Button { text: "‹ Back to layouts"; onClicked: root.view = "main" }

                Text { text: "CHECKS"; color: root.muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2 }
                Text {
                    width: parent.width
                    text: "Judged on the running desktop. CAN'T TELL means OmaGuard could not ask — never a pass, never a problem."
                    color: root.muted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                Repeater {
                    model: root.checks
                    delegate: Row {
                        required property var modelData
                        width: parent.width
                        spacing: 8
                        Text { width: 86; text: root.statusWord(modelData.status); color: root.statusColor(modelData.status); font.pixelSize: 10; font.bold: true; font.letterSpacing: 0.8; anchors.verticalCenter: parent.verticalCenter }
                        Text { width: 150; text: modelData.name; color: root.ink; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                        Text { width: parent.width - 260; text: modelData.detail; color: root.muted; font.pixelSize: 11; elide: Text.ElideRight; textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 8
                    topPadding: 6
                    Text { text: "HISTORY"; color: root.muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2; anchors.verticalCenter: parent.verticalCenter }
                    Button { text: root.busy ? "Working…" : "Take snapshot"; enabled: !root.busy; onClicked: root.takeSnapshot() }
                }
                Text {
                    width: parent.width
                    text: "A snapshot copies your six desktop config files. Compare or preview a restore with omaguard.py in a terminal."
                    color: root.muted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                ListView {
                    id: historyList
                    width: parent.width
                    height: Math.min(count, 6) * 30
                    visible: count > 0
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: (root.historyState.timeline || []).slice().reverse()
                    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: historyList.count > 6 ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff }
                    delegate: Row {
                        required property var modelData
                        width: historyList.width
                        height: 30
                        spacing: 10
                        Text { width: 170; text: root.shortTime(modelData.time); color: root.ink; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                        Text { width: parent.width - 180; text: modelData.summary; color: root.muted; font.pixelSize: 11; elide: Text.ElideRight; textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
            }

            Text {
                width: parent.width
                text: "OmaGuard " + root.version + " · ★ favourites stay on top · Update saves the bar into that layout"
                      + (root.autoAdd ? " · widgets you add join the loaded layout" : "")
                color: root.muted
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }
        }
    }
}
