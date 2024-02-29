import Foundation

extension RangeReplaceableCollection {
    /// Creates a new instance of a collection containing the elements of an asynchronous sequence.
    ///
    /// - Parameter source: The asynchronous sequence of elements for the new collection.
    @inlinable
    internal init<Source: AsyncSequence>(
        _ source: Source
    ) async rethrows where Source.Element == Element {
        self.init()
        for try await item in source {
            append(item)
        }
    }
}

extension Dictionary where Key == Data, Value == Data {
    internal func wrapToStringOrRawBytes() -> [StringOrRawBytes: StringOrRawBytes] {
        var result = [StringOrRawBytes: StringOrRawBytes](minimumCapacity: self.count)
        for (key, value) in self {
            result[.rawBytes(key.toArray())] = .rawBytes(value.toArray())
        }
        return result
    }
}

extension Data {
    internal func toArray<T>() -> [T] {
        return self.withUnsafeBytes { ptr in
            return Array(ptr.bindMemory(to: T.self))
        }
    }
}
