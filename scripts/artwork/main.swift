// Draws Logos's artwork from the glyph in Sources/Logos/Glyph.swift: the app
// icon, the site's share image, and its favicon. Run scripts/artwork.sh from the
// repository root.
import AppKit
import SwiftUI

/// The app icon on macOS's 1024-point grid: an 824-point rounded square,
/// centered, with room around it for the shadow.
struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(colors: [Color(red: 0.3, green: 0.4, blue: 0.95).opacity(0.45), .clear],
                                             center: .init(x: 0.5, y: 0.2), startRadius: 0, endRadius: 520))
                )
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            GlyphShape().fill(.white).frame(width: 520 * Glyph.aspect, height: 520)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The image link previews show for logosvoice.dev.
struct ShareCard: View {
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

                HStack(spacing: 14) {
                    GlyphShape().fill(.white).frame(width: 32 * Glyph.aspect, height: 32)
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

@MainActor
func png(_ view: some View) -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let tiff = renderer.nsImage?.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("couldn't render the image")
    }
    return png
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) failed") }
}

/// Packs a 1024-pixel PNG into an .icns with every size macOS uses, at 1x and 2x.
func writeIcns(_ master: Data, to output: String) {
    let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    let largest = iconset.appending(path: "icon_512x512@2x.png")
    try! master.write(to: largest)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] where !(size == 512 && scale == 2) {
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            run("/usr/bin/sips", ["-z", "\(size * scale)", "\(size * scale)", largest.path, "--out", iconset.appending(path: name).path])
        }
    }
    run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output])
}

MainActor.assumeIsolated {
    writeIcns(png(AppIcon()), to: "Resources/AppIcon.icns")
    print("Wrote Resources/AppIcon.icns")

    try! png(ShareCard()).write(to: URL(fileURLWithPath: "web/og.png"))
    print("Wrote web/og.png")

    let tile = CGRect(x: 0, y: 0, width: 32, height: 32)
    let favicon = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#111"/>\
    \(Glyph.svgRects(in: Glyph.rect(height: 20, centeredIn: tile), fill: "#fff"))</svg>

    """
    try! favicon.write(toFile: "web/favicon.svg", atomically: true, encoding: .utf8)
    print("Wrote web/favicon.svg")
}
