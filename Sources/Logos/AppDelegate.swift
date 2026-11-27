import AppKit
import AVFoundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = OverlayController()
    private let hotkey = HotkeyMonitor()
    private var statusItem: NSStatusItem!

    private var recorder: Recorder?
    private var pressedAt = Date()
    private var targetApp = ""
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
        ConfigStore.shared.ensureFiles()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

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
        guard recorder == nil else { return }
        do {
            recorder = try Recorder.start()
        } catch {
            overlay.flash(error.localizedDescription)
            return
        }
        pressedAt = Date()
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = frontmost?.localizedName ?? "an unknown app"
        if let pid = frontmost?.processIdentifier { FocusedField.prepare(pid: pid) }
        overlayShown = false
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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
        endRecording()?.discard()
        refreshOverlay()
    }

    private func finishRecording() {
        guard let r = endRecording() else { return }
        let config = ConfigStore.shared.current
        guard Date().timeIntervalSince(pressedAt) >= config.minHoldSeconds else {
            r.discard()
            refreshOverlay()
            return
        }
        r.stop()

        let audio = r.url
        let prompt = ConfigStore.shared.prompt
        let app = targetApp
        let previous = chain
        pending += 1
        stageLabel = "Transcribing…"
        refreshOverlay()

        chain = Task { @MainActor [weak self] in
            let result: Result<Pipeline.Outcome, Error>
            do {
                result = .success(try await Pipeline.run(audio: audio, config: config, prompt: prompt, app: app) { stage in
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
        let key = switch config.hotkey {
        case .option: "Option"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        }
        menu.addItem(NSMenuItem(title: "Logos \(Updater.installedVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hold \(key) to dictate", action: nil, keyEquivalent: ""))
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
        menu.addItem(item("Edit Prompt…", #selector(editPrompt)))
        menu.addItem(item("Edit Config…", #selector(editConfig)))
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

    @objc private func editPrompt() { NSWorkspace.shared.open(Paths.prompt) }
    @objc private func editConfig() { NSWorkspace.shared.open(Paths.config) }

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
        let image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: "Logos")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}
