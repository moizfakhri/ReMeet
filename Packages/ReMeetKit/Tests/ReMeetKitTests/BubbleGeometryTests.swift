import CoreGraphics
import Testing
@testable import ReMeetKit

struct BubbleGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)

    @Test func growsTowardCenterKeepingTopEdge() {
        // Right half: right edge stays put.
        let right = CGRect(x: 1200, y: 860, width: 230, height: 44)
        let grown = BubbleGeometry.resize(right, to: CGSize(width: 360, height: 210), on: screen)
        #expect(grown.maxX == right.maxX && grown.maxY == right.maxY)
        #expect(grown.size == CGSize(width: 360, height: 210))
        // Left half: left edge stays put.
        let left = CGRect(x: 40, y: 860, width: 230, height: 44)
        let grownLeft = BubbleGeometry.resize(left, to: CGSize(width: 360, height: 210), on: screen)
        #expect(grownLeft.minX == 40 && grownLeft.maxY == left.maxY)
        // Collapsing again returns to the original frame.
        #expect(BubbleGeometry.resize(grown, to: right.size, on: screen) == right)
    }

    @Test func collapseUsesTheAnchorChosenByThePill() {
        // Pill just left of center: grows right, and the note field's center lands right of
        // center. Collapsing with the pill's anchor must return the pill to the same spot.
        let pill = CGRect(x: 600, y: 860, width: 252, height: 48)
        let anchorRight = BubbleGeometry.anchorsRight(pill, on: screen)
        #expect(!anchorRight)
        let open = BubbleGeometry.resize(pill, to: CGSize(width: 360, height: 214), anchorRight: anchorRight)
        #expect(BubbleGeometry.anchorsRight(open, on: screen))
        #expect(BubbleGeometry.resize(open, to: pill.size, anchorRight: anchorRight) == pill)
    }

    @Test func clampBringsOffscreenFrameBack() {
        let off = CGRect(x: 1700, y: 1200, width: 230, height: 44)
        let fixed = BubbleGeometry.clamp(off, to: [screen])
        #expect(screen.insetBy(dx: 8, dy: 8).contains(fixed))
        // A frame already on screen is unchanged.
        let fine = CGRect(x: 500, y: 500, width: 230, height: 44)
        #expect(BubbleGeometry.clamp(fine, to: [screen]) == fine)
    }

    @Test func clampPicksScreenWithMostOverlap() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        let mostlyOnExternal = CGRect(x: 1480, y: 600, width: 230, height: 44)
        let fixed = BubbleGeometry.clamp(mostlyOnExternal, to: [screen, external])
        #expect(external.contains(fixed))
    }

    @Test func defaultIsTopRight() {
        let frame = BubbleGeometry.defaultFrame(size: CGSize(width: 230, height: 44), visibleFrame: screen)
        #expect(frame.maxX == screen.maxX - 16 && frame.maxY == screen.maxY - 16)
    }
}
