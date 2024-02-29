import Foundation

public struct Environment: Sendable {
    internal enum Configuration {
        case inherit([StringOrRawBytes: StringOrRawBytes])
        case custom([StringOrRawBytes: StringOrRawBytes])
    }

    internal let config: Configuration

    // swiftlint:disable unneeded_synthesized_initializer
    init(config: Configuration) {
        self.config = config
    }

    public static var inherit: Self {
        return .init(config: .inherit([:]))
    }

    public func updating(_ newValue: [String: String]) -> Self {
        return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
    }

    public func updating(_ newValue: [Data: Data]) -> Self {
        return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
    }

    public static func custom(_ newValue: [String: String]) -> Self {
        return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
    }

    public static func custom(_ newValue: [Data: Data]) -> Self {
        return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
    }
}

fileprivate extension Dictionary where Key == String, Value == String {
    func wrapToStringOrRawBytes() -> [StringOrRawBytes: StringOrRawBytes] {
        var result = [StringOrRawBytes: StringOrRawBytes](minimumCapacity: self.count)
        for (key, value) in self {
            result[.string(key)] = .string(value)
        }
        return result
    }
}
