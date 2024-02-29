import Foundation

internal enum StringOrRawBytes: Sendable, Hashable {
    case string(String)
    case rawBytes([CChar])

    // Return value needs to be deallocated manually by callee
    func createRawBytes() -> UnsafeMutablePointer<CChar> {
        switch self {
        case .string(let string):
            return strdup(string)
        case .rawBytes(let rawBytes):
            return strdup(rawBytes)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let string):
            return string
        case .rawBytes(let rawBytes):
            return String(validatingUTF8: rawBytes)
        }
    }

    var count: Int {
        switch self {
        case .string(let string):
            return string.count
        case .rawBytes(let rawBytes):
            return strnlen(rawBytes, Int.max)
        }
    }
}
