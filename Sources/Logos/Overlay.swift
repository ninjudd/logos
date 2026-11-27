import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recording
        case processing(String)
        case message(String)
        case confirmation(String)
        /// A dictation with nowhere to paste, shown so it can be copied.
        case result(String)
    }

    @Published var phase: Phase = .recording
    /// One bar per frequency band, low to high.
    @Published var levels: [Double] = Array(repeating: 0, count: Spectrum.bandCount)
    /// Height of the result card's text area, measured by the controller.
    var resultTextHeight: CGFloat = 0
    var copy: () -> Void = {}
    var close: () -> Void = {}

    /// Per-frame decay at 30 frames a second: a bar falls to a tenth of its height
    /// in about half a second once its frequency goes quiet.
    private let decay = 0.86

    /// Each bar jumps up to new sound at once and fades when the sound stops.
    func update(_ bands: [Double]) {
        guard bands.count == levels.count else { return }
        levels = zip(levels, bands).map { old, new in max(new, old * decay) }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        if case .result(let text) = model.phase {
            ResultCard(text: text, textHeight: model.resultTextHeight, copy: model.copy, close: model.close)
        } else {
            pill.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording:
                HStack(spacing: 3) {
                    ForEach(model.levels.indices, id: \.self) { i in
                        Capsule()
                            .fill(.white)
                            .frame(width: 3, height: 4 + model.levels[i] * 18)
                    }
                }
                .animation(.linear(duration: 1.0 / 30), value: model.levels)
            case .processing(let label):
                ProgressView().controlSize(.small).tint(.white)
                Text(label)
            case .message(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(text).lineLimit(2)
            case .confirmation(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text)
            case .result:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(minWidth: 90, minHeight: 34)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
    }
}

private struct ResultCard: View {
    let text: String
    let textHeight: CGFloat
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: OverlayController.resultIconGap) {
                Text("No text field to paste into")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                iconButton("xmark", label: "Close", action: close)
            }
            HStack(alignment: .top, spacing: OverlayController.resultIconGap) {
                ScrollView {
                    Text(text)
                        .font(.system(size: OverlayController.resultFontSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: textHeight)
                iconButton("square.on.square", label: "Copy", action: copy)
            }
        }
        .foregroundStyle(.white)
        .padding(OverlayController.resultPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.18)))
        .environment(\.colorScheme, .dark)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: OverlayController.resultIconSize, height: OverlayController.resultIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Lets the first click on the card's buttons work while another app is active.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small pill near the bottom of the screen that never takes focus. It ignores
/// the mouse, except while it shows a result card to copy from.
final class OverlayController {
    static let resultFontSize: CGFloat = 13
    static let resultPadding: CGFloat = 14
    static let resultIconSize: CGFloat = 20
    static let resultIconGap: CGFloat = 8
    private static let pillSize = NSSize(width: 460, height: 60)
    private static let resultWidth: CGFloat = 440
    private static let resultMaxTextHeight: CGFloat = 160
    /// The card's header row and the gap below it.
    private static let resultChrome: CGFloat = 10 + resultIconSize

    let model = OverlayModel()
    private let panel: NSPanel
    private var messageToken = 0

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.pillSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = ClickThroughHostingView(rootView: OverlayView(model: model))
    }

    /// A message or result card is up, which other updates shouldn't replace.
    var isHoldingContent: Bool {
        guard panel.isVisible else { return false }
        switch model.phase {
        case .message, .confirmation, .result: return true
        case .recording, .processing: return false
        }
    }

    var isShowingResult: Bool {
        if panel.isVisible, case .result = model.phase { return true }
        return false
    }

    func show(_ phase: OverlayModel.Phase) {
        messageToken += 1
        if phase == .recording && !(panel.isVisible && model.phase == .recording) {
            model.levels = model.levels.map { _ in 0 }
        }
        let wasResult = isShowingResult
        model.phase = phase
        panel.ignoresMouseEvents = true
        if !panel.isVisible || wasResult {
            panel.setContentSize(Self.pillSize)
            position()
            panel.orderFrontRegardless()
        }
    }

    /// Shows text that had nowhere to be pasted, with buttons to copy or close it.
    /// It stays until one is pressed, Esc is pressed, or a new dictation starts.
    func showResult(_ text: String, copy: @escaping () -> Void) {
        messageToken += 1
        model.resultTextHeight = Self.textHeight(text)
        model.copy = copy
        model.close = { [weak self] in self?.hide() }
        model.phase = .result(text)
        panel.setContentSize(NSSize(width: Self.resultWidth,
                                    height: model.resultTextHeight + Self.resultChrome + 2 * Self.resultPadding))
        position()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    /// Shows a message, then hides it after a few seconds unless something replaced it.
    func flash(_ text: String, seconds: Double = 4, success: Bool = false) {
        show(success ? .confirmation(text) : .message(text))
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    func hide() {
        messageToken += 1
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    private static func textHeight(_ text: String) -> CGFloat {
        // The copy button sits beside the text.
        let width = resultWidth - 2 * resultPadding - resultIconGap - resultIconSize
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: resultFontSize)])
        return min(max(ceil(bounds.height) + 2, 18), resultMaxTextHeight)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}
