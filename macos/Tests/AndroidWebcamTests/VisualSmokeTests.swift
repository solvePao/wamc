import AppKit
import SwiftUI
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class VisualSmokeTests: XCTestCase {
    func testIdleWindowRendersAtItsSupportedSize() throws {
        let model = AppModel(preferences: isolatedDefaults(), startServices: false)
        let host = NSHostingView(rootView: ContentView(model: model)
            .environment(\.wamcGlassRendering, .legacy)
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 1040, height: 680)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1040)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 680)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/test-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.write(to: directory.appendingPathComponent("idle-window.png"))
    }
}
