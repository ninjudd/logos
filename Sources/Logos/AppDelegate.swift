import AppKit
import AVFoundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = OverlayController()
    private let hotkey = HotkeyMonitor()
    private lazy var settings = SettingsWindowController(hotkey: hotkey)
    private var statusItem: NSStatusItem!

    private var recorder: Recorder?
    /// Starts and stops the microphone off the main thread. Core Audio can stall
    /// while devices change, such as when a display or audio interface connects,
    /// and Logos must stay responsive when it does.
    private var audioQueue = DispatchQueue(label: "com.ninjudd.logos.audio")
    /// Whether the hotkey is down for the current dictation.
    private var holding = false
    /// Identifies the microphone start in flight, so a late or abandoned one is discarded.
    private var startID = 0
    private var startInFlight: Int?
    private var pressedAt = Date()
    private var targetApp = ""
    private var targetRunningApp: NSRunningApplication?
    private var overlayShown = false
    private var meterTimer: Timer?

    /// Dictations still being transcribed or cleaned up. Each one pastes only after
    /// the one before it, so text lands in the order you spoke it.
    private var pending = 0
    private var stageLabel = "Transcribing…"
    private var chain: Task<Void, Never>?
    private var lastText: String?
    private var trustTimer: Timer?
    private var availableUpdate: String?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        ConfigStore.shared.ensureFiles()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = Self.mainMenu()

        hotkey.hotkey = { ConfigStore.shared.current.hotkey }
        hotkey.onPress = { [weak self] in MainActor.assumeIsolated { self?.startRecording() } }
        hotkey.onRelease = { [weak self] in MainActor.assumeIsolated { self?.finishRecording() } }
        hotkey.onCancel = { [weak self] in MainActor.assumeIsolated { self?.cancelRecording() } }
        hotkey.onKeyDown = { [weak self] keyCode in
            MainActor.assumeIsolated {
                let escape: UInt16 = 53
                if keyCode == escape, self?.overlay.isShowingResult == true { self?.overlay.hide() }
            }
        }
        hotkey.install()
        watchAccessibility()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let transcription = ConfigStore.shared.current.transcription
        Task { await Transcriber.prepare(transcription) }
        if let error = ConfigStore.shared.lastError { overlay.flash(error) }

        checkForUpdate()
        // The cache limits this to one request to GitHub a day.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdate() }
        }
    }

    /// Two copies would both answer the hotkey and paste every dictation twice.
    /// The newest copy wins, because installs and updates start the new version.
    private func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current }
        for other in others { other.terminate() }
        guard !others.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for other in others where !other.isTerminated { other.forceTerminate() }
        }
    }

    // MARK: Updates

    private func checkForUpdate() {
        Task { @MainActor in
            guard let tag = await Updater.latestTagCached(),
                  Updater.isNewer(tag, than: Updater.installedVersion) else { return }
            availableUpdate = tag
        }
    }

    /// Runs the release's installer in the background. It builds the new version,
    /// replaces this app, and starts it, so this process ends when it succeeds.
    @objc private func installUpdate() {
        guard let tag = availableUpdate else { return }
        overlay.flash("Building Logos \(tag). It restarts when the build finishes.", seconds: 6, success: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let installer = try await Updater.installer(tag: tag)
                let process = Updater.installProcess(installer: installer, tag: tag)
                FileManager.default.createFile(atPath: Paths.updateLog.path, contents: nil)
                let log = try FileHandle(forWritingTo: Paths.updateLog)
                process.standardOutput = log
                process.standardError = log
                process.terminationHandler = { [weak self] process in
                    guard process.terminationStatus != 0 else { return }
                    Task { @MainActor in self?.overlay.flash("Update failed. See \(Paths.updateLog.path)") }
                }
                try process.run()
            } catch {
                overlay.flash("Update failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard !holding, recorder == nil, startInFlight == nil else { return }
        holding = true
        startID += 1
        let id = startID
        startInFlight = id
        let device = ConfigStore.shared.current.inputDevice
        audioQueue.async { [weak self] in
            let result = Result { try Recorder.start(inputDevice: device) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.microphoneStarted(result, id: id) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.microphoneTimedOut(id) }
        }
        pressedAt = Date()
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = frontmost?.localizedName ?? "an unknown app"
        targetRunningApp = frontmost
        if let pid = frontmost?.processIdentifier { FocusedField.prepare(pid: pid) }
        overlayShown = false
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func microphoneStarted(_ result: Result<Recorder, Error>, id: Int) {
        guard id == startID, startInFlight == id else {
            // Abandoned after timing out; nothing is waiting for it.
            if case .success(let late) = result { discard(late) }
            return
        }
        startInFlight = nil
        switch result {
        case .success(let started) where holding:
            recorder = started
        case .success(let started):
            // Released before the microphone started, which is too short to keep.
            discard(started)
        case .failure(let error):
            _ = endRecording()
            overlay.flash(error.localizedDescription)
        }
    }

    /// Gives up on a microphone that hasn't started in time. Its thread may stay
    /// stuck, so later recordings use a fresh one.
    private func microphoneTimedOut(_ id: Int) {
        guard startInFlight == id else { return }
        startInFlight = nil
        startID += 1
        audioQueue = DispatchQueue(label: "com.ninjudd.logos.audio")
        _ = endRecording()
        overlay.flash("The microphone didn't respond. Try again, or choose another microphone in Settings.")
        NSLog("Logos: the microphone took more than 3 seconds to start; abandoned it")
    }

    private func discard(_ recorder: Recorder) {
        audioQueue.async { recorder.discard() }
    }

    /// Stops `recorder` on the audio queue and waits, so its file is complete.
    private func stop(_ recorder: Recorder) async {
        let queue = audioQueue
        await withCheckedContinuation { continuation in
            queue.async {
                recorder.stop()
                continuation.resume()
            }
        }
    }

    private func tick() {
        guard let recorder else { return }
        // Wait a moment before showing anything, so quick ⌥-shortcuts don't flash the overlay.
        if !overlayShown && Date().timeIntervalSince(pressedAt) >= 0.15 {
            overlayShown = true
            overlay.show(.recording)
            setIcon(recording: true)
        }
        if overlayShown { overlay.model.update(recorder.spectrum) }
    }

    private func endRecording() -> Recorder? {
        meterTimer?.invalidate()
        meterTimer = nil
        let r = recorder
        recorder = nil
        setIcon(recording: false)
        return r
    }

    private func cancelRecording() {
        holding = false
        if let r = endRecording() { discard(r) }
        refreshOverlay()
    }

    private func finishRecording() {
        holding = false
        guard let r = endRecording() else {
            refreshOverlay()
            return
        }
        let config = ConfigStore.shared.current
        guard Date().timeIntervalSince(pressedAt) >= config.minHoldSeconds else {
            discard(r)
            refreshOverlay()
            return
        }

        let audio = r.url
        let prompt = ConfigStore.shared.prompt
        let app = targetApp
        // Read the field now, before anything else can change it.
        var context = config.readCursorContext ? AppContext.capture(app: targetRunningApp) : AppContext()
        let provided = ContextFiles.load(bundleID: targetRunningApp?.bundleIdentifier)
        context.hints = provided.hints
        let vocabulary = Vocabulary.merge(ConfigStore.shared.dictionary, provided.words)
        let previous = chain
        pending += 1
        stageLabel = "Transcribing…"
        refreshOverlay()

        chain = Task { @MainActor [weak self] in
            await self?.stop(r)
            let result: Result<Pipeline.Outcome, Error>
            do {
                result = .success(try await Pipeline.run(audio: audio, config: config, prompt: prompt,
                                                         vocabulary: vocabulary, app: app, context: context) { stage in
                    Task { @MainActor in
                        self?.stageLabel = stage
                        self?.refreshOverlay()
                    }
                })
            } catch {
                result = .failure(error)
            }
            try? FileManager.default.removeItem(at: audio)
            await previous?.value
            self?.deliver(result, config: config)
        }
    }

    private func deliver(_ result: Result<Pipeline.Outcome, Error>, config: Config) {
        pending -= 1
        switch result {
        case .failure(let error):
            overlay.flash(error.localizedDescription)
            return
        case .success(let outcome):
            if !outcome.text.isEmpty {
                lastText = outcome.text
                if hasNowhereToPaste(config) {
                    let text = outcome.text
                    overlay.showResult(text) { [weak self] in
                        Paster.copy(text)
                        self?.overlay.flash("Copied", seconds: 1.5, success: true)
                    }
                    return
                }
                Paster.paste(outcome.text + (config.trailingSpace ? " " : ""), restoreClipboard: config.restoreClipboard)
                if !AXIsProcessTrusted() {
                    overlay.flash("Copied to the clipboard. Grant Accessibility access to paste automatically.")
                    return
                }
            }
            if let warning = outcome.warning {
                overlay.flash(warning)
                return
            }
        }
        refreshOverlay()
    }

    private func refreshOverlay() {
        if recorder != nil && overlayShown {
            overlay.show(.recording)
        } else if pending > 0 && !overlay.isShowingResult {
            overlay.show(.processing(stageLabel))
        } else if !overlay.isHoldingContent {
            overlay.hide()
        }
    }

    /// True when the focused element can't take text, so pressing ⌘V would lose
    /// the dictation. Without Accessibility access Logos can't tell, and copies.
    private func hasNowhereToPaste(_ config: Config) -> Bool {
        guard config.showWhenNoTextField, AXIsProcessTrusted() else { return false }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, config.alwaysPasteApps.contains(id) {
            return false
        }
        return FocusedField.acceptsText(FocusedField.current()) == false
    }

    // MARK: Accessibility

    /// Logos needs Accessibility access to see the hotkey in other apps and to press ⌘V.
    /// Monitors installed before access is granted stay deaf, so reinstall once it is.
    private func watchAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                timer.invalidate()
                self.trustTimer = nil
                self.hotkey.install()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = ConfigStore.shared.current
        menu.addItem(NSMenuItem(title: "Logos \(Updater.installedVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hold \(config.hotkey) to dictate", action: nil, keyEquivalent: ""))
        if let availableUpdate {
            menu.addItem(item("Update to \(availableUpdate)…", #selector(installUpdate)))
        }
        if let error = ConfigStore.shared.lastError {
            menu.addItem(NSMenuItem(title: "⚠︎ \(error)", action: nil, keyEquivalent: ""))
        }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("Open History", #selector(openHistory)))
        let copy = item("Copy Last Dictation", #selector(copyLast))
        copy.isEnabled = lastText != nil
        menu.addItem(copy)
        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Logos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettings() { settings.show() }

    /// Logos shows no menu bar, but text fields take ⌘C, ⌘V, ⌘A, and ⌘Z only
    /// from menu items, so the Settings window needs an Edit menu to exist.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        app.addItem(NSMenuItem(title: "Quit Logos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        for submenu in [app, edit] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
    }

    @objc private func openHistory() {
        if !FileManager.default.fileExists(atPath: Paths.history.path) {
            FileManager.default.createFile(atPath: Paths.history.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(Paths.history)
    }

    @objc private func copyLast() {
        guard let lastText else { return }
        Paster.copy(lastText)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            overlay.flash("Launch at Login: \(error.localizedDescription)")
        }
    }

    private func setIcon(recording: Bool) {
        statusItem?.button?.image = Glyph.menuBarImage(recording: recording)
    }
}
