import Foundation
import SystemPackage

extension Array where Element == FileDescriptor {
  internal func closeAllIgnoringErrors() {
    for fd in self {
      // TODO: Log errors?
      try? fd.close()
    }
  }
}

extension Errno {
  /// The current error value, set by system calls if an error occurs.
  ///
  /// The corresponding C global variable is `errno`.
  internal static var current: Errno {
    get { Errno(rawValue: system_errno) }
    set { system_errno = newValue.rawValue }
  }
}
