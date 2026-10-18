import AppKit
import SwiftUI
import XCTest
@testable import AndroidWebcamAppRuntime

@MainActor
final class GlassRenderingTests: XCTestCase {
    func testNamedPreviewsRenderTheSameControlsUsedByTheApp() {
        XCTAssertGreaterThan(NSHostingView(rootView: ConnectedCameraControlsPreview.previews).fittingSize.height, 0)
        XCTAssertGreaterThan(NSHostingView(rootView: DisconnectedCameraControlsPreview.previews).fittingSize.height, 0)
        let canvas = NSHostingView(rootView: DisconnectedCanvasPreview.previews)
        XCTAssertEqual(canvas.fittingSize.width, 520)
        XCTAssertEqual(canvas.fittingSize.height, 380)
    }

    func testGlassAndLegacyControlsRenderEverySupportedAppearance() {
        for rendering in [GlassRendering.native, .standard, .legacy] {
            for prominent in [false, true] {
                let controls = GlassControlGroup {
                    VStack {
                        Text("Static surface").wamcGlassSurface()
                        Text("Interactive surface").wamcGlassSurface(interactive: true)
                        Button("Action", action: {}).wamcActionStyle(prominent: prominent)
                    }
                    .padding()
                }
                .environment(\.wamcGlassRendering, rendering)
                let host = NSHostingView(rootView: controls)
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
        }
    }
}
