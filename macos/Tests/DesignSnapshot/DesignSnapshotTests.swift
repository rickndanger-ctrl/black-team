import XCTest
import SwiftUI
import AppKit
@testable import BlackTeamUI

// Renders the design gallery to PNGs so the look can be checked without a person at the Mac.
// Not part of Package.swift: dev/design-snapshot.sh adds it to a scratch copy on the mini.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    func testRenderGallery() throws {
        Fonts.register()
        XCTAssertTrue(Fonts.isAvailable, "bundled fonts did not register")
        for theme in [ThemeSetting.covert, .light, .ghost] {
            let view = DesignGallery(forcing: theme, flat: true).frame(width: 920)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                return XCTFail("render failed for \(theme)")
            }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bt-gallery-\(theme.rawValue).png")
            try png.write(to: url)
            print("SNAPSHOT \(url.path)")
        }
    }
}
