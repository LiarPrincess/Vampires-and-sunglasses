import Foundation

public struct Arguments: Sendable, ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = String

    internal let storage: [StringOrRawBytes]
    internal let executablePathOverride: StringOrRawBytes?

    public init(arrayLiteral elements: String...) {
        self.storage = elements.map { .string($0) }
        self.executablePathOverride = nil
    }

    public init(_ array: [String], executablePathOverride: String? = nil) {
        self.storage = array.map { .string($0) }

        if let o = executablePathOverride {
            self.executablePathOverride = .string(o)
        } else {
            self.executablePathOverride = nil
        }
    }

    public init(_ array: [Data], executablePathOverride: Data? = nil) {
        self.storage = array.map { .rawBytes($0.toArray()) }
        if let override = executablePathOverride {
            self.executablePathOverride = .rawBytes(override.toArray())
        } else {
            self.executablePathOverride = nil
        }
    }

    public mutating func append(_ s: String) {}
    public mutating func append(_ s: Data) {}
}
