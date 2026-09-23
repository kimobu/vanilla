//
//  CaptureGeometryTests.swift
//  Ice
//

import CoreGraphics
import Testing

struct CaptureGeometryTests {
    @Test func locatesRetractedMenuBarInsteadOfInactiveDesktopBar() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let desktop = CGRect(x: 0, y: 0, width: 1920, height: 30)
        let retracted = CGRect(x: 0, y: -62, width: 1920, height: 30)
        let control = CGRect(x: 1648, y: -59, width: 35, height: 24)
        #expect(CaptureGeometry.menuBarRow(display: display, candidates: [desktop, retracted], anchors: [control]) == retracted)
    }

    @Test func menuBarRowsRespectDisplayOriginAndWidth() {
        let display = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let row = CGRect(x: -1920, y: -1142, width: 1920, height: 30)
        let other = CGRect(x: 0, y: -1142, width: 2560, height: 30)
        let control = CGRect(x: -100, y: -1139, width: 35, height: 24)
        #expect(CaptureGeometry.menuBarRow(display: display, candidates: [other, row], anchors: [control]) == row)
    }

    @Test func unavailableOrAmbiguousAnchorsDoNotInventARow() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let row = CGRect(x: 0, y: -62, width: 1920, height: 30)
        let control = CGRect(x: 1648, y: -59, width: 35, height: 24)
        #expect(CaptureGeometry.menuBarRow(display: display, candidates: [row], anchors: [.null, .zero]) == nil)
        #expect(CaptureGeometry.menuBarRow(display: display, candidates: [row, row], anchors: [control]) == nil)
    }

    @Test func hostMatchingUsesBothAxesAndButtonInsets() {
        let host = CGRect(x: -3453, y: -62, width: 38, height: 30)
        let button = CGRect(x: -3445, y: -58, width: 22, height: 22)
        #expect(CaptureGeometry.matchesHostWindow(host, item: button))
        #expect(!CaptureGeometry.matchesHostWindow(host.offsetBy(dx: 38, dy: 0), item: button))
        #expect(!CaptureGeometry.matchesHostWindow(host.offsetBy(dx: 0, dy: 62), item: button))
        #expect(!CaptureGeometry.matchesHostWindow(host, item: .null))
        #expect(!CaptureGeometry.matchesHostWindow(host, item: host.insetBy(dx: -8, dy: 0)))
    }

    @Test func cropsRetractedHostToItsAXButtonAtRetinaScale() {
        #expect(CaptureGeometry.pixelRect(
            for: CGRect(x: -3445, y: -58, width: 22, height: 22),
            windowFrame: CGRect(x: -3453, y: -62, width: 38, height: 30),
            imageSize: CGSize(width: 76, height: 60)
        ) == CGRect(x: 16, y: 8, width: 44, height: 44))
    }

    @Test func convertsNegativeDisplayOriginToBackingPixels() {
        let result = CaptureGeometry.pixelRect(
            for: CGRect(x: -1800, y: 100, width: 50, height: 20),
            windowFrame: CGRect(x: -1920, y: 80, width: 300, height: 100),
            imageSize: CGSize(width: 600, height: 200)
        )
        #expect(result == CGRect(x: 240, y: 40, width: 100, height: 40))
    }

    @Test func clipsToTheCapturedWindow() {
        let result = CaptureGeometry.pixelRect(
            for: CGRect(x: 90, y: 20, width: 40, height: 30),
            windowFrame: CGRect(x: 100, y: 30, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        #expect(result == CGRect(x: 0, y: 0, width: 60, height: 40))
    }

    @Test func usesActualImageDimensionsAtFractionalScale() {
        let frame = CGRect(x: 200, y: -900, width: 41, height: 23)
        let result = CaptureGeometry.pixelRect(for: frame, windowFrame: frame, imageSize: CGSize(width: 62, height: 35))
        #expect(result == CGRect(x: 0, y: 0, width: 62, height: 35))
    }

    @Test func rejectsEmptyAndNonOverlappingRegions() {
        let frame = CGRect(x: 100, y: 100, width: 10, height: 10)
        #expect(CaptureGeometry.pixelRect(for: .zero, windowFrame: frame, imageSize: CGSize(width: 20, height: 20)) == nil)
        #expect(CaptureGeometry.pixelRect(for: frame, windowFrame: frame, imageSize: .zero) == nil)
    }
}
