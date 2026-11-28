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
    private var audioQueue = AppDelegate.makeAudioQueue()
    private var microphone = MicrophoneStart()
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
    private var isCheckingForUpdates = false
    /// The release being installed, while its installer runs.
    private var updating: String?

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
        if ConfigStore.shared.current.useContacts { Task { await ContactsIndex.shared.enable() } }
        if let update = Updater.takePending() {
            let message = Updater.launchMessage(after: update)
            overlay.flash(message.text, seconds: 6, success: message.success)
        }
        // A broken config matters more than an update's news, so its message replaces it.
        if let error = ConfigStore.shared.lastError { overlay.flash(error) }

        checkAutomatically()
        // The cache limits this to one request to GitHub a day. Each tick reads
        // the setting, so turning it on or off applies within the hour.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomatically() }
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

    /// Looks for a newer release when the checkForUpdates setting allows it, and
    /// offers it in the menu without interrupting you.
    private func checkAutomatically() {
        let enabled = ConfigStore.shared.current.checkForUpdates
        Task { @MainActor in
            guard let tag = await Updater.automaticCheck(enabled: enabled) else { return }
            availableUpdate = tag
        }
    }

    /// Check for Updates… in the menu. It asks GitHub now and always answers,
    /// with an offer to install, the version you have, or the error.
    @objc private func checkForUpdatesNow() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task { @MainActor [weak self] in
            let result = await Updater.check()
            self?.report(result)
            self?.isCheckingForUpdates = false
        }
    }

    private func report(_ result: Updater.CheckResult) {
        let alert = NSAlert()
        switch result {
        case .newer(let tag):
            availableUpdate = tag
            alert.messageText = "Logos \(tag) is available"
            alert.informativeText = "You have Logos \(Updater.installedVersion). Installing builds the new version on this Mac, then restarts Logos."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Later")
        case .upToDate(let latest):
            availableUpdate = nil
            alert.messageText = "Logos \(Updater.installedVersion) is the latest version"
            alert.informativeText = "The newest release on GitHub is \(latest)."
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
        }
        // Logos has no Dock icon, so the alert would open behind the app in front.
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, case .newer = result { installUpdate() }
    }

    @objc private func toggleCheckForUpdates() {
        let enabled = !ConfigStore.shared.current.checkForUpdates
        do {
            try ConfigFile.set(enabled, at: ["checkForUpdates"])
        } catch {
            overlay.flash(error.localizedDescription)
            return
        }
        settings.refresh(\.checkForUpdates)
    }

    /// Runs the release's installer in the background. It builds the new version,
    /// replaces this app, and starts it, so this process ends when it succeeds.
    @objc private func installUpdate() {
        guard let tag = availableUpdate, updating == nil else { return }
        updating = tag
        // The menu reads its progress from this log, so a menu opened while
        // install.sh downloads must not show the last update's final stage.
        FileManager.default.createFile(atPath: Paths.updateLog.path, contents: nil)
        overlay.flash("Updating to Logos \(tag). The menu shows its progress, and Logos restarts when it's done.",
                      seconds: 6, success: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let installer = try await Updater.installer(tag: tag)
                let process = Updater.installProcess(installer: installer, tag: tag)
                let log = try FileHandle(forWritingTo: Paths.updateLog)
                process.standardOutput = log
                process.standardError = log
                // A successful install quits this copy and starts the new one, so
                // this runs only when the installer fails or this copy survived it.
                process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { @MainActor in self?.updateEnded(tag: tag, status: status) }
                }
                Updater.recordPending(.init(from: Updater.installedVersion, to: tag))
                try process.run()
            } catch {
                updateEnded(tag: tag, error: error.localizedDescription)
            }
        }
    }

    private func updateEnded(tag: String, status: Int32 = 1, error: String? = nil) {
        updating = nil
        _ = Updater.takePending()
        if let error {
            overlay.flash("Update failed: \(error)")
        } else if status != 0 {
            overlay.flash("Update failed. See \(Paths.updateLog.path)")
        } else {
            overlay.flash("Logos \(tag) is installed, but this copy is still running. Quit Logos and open it again to finish.")
        }
    }

    // MARK: Recording

    private func startRecording() {
        switch microphone.press() {
        case .ignore:
            return
        case .adopt:
            break
        case .start(let id):
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
        switch (microphone.arrived(id), result) {
        case (.abandoned, .success(let late)):
            discard(late)
        case (.abandoned, .failure):
            break
        case (.wanted, .success(let started)):
            recorder = started
        case (.unwanted, .success(let started)):
            // Released before the microphone started, which is too short to keep.
            discard(started)
        case (_, .failure(let error)):
            _ = endRecording()
            overlay.flash(error.localizedDescription)
        }
    }

    /// Gives up on a microphone that hasn't started in time. Its thread may stay
    /// stuck, so later recordings use a fresh one.
    private func microphoneTimedOut(_ id: Int) {
        guard microphone.timedOut(id) else { return }
        audioQueue = Self.makeAudioQueue()
        _ = endRecording()
        overlay.flash("The microphone didn't respond. Try again, or choose another microphone in Settings.")
        NSLog("Logos: the microphone took more than 3 seconds to start; abandoned it")
    }

    /// Every audio queue Logos uses, including the fresh one after a stall, carries
    /// the same label, so they read as one queue in a debugger or crash log.
    private nonisolated static func makeAudioQueue() -> DispatchQueue {
        DispatchQueue(label: "com.ninjudd.logos.audio")
    }

    private func discard(_ recorder: Recorder) {
        audioQueue.async { recorder.discard() }
    }

    /// Stops `recorder` on the audio queue and waits, so its file is complete.
    /// Returns false when the stop takes more than 3 seconds. Its thread may stay
    /// stuck, so later recordings use a fresh one.
    private func stop(_ recorder: Recorder) async -> Bool {
        guard await audioQueue.run(within: 3, { recorder.stop() }) else {
            audioQueue = Self.makeAudioQueue()
            NSLog("Logos: the microphone took more than 3 seconds to stop; dropped the dictation")
            return false
        }
        return true
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
        microphone.release()
        if let r = endRecording() { discard(r) }
        refreshOverlay()
    }

    private func finishRecording() {
        microphone.release()
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
            let stopped = await self?.stop(r) ?? false
            let result: Result<Pipeline.Outcome, Error>
            if stopped {
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
            } else {
                // The file may be incomplete, so it isn't worth transcribing.
                result = .failure(LogosError("The microphone didn't stop in time, so that dictation was dropped. Try again."))
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
        if let updating {
            let log = (try? String(contentsOf: Paths.updateLog, encoding: .utf8)) ?? ""
            menu.addItem(NSMenuItem(title: "Updating to \(updating): \(Updater.progress(log: log))…", action: nil, keyEquivalent: ""))
        } else if let availableUpdate {
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
        if isCheckingForUpdates {
            menu.addItem(NSMenuItem(title: "Checking for Updates…", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdatesNow)))
        }
        let automatic = item("Check for Updates Automatically", #selector(toggleCheckForUpdates))
        automatic.state = config.checkForUpdates ? .on : .off
        menu.addItem(automatic)
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
