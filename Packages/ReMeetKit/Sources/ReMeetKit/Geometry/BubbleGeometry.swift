import CoreGraphics

/// Placement of the floating note bubble. Rects are in AppKit screen coordinates
/// (origin bottom-left, y up).
public enum BubbleGeometry {
    /// Resizes `frame` to `size` keeping its top edge fixed, and its right edge fixed when
    /// the bubble sits in the right half of `screen` (so it grows toward the screen center).
    public static func resize(_ frame: CGRect, to size: CGSize, on screen: CGRect) -> CGRect {
        resize(frame, to: size, anchorRight: anchorsRight(frame, on: screen))
    }

    /// Resizes keeping the top edge and the given side fixed. The bubble decides the side
    /// once, from the pill, and reuses it to collapse: the note field's own center can sit
    /// on the other half of the screen, which would make the pill come back somewhere else.
    public static func resize(_ frame: CGRect, to size: CGSize, anchorRight: Bool) -> CGRect {
        let x = anchorRight ? frame.maxX - size.width : frame.minX
        return CGRect(x: x, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// True when the bubble sits in the right half of `screen` and so grows leftward.
    public static func anchorsRight(_ frame: CGRect, on screen: CGRect) -> Bool {
        frame.midX > screen.midX
    }

    /// Moves `frame` fully onto the screen whose visible area it overlaps most (or the
    /// first screen), with a margin. Used when restoring a remembered position after the
    /// display layout changed.
    public static func clamp(_ frame: CGRect, to visibleFrames: [CGRect], margin: CGFloat = 8) -> CGRect {
        guard let first = visibleFrames.first else { return frame }
        let screen = visibleFrames.max { overlap($0, frame) < overlap($1, frame) }
            .flatMap { overlap($0, frame) > 0 ? $0 : nil } ?? first
        let bounds = screen.insetBy(dx: margin, dy: margin)
        var result = frame
        result.size.width = min(frame.width, bounds.width)
        result.size.height = min(frame.height, bounds.height)
        result.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    /// Default spot: top-right of the main screen's visible area, below the menu bar.
    public static func defaultFrame(size: CGSize, visibleFrame: CGRect, margin: CGFloat = 16) -> CGRect {
        CGRect(x: visibleFrame.maxX - size.width - margin, y: visibleFrame.maxY - size.height - margin,
               width: size.width, height: size.height)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
