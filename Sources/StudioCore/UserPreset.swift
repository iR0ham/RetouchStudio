import Foundation

/// A look the owner saved from their own slider positions.
public struct UserPreset: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var adjustments: Adjustments

    public init(id: String = UUID().uuidString, name: String,
                adjustments: Adjustments = Adjustments()) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
    }
}
