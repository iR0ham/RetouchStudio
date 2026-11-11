import Foundation
import StudioCore
import SwiftUI

extension MakeupColor {
    var color: Color {
        let c = rgb
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

extension MakeupFamily {
    var title: String {
        L10n.current.makeupFamilyTitle(self)
    }
}

extension MakeupRegion {
    var title: String {
        L10n.current.makeupRegionTitle(self)
    }
}
