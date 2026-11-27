// Draws Logos's app icon and packs it into Resources/AppIcon.icns.
// Run from the repository root: swift scripts/app-icon.swift
import AppKit
import SwiftUI

/// The icon on macOS's 1024-point grid: an 824-point rounded square, centered,
/// with room around it for the shadow.
struct Icon: View {
    let levels: [CGFloat] = [0.32, 0.62, 1.0, 0.78, 0.9, 0.5, 0.28]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(colors: [Color(red: 0.3, green: 0.4, blue: 0.95).opacity(0.45), .clear],
                                             center: .init(x: 0.5, y: 0.2), startRadius: 0, endRadius: 520))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)

            HStack(spacing: 34) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().fill(.white).frame(width: 50, height: 90 + levels[i] * 360)
                }
            }
        }
        .frame(width: 1024, height: 1024)
    }
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

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let tiff = renderer.nsImage?.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("couldn't render the icon")
    }
    let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    let master = iconset.appending(path: "icon_512x512@2x.png")
    try! png.write(to: master)

    // Every size an .icns holds, each at 1x and 2x.
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] where !(size == 512 && scale == 2) {
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            let pixels = size * scale
            run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appending(path: name).path])
        }
    }
    let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
    run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output])
    print("Wrote \(output)")
}
