// Draws the image link previews show for logosvoice.dev.
// Run from the repository root: swift scripts/og-image.swift web/og.png
import AppKit
import SwiftUI

struct Card: View {
    // Bar heights for the recording pill, low pitches on the left, like a voice.
    let levels: [CGFloat] = [0.25, 0.45, 0.8, 1.0, 0.85, 0.95, 0.7, 0.75, 0.55, 0.6, 0.4, 0.45, 0.3, 0.35, 0.22, 0.28, 0.18, 0.2, 0.12, 0.15]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.25, green: 0.33, blue: 0.75).opacity(0.35), .clear],
                           center: .init(x: 0.85, y: 0.1), startRadius: 0, endRadius: 520)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(levels.indices, id: \.self) { i in
                        Capsule().fill(.white).frame(width: 7, height: 8 + levels[i] * 46)
                    }
                }
                .padding(.horizontal, 30)
                .frame(height: 84)
                .background(Capsule().fill(Color(white: 0.07)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)

                Spacer()

                Text("Dictation for your Mac,\non your terms.")
                    .font(.system(size: 76, weight: .bold))
                    .tracking(-2)
                    .lineSpacing(-4)
                    .foregroundStyle(.white)
                Text("Hold Option, speak, and let go. Your prompt, your models, no server.")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.top, 22)

                Spacer().frame(height: 44)

                HStack {
                    Text("Logos").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("logosvoice.dev")
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 0.56, green: 0.65, blue: 1.0))
                }
            }
            .padding(72)
        }
        .frame(width: 1200, height: 630)
        .environment(\.colorScheme, .dark)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Card())
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("couldn't render the image")
    }
    let output = CommandLine.arguments.dropFirst().first ?? "web/og.png"
    try! png.write(to: URL(fileURLWithPath: output))
    print("Wrote \(output)")
}
