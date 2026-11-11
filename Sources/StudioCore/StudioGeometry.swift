import Foundation

/// A point in a declared `StudioCoordinateSpace`. `Double` keeps the value
/// identical on every platform; the macOS app converts to its own drawing
/// types at the boundary.
///
/// A bare point carries no origin or unit. The space is supplied by the field
/// that stores it, exactly as the current project format does.
public struct StudioPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = StudioPoint(x: 0, y: 0)

    public var isFinite: Bool { x.isFinite && y.isFinite }

    public func distance(to other: StudioPoint) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Width and height in one unit. Zero is valid — an empty crop or an empty
/// mask box is a real state. Negative extents are representable but invalid:
/// nothing clamps them, so a draft or a legacy value round-trips unchanged.
public struct StudioSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = StudioSize(width: 0, height: 0)

    public var isFinite: Bool { width.isFinite && height.isFinite }

    public var isValid: Bool { isFinite && width >= 0 && height >= 0 }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// An axis-aligned rectangle whose `x`/`y` name the min corner in its space,
/// matching the canonical JSON keys. Extents are not standardized on
/// construction or on decode.
public struct StudioRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: StudioPoint, size: StudioSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = StudioRect(x: 0, y: 0, width: 0, height: 0)
    public static let unit = StudioRect(x: 0, y: 0, width: 1, height: 1)

    public var origin: StudioPoint {
        get { StudioPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    public var size: StudioSize {
        get { StudioSize(width: width, height: height) }
        set { width = newValue.width; height = newValue.height }
    }

    public var minX: Double { x }
    public var midX: Double { x + width / 2 }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var midY: Double { y + height / 2 }
    public var maxY: Double { y + height }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    public var isValid: Bool { isFinite && width >= 0 && height >= 0 }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Half-open: the min edges belong to the rectangle, the max edges do not.
    public func contains(_ point: StudioPoint) -> Bool {
        guard isValid, point.isFinite else { return false }
        return point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// Flips negative extents so the origin becomes the min corner. Explicit:
    /// no initializer, decoder or conversion applies this on its own.
    public func standardized() -> StudioRect {
        var result = self
        if result.width < 0 {
            result.x += result.width
            result.width = -result.width
        }
        if result.height < 0 {
            result.y += result.height
            result.height = -result.height
        }
        return result
    }
}

/// Which origin and unit a geometry value uses. The document space is
/// `sourceNormalizedTopLeft`, whose raw value is the canonical
/// `source_normalized`. The other cases exist because the current app also
/// stores analysis pins bottom-left and works with pixel/mask frames.
public enum StudioCoordinateSpace: String, CaseIterable, Codable, Sendable {
    case sourceNormalizedTopLeft = "source_normalized"
    case sourceNormalizedBottomLeft = "source_normalized_bottom_left"
    case sourcePixelTopLeft = "source_pixel"
    case sourcePixelBottomLeft = "source_pixel_bottom_left"

    public var isNormalized: Bool {
        switch self {
        case .sourceNormalizedTopLeft, .sourceNormalizedBottomLeft: return true
        case .sourcePixelTopLeft, .sourcePixelBottomLeft: return false
        }
    }

    public var hasTopLeftOrigin: Bool {
        switch self {
        case .sourceNormalizedTopLeft, .sourcePixelTopLeft: return true
        case .sourceNormalizedBottomLeft, .sourcePixelBottomLeft: return false
        }
    }

    public func sameUnit(as other: StudioCoordinateSpace) -> Bool {
        isNormalized == other.isNormalized
    }

    /// Converts a point only within one unit. A cross-unit request returns
    /// `nil` rather than guessing a frame size. Non-finite input returns `nil`.
    /// `frameHeight` is read only for pixel spaces.
    public func convert(_ point: StudioPoint, to target: StudioCoordinateSpace,
                        frameHeight: Double = 1) -> StudioPoint? {
        guard sameUnit(as: target) else { return nil }
        guard hasTopLeftOrigin != target.hasTopLeftOrigin else { return point }
        guard point.isFinite, let height = frameExtent(frameHeight) else { return nil }
        return StudioPoint(x: point.x, y: height - point.y)
    }

    /// Converts a rectangle whose `y` is its min edge in this space. A
    /// negative-extent rectangle is refused; call `standardized()` first if
    /// that is what the caller means.
    public func convert(_ rect: StudioRect, to target: StudioCoordinateSpace,
                        frameHeight: Double = 1) -> StudioRect? {
        guard sameUnit(as: target) else { return nil }
        guard hasTopLeftOrigin != target.hasTopLeftOrigin else { return rect }
        guard rect.isValid, let height = frameExtent(frameHeight) else { return nil }
        return StudioRect(x: rect.x, y: height - rect.maxY,
                          width: rect.width, height: rect.height)
    }

    private func frameExtent(_ frameHeight: Double) -> Double? {
        switch self {
        case .sourceNormalizedTopLeft, .sourceNormalizedBottomLeft:
            return 1
        case .sourcePixelTopLeft, .sourcePixelBottomLeft:
            guard frameHeight.isFinite, frameHeight > 0 else { return nil }
            return frameHeight
        }
    }
}
