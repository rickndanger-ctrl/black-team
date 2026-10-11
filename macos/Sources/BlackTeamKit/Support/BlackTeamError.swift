import Foundation

/// An error whose message is written for the person using the app and can be shown as it is.
public struct BlackTeamError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
