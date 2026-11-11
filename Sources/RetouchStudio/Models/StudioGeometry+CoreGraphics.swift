import CoreGraphics
import StudioCore

// The only place the portable geometry meets CoreGraphics. `CGFloat` is
// 64-bit on every supported architecture, so these conversions are exact and
// do not standardize, clamp or otherwise reinterpret the value.

extension StudioPoint {
    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

extension StudioSize {
    init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

extension StudioRect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y),
                  width: Double(rect.size.width), height: Double(rect.size.height))
    }

    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y),
               width: CGFloat(width), height: CGFloat(height))
    }
}
