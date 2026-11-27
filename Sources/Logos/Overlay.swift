import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recording
        case processing(String)
        case message(String)
    }

    @Published var phase: Phase = .recording
    /// One bar per frequency band, low to high.
    @Published var levels: [Double] = Array(repeating: 0, count: Spectrum.bandCount)

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
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(minWidth: 90, minHeight: 34)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small pill near the bottom of the screen that never takes focus or clicks.
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var messageToken = 0
    private let size = NSSize(width: 460, height: 60)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    var isShowingMessage: Bool {
        if panel.isVisible, case .message = model.phase { return true }
        return false
    }

    func show(_ phase: OverlayModel.Phase) {
        messageToken += 1
        if phase == .recording && !(panel.isVisible && model.phase == .recording) {
            model.levels = model.levels.map { _ in 0 }
        }
        model.phase = phase
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
    }

    /// Shows a message, then hides it after a few seconds unless something replaced it.
    func flash(_ text: String, seconds: Double = 4) {
        show(.message(text))
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    func hide() {
        messageToken += 1
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}
