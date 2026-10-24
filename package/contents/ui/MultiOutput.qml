/*
    SPDX-FileCopyrightText: 2026 lckt0
    SPDX-License-Identifier: GPL-2.0-or-later

    Multi-output controller for io.github.lckt0.volume.

    Backend: pipewire-pulse "module-combine-sink" (internally
    libpipewire-module-combine-stream). It is created on demand when two or more
    outputs are checked and unloaded again when fewer than two remain. Nothing
    here polls: every action is driven by a user click or by a sink/module
    add/remove event coming from the existing PulseAudio context.

    PulseAudioQt::Context::loadModule() exists but is not Q_INVOKABLE and the
    plasma-pa QML plugin does not expose it, so loading/unloading goes through a
    one-shot `pactl` call (Plasma5Support "executable" engine, no interval).
*/

import QtQuick

import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.kitemmodels as KItemModels

import org.kde.plasma.private.volume

QtObject {
    id: mo

    required property SinkModel sinkModel

    // Every combined sink this applet creates is named <prefix>a or <prefix>b.
    // Alternating the name lets us build the new sink, move the default to it
    // and only then unload the old one, so changing the set does not route
    // audio through a random fallback device for a moment.
    readonly property string sinkPrefix: "lckt0_multi_output_"
    readonly property string combinedDescription: i18nc("@label name of the virtual output that plays on several devices", "Combined Output")

    readonly property bool enabled: Plasmoid.configuration.multiOutputEnabled
    readonly property var members: Plasmoid.configuration.multiOutputSinks
    readonly property bool latencyCompensate: Plasmoid.configuration.multiOutputLatencyCompensate

    // [{ index: int, sinkName: string, slaves: [string] }], rebuilt from ModuleModel,
    // minus modules we already asked to unload.
    property var modules: []
    readonly property var active: pickActive(modules)
    readonly property string activeSinkName: active ? active.sinkName : ""
    readonly property var activeSlaves: active ? active.slaves : []

    property int inFlight: 0
    property string pendingDefault: ""
    // Name of a sink we just loaded but that ModuleModel does not list yet.
    // The PulseAudio introspection events for the sink and for the module
    // arrive separately; without this, sync() could see "no module" in
    // between and load a second one.
    property string awaitingModule: ""
    // Module indexes we asked to unload (index -> true) until they disappear.
    property var unloading: ({})
    property string lastError: ""
    property string lastFailedKey: ""
    property bool settled: false
    readonly property bool contextReady: Context.state === Context.State.Ready

    readonly property url scriptUrl: Qt.resolvedUrl("../code/multi-output.sh")
    property int runSerial: 0
    property var callbacks: ({})

    // ---- public API used by the UI -------------------------------------

    function isOurs(name) {
        return typeof name === "string" && name.startsWith(sinkPrefix)
    }

    function isMember(name) {
        return (members || []).includes(name)
    }

    // True for the internal per-device streams of our combined sink, so the
    // "Applications" tab does not list them as if they were apps.
    function isOwnStream(properties) {
        if (!properties) {
            return false
        }
        const id = properties["pulse.module.id"]
        if (id === undefined) {
            return false
        }
        return modules.some(m => String(m.index) === String(id))
    }

    function setEnabled(on) {
        if (on === enabled) {
            return
        }
        if (on) {
            const def = PreferredDevice.sink
            const seed = (def && !isOurs(def.name) && def.name !== "auto_null") ? [def.name] : []
            Plasmoid.configuration.multiOutputSinks = seed
            Plasmoid.configuration.multiOutputEnabled = true
        } else {
            const target = (members || []).find(n => sinkByName(n) !== null) || ""
            Plasmoid.configuration.multiOutputEnabled = false
            Plasmoid.configuration.multiOutputSinks = []
            if (modules.length > 0) {
                dissolve(target)
            }
        }
    }

    function toggle(name) {
        if (!enabled || isOurs(name)) {
            return
        }
        let list = (members || []).slice()
        if (list.includes(name)) {
            if (list.length <= 1) {
                return // keep at least one output checked
            }
            list = list.filter(n => n !== name)
        } else {
            list.push(name)
        }
        Plasmoid.configuration.multiOutputSinks = list
        lastFailedKey = ""
        if (list.length === 1 && modules.length === 0) {
            const sink = sinkByName(list[0])
            if (sink) {
                sink.default = true
            }
        }
        Qt.callLater(sync)
    }

    // ---- internals -------------------------------------------------------

    function pickActive(list) {
        if (list.length === 0) {
            return null
        }
        const def = PreferredDevice.sink
        const byDefault = def ? list.find(m => m.sinkName === def.name) : undefined
        return byDefault || list[list.length - 1]
    }

    function roleOf(model, name) {
        return model.KItemModels.KRoleNames.role(name)
    }

    function sinkByName(name) {
        if (!name) {
            return null
        }
        const role = roleOf(sinkModel, "PulseObject")
        for (let i = 0; i < sinkModel.rowCount(); ++i) {
            const obj = sinkModel.data(sinkModel.index(i, 0), role)
            if (obj && obj.name === name) {
                return obj
            }
        }
        return null
    }

    function parseSlaves(argument) {
        const m = /(?:^|\s)(?:slaves|sinks)=(\S+)/.exec(argument || "")
        return m ? m[1].split(",").filter(s => s.length > 0) : []
    }

    function refreshModules() {
        const role = roleOf(moduleModel, "PulseObject")
        const re = new RegExp("(?:^|\\s)sink_name=(" + sinkPrefix + "[A-Za-z0-9_]+)(?:\\s|$)")
        const out = []
        const seen = {}
        for (let i = 0; i < moduleModel.rowCount(); ++i) {
            const module = moduleModel.data(moduleModel.index(i, 0), role)
            if (!module || module.name !== "module-combine-sink") {
                continue
            }
            const m = re.exec(module.argument || "")
            if (!m) {
                continue
            }
            seen[module.index] = true
            if (m[1] === awaitingModule) {
                awaitingModule = ""
                awaitTimer.stop()
            }
            if (!unloading[module.index]) {
                out.push({ index: module.index, sinkName: m[1], slaves: parseSlaves(module.argument) })
            }
        }
        for (const idx of Object.keys(unloading)) {
            if (!seen[idx]) {
                delete unloading[idx]
            }
        }
        modules = out
    }

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    function run(args, callback) {
        const path = decodeURIComponent(String(scriptUrl).replace(/^file:\/\//, ""))
        runSerial += 1
        // The trailing comment only keeps command strings unique for the engine.
        const cmd = "/bin/sh " + [path].concat(args).map(shellQuote).join(" ") + " #" + runSerial
        callbacks[cmd] = callback
        inFlight += 1
        runner.connectSource(cmd)
    }

    function finished(cmd, data) {
        runner.disconnectSource(cmd)
        const cb = callbacks[cmd]
        delete callbacks[cmd]
        inFlight = Math.max(0, inFlight - 1)
        const code = data["exit code"]
        const out = (data.stdout || "").trim()
        const err = (data.stderr || "").trim()
        if (code !== 0) {
            console.warn("io.github.lckt0.volume: multi-output helper failed", code, err || out)
        }
        if (cb) {
            cb(code, out, err)
        }
        Qt.callLater(sync)
    }

    function build(slaves) {
        const name = sinkPrefix + (activeSinkName === sinkPrefix + "a" ? "b" : "a")
        const key = slaves.slice().sort().join(",")
        run(["load", name, latencyCompensate ? "1" : "0", combinedDescription].concat(slaves), (code, out, err) => {
            if (code !== 0) {
                lastError = err || out || ("exit " + code)
                lastFailedKey = key
                return
            }
            lastError = ""
            lastFailedKey = ""
            awaitingModule = name
            awaitTimer.restart()
            refreshModules() // it may already be listed
            pendingDefault = name
            applyPendingDefault()
        })
    }

    function unloadModules(keepSinkName) {
        const doomed = modules.filter(m => m.sinkName !== keepSinkName)
        if (doomed.length === 0) {
            return
        }
        for (const m of doomed) {
            unloading[m.index] = true
            run(["unload", String(m.index)], () => {})
        }
        modules = modules.filter(m => m.sinkName === keepSinkName)
    }

    function dissolve(targetName) {
        const target = sinkByName(targetName)
        if (target) {
            target.default = true // move streams first, then remove the combined sink
        }
        unloadModules("")
    }

    function applyPendingDefault() {
        if (!pendingDefault) {
            return
        }
        const sink = sinkByName(pendingDefault)
        if (!sink) {
            return // wait for the sink to show up in the model
        }
        const keep = pendingDefault
        sink.default = true
        pendingDefault = ""
        unloadModules(keep)
    }

    function sync() {
        if (!contextReady || !settled || inFlight > 0 || pendingDefault || awaitingModule) {
            return
        }
        const list = members || []

        if (!enabled || list.length < 2) {
            if (modules.length > 0) {
                dissolve(list.find(n => sinkByName(n) !== null) || "")
            }
            return
        }

        const present = list.filter(n => !isOurs(n) && sinkByName(n) !== null)

        if (!active) {
            if (present.length >= 2 && present.slice().sort().join(",") !== lastFailedKey) {
                build(present)
            }
            return
        }

        // A checked device that the running combined sink does not cover
        // (plugged in later, or newly checked) -> rebuild. A device that was
        // merely disconnected is left alone: combine-stream re-attaches it by
        // node.name when it comes back.
        const missing = present.filter(n => !activeSlaves.includes(n))
        const removed = activeSlaves.filter(n => !list.includes(n))
        if (missing.length > 0 || removed.length > 0) {
            if (present.length >= 2) {
                if (present.slice().sort().join(",") !== lastFailedKey) {
                    build(present)
                }
            } else {
                dissolve(present[0] || "")
            }
            return
        }

        if (modules.length > 1) {
            unloadModules(activeSinkName) // leftovers, e.g. after a plasmashell restart mid-switch
        }
    }

    // ---- objects ---------------------------------------------------------

    readonly property ModuleModel moduleModel: ModuleModel {}

    readonly property P5Support.DataSource runner: P5Support.DataSource {
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => mo.finished(sourceName, data)
    }

    // One-shot grace period after connecting so the initial sink/module
    // enumeration is complete before we decide anything. Not a poll.
    readonly property Timer settleTimer: Timer {
        interval: 1500
        repeat: false
        running: mo.contextReady && !mo.settled
        onTriggered: {
            mo.refreshModules()
            mo.settled = true
            mo.sync()
        }
    }

    // Safety net: if the module never shows up in ModuleModel, stop waiting.
    readonly property Timer awaitTimer: Timer {
        interval: 5000
        repeat: false
        onTriggered: {
            mo.awaitingModule = ""
            mo.refreshModules()
            Qt.callLater(mo.sync)
        }
    }

    readonly property Connections moduleWatcher: Connections {
        target: mo.moduleModel
        function onRowsInserted() { mo.refreshModules(); Qt.callLater(mo.sync) }
        function onRowsRemoved() { mo.refreshModules(); Qt.callLater(mo.sync) }
        function onModelReset() { mo.refreshModules(); Qt.callLater(mo.sync) }
    }

    readonly property Connections sinkWatcher: Connections {
        target: mo.sinkModel
        function onRowsInserted() { Qt.callLater(mo.applyPendingDefault); Qt.callLater(mo.sync) }
        function onRowsRemoved() { Qt.callLater(mo.sync) }
    }

    // With multi-output on but fewer than two outputs checked there is no
    // combined sink; keep the single checked entry in step with the default
    // device if it is changed elsewhere (System Settings, kded, WirePlumber).
    readonly property Connections defaultWatcher: Connections {
        target: PreferredDevice
        function onSinkChanged() {
            const sink = PreferredDevice.sink
            if (!mo.enabled || mo.modules.length > 0 || mo.inFlight > 0 || mo.pendingDefault || mo.awaitingModule) {
                return
            }
            if ((mo.members || []).length <= 1 && sink && !mo.isOurs(sink.name) && sink.name !== "auto_null") {
                Plasmoid.configuration.multiOutputSinks = [sink.name]
            }
        }
    }
}
