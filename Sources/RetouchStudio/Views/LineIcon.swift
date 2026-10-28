import SwiftUI

/// The app's own icon set.
///
/// The reference design draws every tool mark with the same thin, round-capped
/// stroke. SF Symbols cannot match it: their weights are tuned to sit beside
/// text, each symbol has its own optical size, and mixing eight of them makes a
/// toolbar look like a pile of clip-art rather than one tool family. These are
/// drawn on a 24-unit grid with one stroke rule, so every mark carries the same
/// line weight at any size.
///
/// Call sites keep the names they had, and an unknown name falls back to the
/// system symbol, so a glyph that has not been drawn yet still shows up.
struct Icon: View {
    let name: String
    /// Width of the square the glyph is drawn in.
    var size: CGFloat = 15
    /// Slightly heavier line, used where the old code asked for a semibold
    /// symbol — the active tool, a pressed button.
    var emphasised: Bool = false

    var body: some View {
        if let glyph = Self.glyphs[name] {
            let grid = Grid(u: size / 24)
            let stroke = glyph.stroke(grid)
            let fill = glyph.fill?(grid)
            let weight = min(2.2, max(0.9, size * (emphasised ? 0.095 : 0.075)))
            // Drawn in a canvas with the foreground shading: a plain
            // `Color.primary` path would ignore whatever colour the caller
            // asked for and stay label-white on the light active pill.
            Canvas { ctx, _ in
                if let fill { ctx.fill(fill, with: .foreground) }
                ctx.stroke(stroke, with: .foreground, style: StrokeStyle(
                    lineWidth: weight, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
            // A drawn path carries no name, so the mark would disappear from
            // VoiceOver, where a system symbol at least announced itself.
            .accessibilityLabel(Text(name))
        } else {
            Image(systemName: name)
                .font(.system(size: size * 0.8, weight: emphasised ? .semibold : .regular))
        }
    }

    /// A glyph is one stroked path plus an optional filled one for the parts
    /// that are solid ink rather than line.
    private struct Glyph {
        var stroke: (Grid) -> Path
        var fill: ((Grid) -> Path)? = nil
    }

    private static let glyphs: [String: Glyph] = [
        // MARK: Tools

        "sparkles": Glyph(stroke: { g in
            Pen(g).star(9.5, 10, 6.5).star(17.6, 17, 3.4).path
        }),

        "bandage": Glyph(stroke: { g in
            var p = Path()
            p.addRoundedRect(in: g.r(4, 8.6, 16, 6.8),
                             cornerSize: CGSize(width: 3.4 * g.u, height: 3.4 * g.u))
            return p.applying(g.rotated(by: -.pi / 4))
        }, fill: { g in
            Pen(g).dot(10.4, 10.4).dot(13.6, 13.6).dot(13.6, 10.4).dot(10.4, 13.6).path
        }),

        // The reshape tool: a face with the cheeks pulled outward, so the mark
        // says "this one moves the shape" rather than "this one is a face".
        "face.smiling": Glyph(stroke: { g in
            Pen(g).oval(5.4, 5.4, 13.2, 13.2)
                .move(9.2, 13.6).quad(12, 16.2, 14.8, 13.6)
                .move(1.2, 12).line(4.2, 12)
                .move(2.8, 10.4).line(1.2, 12).line(2.8, 13.6)
                .move(22.8, 12).line(19.8, 12)
                .move(21.2, 10.4).line(22.8, 12).line(21.2, 13.6).path
        }, fill: { g in Pen(g).dot(9.6, 10.6, 0.8).dot(14.4, 10.6, 0.8).path }),

        "eye": Glyph(stroke: { g in
            Pen(g).move(2, 12).quad(12, 3.6, 22, 12).quad(12, 20.4, 2, 12).close()
                .oval(9, 9, 6, 6).path
        }, fill: { g in Pen(g).dot(12, 12, 1.5).path }),

        "paintpalette": Glyph(stroke: { g in
            Pen(g).oval(2.6, 4.4, 18.8, 15.2)
                .oval(5.6, 13.4, 4, 4).path
        }, fill: { g in
            Pen(g).dot(8, 9, 1.15).dot(12.6, 7.4, 1.15).dot(16.8, 9.6, 1.15)
                .dot(16.4, 14.2, 1.15).path
        }),

        "camera.filters": Glyph(stroke: { g in
            Pen(g).oval(3.5, 3.5, 17, 17).path
        }, fill: { g in
            Pen(g).move(12, 3.5).arc(12, 12, 8.5, -90, 90).close().path
        }),

        "film": Glyph(stroke: { g in
            Pen(g).roundRect(2.6, 5.4, 18.8, 13.2, 2.2)
                .move(6.4, 5.4).line(6.4, 18.6)
                .move(17.6, 5.4).line(17.6, 18.6).path
        }, fill: { g in
            Pen(g).dot(4.5, 8.2, 0.85).dot(4.5, 12, 0.85).dot(4.5, 15.8, 0.85)
                .dot(19.5, 8.2, 0.85).dot(19.5, 12, 0.85).dot(19.5, 15.8, 0.85).path
        }),

        "crop": Glyph(stroke: { g in
            Pen(g).move(6.6, 2.4).line(6.6, 17.4).line(21.6, 17.4)
                .move(2.4, 6.6).line(17.4, 6.6).line(17.4, 21.6).path
        }),

        // MARK: Generative actions

        "wand.and.stars": Glyph(stroke: { g in
            Pen(g).move(3, 21).line(13.6, 10.4)
                .star(17.4, 6.8, 3.9).star(8.4, 5.4, 2.3).path
        }, fill: { g in Pen(g).dot(21.4, 12.6, 0.95).path }),

        "wand.and.rays": Glyph(stroke: { g in
            Pen(g).move(3.4, 20.6).line(13.8, 10.2)
                .move(15.6, 12).line(19.4, 15.8)
                .move(17.4, 8.6).line(21.6, 9.4)
                .move(12, 6.6).line(12.8, 2.4).path
        }, fill: { g in Pen(g).dot(20.8, 13.4, 0.95).dot(9.4, 4.4, 0.95).path }),

        "mouth": Glyph(stroke: { g in
            Pen(g).move(3, 12.4)
                .quad(6.4, 8.6, 9.4, 10.6).quad(10.7, 11.4, 12, 10.6)
                .quad(14.6, 8.6, 21, 12.4)
                .quad(16.6, 17.8, 12, 17.8).quad(7.4, 17.8, 3, 12.4).close()
                .move(3, 12.4).line(21, 12.4).path
        }),

        // The pan hint: a body with an arrow on every side, which is what the
        // canvas actually does when it is dragged.
        "hand.draw": Glyph(stroke: { g in
            Pen(g).move(12, 3.4).line(12, 20.6)
                .move(8.6, 6.8).line(12, 3.4).line(15.4, 6.8)
                .move(8.6, 17.2).line(12, 20.6).line(15.4, 17.2)
                .move(3.4, 12).line(20.6, 12)
                .move(6.8, 8.6).line(3.4, 12).line(6.8, 15.4)
                .move(17.2, 8.6).line(20.6, 12).line(17.2, 15.4).path
        }),

        // MARK: Revert, history and export

        "arrow.uturn.backward": Glyph(stroke: { g in
            Pen(g).move(8, 5).line(3.4, 9.6).line(8, 14.2)
                .move(3.4, 9.6).line(14.4, 9.6)
                .curve(19.4, 9.6, 19.4, 18.8, 14.4, 18.8).line(7.6, 18.8).path
        }),

        "arrow.uturn.forward": Glyph(stroke: { g in
            Pen(g).move(16, 5).line(20.6, 9.6).line(16, 14.2)
                .move(20.6, 9.6).line(9.6, 9.6)
                .curve(4.6, 9.6, 4.6, 18.8, 9.6, 18.8).line(16.4, 18.8).path
        }),

        // A ring that opens at the top-left and an arrowhead pointing the other
        // way, so this reads as "start over" and never as the undo hook, which
        // turns back on itself.
        "arrow.counterclockwise": Glyph(stroke: { g in
            Pen(g).arc(12, 12, 8, -85, 210)
                .move(12.6, 2.4).line(9, 4.4).line(12.6, 6.4).path
        }),

        "arrow.down.to.line.compact": Glyph(stroke: { g in
            Pen(g).move(12, 3.4).line(12, 14)
                .move(7.6, 9.6).line(12, 14).line(16.4, 9.6)
                .move(4, 17).line(4, 20.6).line(20, 20.6).line(20, 17).path
        }),

        // MARK: Canvas controls

        "arrow.up.left.and.arrow.down.right": Glyph(stroke: { g in
            Pen(g).move(3, 8.6).line(3, 3).line(8.6, 3)
                .move(15.4, 3).line(21, 3).line(21, 8.6)
                .move(21, 15.4).line(21, 21).line(15.4, 21)
                .move(8.6, 21).line(3, 21).line(3, 15.4).path
        }),

        "minus.magnifyingglass": Glyph(stroke: { g in
            Pen(g).oval(4, 4, 13, 13).move(15.4, 15.4).line(21, 21)
                .move(7.6, 10.5).line(13.4, 10.5).path
        }),

        "plus.magnifyingglass": Glyph(stroke: { g in
            Pen(g).oval(4, 4, 13, 13).move(15.4, 15.4).line(21, 21)
                .move(7.6, 10.5).line(13.4, 10.5)
                .move(10.5, 7.6).line(10.5, 13.4).path
        }),

        "rectangle.split.2x1": Glyph(stroke: { g in
            Pen(g).roundRect(3, 5, 18, 14, 2.2).move(12, 5).line(12, 19).path
        }),

        "face.dashed": Glyph(stroke: { g in
            Pen(g).roundRect(3.4, 3.4, 17.2, 17.2, 4.4)
                .move(8.4, 14.4).quad(12, 17.6, 15.6, 14.4).path
        }, fill: { g in Pen(g).dot(9.4, 10.4, 1.05).dot(14.6, 10.4, 1.05).path }),

        "arrow.left.and.right": Glyph(stroke: { g in
            Pen(g).move(3, 12).line(21, 12)
                .move(7, 8).line(3, 12).line(7, 16)
                .move(17, 8).line(21, 12).line(17, 16).path
        }),

        // MARK: Small state marks

        "chevron.down": Glyph(stroke: { g in
            Pen(g).move(7, 10).line(12, 15).line(17, 10).path
        }),

        "xmark.circle": Glyph(stroke: { g in
            Pen(g).oval(3.5, 3.5, 17, 17)
                .move(9.2, 9.2).line(14.8, 14.8)
                .move(14.8, 9.2).line(9.2, 14.8).path
        }),

        "checkmark.circle.fill": Glyph(stroke: { g in
            Pen(g).oval(3.5, 3.5, 17, 17)
                .move(7.6, 12.4).line(10.6, 15.4).line(16.4, 8.8).path
        }),

        "exclamationmark.triangle.fill": Glyph(stroke: { g in
            Pen(g).move(12, 3.6).line(21.2, 19.8).line(2.8, 19.8).close()
                .move(12, 9.6).line(12, 14.4).path
        }, fill: { g in Pen(g).dot(12, 17.2, 0.95).path }),

        "photo": Glyph(stroke: { g in
            Pen(g).roundRect(3, 5, 18, 14, 2.4)
                .move(6, 16.4).line(10, 11.6).line(13, 14.6)
                .line(16, 11.4).line(19, 15.4).path
        }, fill: { g in Pen(g).dot(8, 8.6, 1.3).path }),

        // Two stroked rectangles on top of each other turn to mud at 15 points,
        // so the second print is only an edge peeking out from behind the first.
        "photo.on.rectangle.angled": Glyph(stroke: { g in
            Pen(g).move(6.6, 4.8).line(18.2, 4.8).quad(20.6, 4.8, 20.6, 7.2)
                .line(20.6, 13.8)
                .roundRect(3, 7.6, 14.6, 12.8, 2.4)
                .move(5.8, 17.2).line(8.8, 13.6).line(11.2, 15.8)
                .line(13.8, 12.8).line(16.2, 15.6).path
        }, fill: { g in Pen(g).dot(7, 11, 1.1).path }),
    ]
}

/// Maps the 24-unit drawing grid onto points.
private struct Grid {
    let u: CGFloat

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
    }

    /// Rotation about the centre of the grid, for glyphs that are easier to
    /// draw upright and then turned. Core Graphics composes a transform by
    /// appending, so the moves have to be written in the opposite order to the
    /// one they take effect in.
    func rotated(by angle: Double) -> CGAffineTransform {
        let c = p(12, 12)
        return CGAffineTransform.identity
            .translatedBy(x: c.x, y: c.y)
            .rotated(by: angle)
            .translatedBy(x: -c.x, y: -c.y)
    }
}

/// Builds a path in grid units so a glyph reads as the drawing it is.
private struct Pen {
    private let g: Grid
    private(set) var path = Path()

    init(_ g: Grid) { self.g = g }

    func move(_ x: CGFloat, _ y: CGFloat) -> Pen { copy { $0.move(to: g.p(x, y)) } }
    func line(_ x: CGFloat, _ y: CGFloat) -> Pen { copy { $0.addLine(to: g.p(x, y)) } }
    func quad(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) -> Pen {
        copy { $0.addQuadCurve(to: g.p(x, y), control: g.p(cx, cy)) }
    }
    func curve(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat,
               _ x: CGFloat, _ y: CGFloat) -> Pen {
        copy { $0.addCurve(to: g.p(x, y), control1: g.p(c1x, c1y), control2: g.p(c2x, c2y)) }
    }
    func close() -> Pen { copy { $0.closeSubpath() } }
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Pen {
        copy { $0.addEllipse(in: g.r(x, y, w, h)) }
    }
    func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                   _ corner: CGFloat) -> Pen {
        copy { $0.addRoundedRect(in: g.r(x, y, w, h),
                                 cornerSize: CGSize(width: corner * g.u, height: corner * g.u)) }
    }
    func arc(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat,
             _ from: CGFloat, _ to: CGFloat) -> Pen {
        copy { $0.addArc(center: g.p(cx, cy), radius: radius * g.u,
                         startAngle: .degrees(Double(from)), endAngle: .degrees(Double(to)),
                         clockwise: false) }
    }
    func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat = 1) -> Pen {
        oval(x - radius, y - radius, radius * 2, radius * 2)
    }

    /// A four-point sparkle: straight out to a point, then curved back in, the
    /// shape every retouch app uses for "make this better".
    func star(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat) -> Pen {
        let in1 = radius * 0.18
        return move(cx, cy - radius)
            .quad(cx + in1, cy - in1, cx + radius, cy)
            .quad(cx + in1, cy + in1, cx, cy + radius)
            .quad(cx - in1, cy + in1, cx - radius, cy)
            .quad(cx - in1, cy - in1, cx, cy - radius)
            .close()
    }

    private func copy(_ add: (inout Path) -> Void) -> Pen {
        var next = path
        add(&next)
        return Pen(g, next)
    }

    private init(_ g: Grid, _ path: Path) {
        self.g = g
        self.path = path
    }
}
