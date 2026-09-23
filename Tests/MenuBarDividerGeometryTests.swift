//
//  MenuBarDividerGeometryTests.swift
//  Ice
//

import CoreGraphics
import Testing

struct MenuBarDividerGeometryTests {
    @Test func narrowerDisplayLimitsTheSeparatorOnEveryDisplay() {
        #expect(MenuBarDividerGeometry.maximumLength(availableWidths: [2880, 1440]) == 656)
        #expect(MenuBarDividerGeometry.maximumLength(availableWidths: [1440, 2880]) == 656)
    }

    @Test func notchAreaCanBeTheLimitingWidth() {
        #expect(MenuBarDividerGeometry.maximumLength(availableWidths: [2880, 620]) == 246)
    }

    @Test func supplementalDividersCoverTheWiderDisplayWithoutOversizingOneItem() throws {
        for widths: [CGFloat] in [[2880, 1440], [2880, 620], [1440]] {
            let length = try #require(MenuBarDividerGeometry.maximumLength(availableWidths: widths))
            let count = MenuBarDividerGeometry.supplementalCount(availableWidths: widths)
            #expect(CGFloat(count + 1) * length >= widths.max() ?? 0)
            #expect(length < (widths.min() ?? 0) / 2)
        }
        #expect(MenuBarDividerGeometry.supplementalCount(availableWidths: [2880, 1440]) == 4)
        #expect(MenuBarDividerGeometry.supplementalCount(availableWidths: [.nan, 0]) == 0)
    }

    @Test func invalidDisplayMeasurementsDoNotBecomeLengths() {
        #expect(MenuBarDividerGeometry.maximumLength(availableWidths: []) == nil)
        #expect(MenuBarDividerGeometry.maximumLength(availableWidths: [0, -10, .infinity, .nan]) == nil)
        #expect(MenuBarDividerGeometry.maximumLength(availableWidths: [0, .nan, 1440]) == 656)
    }

    @Test(arguments: [CGFloat(2.5), 64, 127.5, 200, 1440.5])
    func fractionalAndNarrowWidthsRemainBelowTheCutoff(width: CGFloat) throws {
        let length = try #require(MenuBarDividerGeometry.maximumLength(availableWidths: [width]))
        #expect(length > 0)
        #expect(length < width / 2)
    }
}
