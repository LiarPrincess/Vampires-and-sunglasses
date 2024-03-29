import Foundation
import SystemPackage

/// Wrapper for `FileDescriptor` because actors do not support protocols/inheritance.
private struct File {

  private typealias Flags = UInt8

  private static let isClosedMask: Flags = 1 << 0

  private var fd: FileDescriptor
  private var flags = Flags.zero

  fileprivate init(_ fd: FileDescriptor) {
    self.fd = fd
  }

  fileprivate func getFileDescriptorUnlessCancelled() throws -> FileDescriptor {
    try Task.checkCancellation()

    // Prevent unintended read/write when file descriptor is re-used.
    if self.isSet(Self.isClosedMask) {
      throw Errno.badFileDescriptor
    }

    return fd
  }

  // We need to be idempotent as user can BOTH:
  // - select automatic `close` during the process creation
  // - call `close` (possibly multiple times)
  //
  // We want to prevent double-close.
  fileprivate mutating func idempotentClose() throws {
    if !self.isSet(Self.isClosedMask) {
      // Set flag before closing to prevent double closing on 'throw'.
      self.set(Self.isClosedMask)
      try fd.close()
    }
  }

  private func isSet(_ f: Flags) -> Bool { (self.flags & f) == f }
  private mutating func set(_ f: Flags) { self.flags = self.flags | f }
}

extension Subprocess {

  public actor Input {

    private var file: File

    internal init(nonBlockingFile fd: FileDescriptor) {
      self.file = File(fd)
    }

    /*
    IMPORTANT:
    https://www.man7.org/linux/man-pages/man7/pipe.7.html

    For n = number of bytes to be written:

    O_NONBLOCK enabled, n <= PIPE_BUF
      If there is room to write n bytes to the pipe, then
      write(2) succeeds immediately, writing all n bytes;
      otherwise write(2) fails, with errno set to EAGAIN.

    O_NONBLOCK enabled, n > PIPE_BUF
      If the pipe is full, then write(2) fails, with errno set
      to EAGAIN.  Otherwise, from 1 to n bytes may be written
      (i.e., a "partial write" may occur; the caller should
      check the return value from write(2) to see how many bytes
      were actually written), and these bytes may be interleaved
      with writes by other processes.
    */

    /// Writes the contents of a buffer into the pipe.
    ///
    /// This is a write on `O_NONBLOCK` pipe, so OS specific terms may apply.
    /// Be careful when writing more than `PIPE_BUF` bytes.
    ///
    /// Race condition: The result is undefined if the `buffer` was modified
    /// during the execution of this method.
    ///
    /// - Returns: The number of bytes that were written or `nil` if the write
    /// was blocked because the pipe is full.
    @discardableResult
    public func write(buffer: UnsafeRawBufferPointer) throws -> Int? {
      do {
// TODO: Split into PIPE_BUF chunks
        let fd = try self.file.getFileDescriptorUnlessCancelled()
        return try fd.write(buffer)
      } catch Errno.wouldBlock, Errno.resourceTemporarilyUnavailable {
        return nil
      }
    }

    /// Writes a sequence of bytes into the pipe.
    ///
    /// This is a write on `O_NONBLOCK` pipe, so OS specific terms may apply.
    /// Be careful when writing more than `PIPE_BUF` bytes.
    ///
    /// - Returns: The number of bytes that were written or `nil` if the write
    /// was blocked because the pipe is full.
    @discardableResult
    public func writeAll<S: Sequence & Sendable>(
      _ sequence: S
    ) throws -> Int? where S.Element == UInt8 {
      do {
// TODO: Split into PIPE_BUF chunks
        let fd = try self.file.getFileDescriptorUnlessCancelled()
        return try fd.writeAll(sequence)
      } catch Errno.wouldBlock, Errno.resourceTemporarilyUnavailable {
        return nil
      }
    }

    /// Writes a sequence of bytes into the pipe.
    ///
    /// This is a write on `O_NONBLOCK` pipe, so OS specific terms may apply.
    /// Be careful when writing more than `PIPE_BUF` bytes.
    ///
    /// - Returns: The number of bytes that were written or `nil` if the write
    /// was blocked because the pipe is full.
    @discardableResult
    public func writeAll<S: AsyncSequence & Sendable>(
      _ asyncSequence: S
    ) async throws -> Int? where S.Element == UInt8 {
      // This is what the proposal does…
      let sequence = try await Array(asyncSequence)
      return try self.writeAll(sequence)
    }

    /// Encodes the given `String` using the specified `encoding` and then
    /// writes the resulting sequence of bytes into the pipe.
    ///
    /// This is a write on `O_NONBLOCK` pipe, so OS specific terms may apply.
    /// Be careful when writing more than `PIPE_BUF` bytes.
    ///
    /// This should not be here, but for convenience it is. In reality we should
    /// have some kind of `StringInput` decorator that deals with all of the
    /// `String` nonsense (splitting lines etc.).
    ///
    /// Btw. `String.Encoding` is not `Sendable`.
    ///
    /// - Returns: The number of bytes that were written or `nil` if the write
    /// was blocked because the pipe is full.
    @discardableResult
    public func writeAll(
      _ s: String,
      encoding: String.Encoding = .utf8
    ) throws -> Int? {
      try Task.checkCancellation()

      // This is an 'Array', so we do not need to call 'deallocate'.
      guard let cString = s.cString(using: encoding) else {
        throw Errno.invalidArgument
      }

      return try cString.withUnsafeBufferPointer { charPtr in
        // CChar is a trivial type, so we do not have to rebind the memory.
        let ptr = UnsafeRawBufferPointer(charPtr)
        return try self.write(buffer: ptr)
      }
    }

    /// Idempotent close.
    public func close() throws {
      try self.file.idempotentClose()
    }
  }

  public actor Output {

    private typealias CloseContinuation = UnsafeContinuation<(), Never>

    private var file: File
    /// Number of long running reads, used to delay closing the file.
    private var pendingReadCount: Int32 = 0
    /// Resume close after all of the pending reads finished.
    private var closeContinuation: CloseContinuation?

    internal init(nonBlockingFile fd: FileDescriptor) {
      self.file = File(fd)
    }

    /// Read bytes from the pipe.
    ///
    /// - Returns: The number of bytes that were read or `nil` if there is no
    /// data available.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int? {
      let fd = try self.file.getFileDescriptorUnlessCancelled()

      switch try self.read(fd, into: buffer) {
      case .eof: return 0
      case .data(let byteCount): return byteCount
      case .noDataAvailableOnNonBlockingFile: return nil
      case .error(let e): throw e
      }
    }

    /// Read all of the data from the pipe.
    public func readAll() async throws -> Data {
      var result = Data()

      try await self.readAll { (buffer: UnsafeMutableRawBufferPointer, count: Int) in
        let ptr = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        result.append(ptr, count: count)
      }

      return result
    }

    /// Read all of the data from the pipe and then decode the `String` using
    /// the specified `encoding`.
    ///
    /// This should not be here, but for convenience it is. In reality we should
    /// have some kind of `StringOutput` decorator that deals with all of the
    /// `String` nonsense (splitting lines etc.).
    ///
    /// - Returns: Decoded `String` or `nil` if the decoding fails.
    public func readAll(encoding: String.Encoding) async throws -> String? {
      let data = try await self.readAll()
      return String(data: data, encoding: encoding)
    }

    /// Read and throw away all of the data. Closed file -> `EBADF`.
    internal func readAllDiscardingResult() async throws {
      try await self.readAll { (_, _) in }
    }

    private func readAll(onDataRead: (UnsafeMutableRawBufferPointer, Int) -> Void) async throws {
      let fd = try self.file.getFileDescriptorUnlessCancelled()

      // We are starting a long running read. Process may terminate during it.
      // We need to finish the read before we close the file.
      self.incrementPendingReadCount()
      defer { self.decrementPendingReadCount() }

      let count = 1024
      let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
      defer { buffer.deallocate() }

      while true {
        try Task.checkCancellation()

        switch try self.read(fd, into: buffer) {
        case .eof:
          return

        case .data(let byteCount):
          onDataRead(buffer, byteCount)

        case .noDataAvailableOnNonBlockingFile:
          // Wait and collect the remaining data.
          // There is a better way, but it is a bit complicated and I'm not
          // getting paid to write it.
          // Oh wait… I am not getting paid for any of this.
          let millisecond: UInt64 = 1_000_000
          try await Task.sleep(nanoseconds: 500 * millisecond)

        case .error(let e):
          throw e
        }
      }
    }

    private enum ReadResult {
      case eof
      case data(byteCount: Int)
      case noDataAvailableOnNonBlockingFile
      case error(Error)
    }

    private func read(
      _ fd: FileDescriptor,
      into buffer: UnsafeMutableRawBufferPointer
    ) throws -> ReadResult {
      do {
        let byteCount = try fd.read(into: buffer)

        // read(2)
        // If the file offset is at or past the end of file, no bytes are read,
        // and read() returns zero.
        // For pipes this means that the writing end is closed.
        if byteCount == 0 {
          return .eof
        }

        return .data(byteCount: byteCount)
      } catch Errno.wouldBlock, Errno.resourceTemporarilyUnavailable {
        // EAGAIN The file descriptor fd refers to a file other than a
        //        socket and has been marked nonblocking (O_NONBLOCK), and
        //        the read would block. See open(2) for further details on
        //        the O_NONBLOCK flag.
        return .noDataAvailableOnNonBlockingFile
      } catch {
        // For example: somebody closed the file in different `Task`.
        // Nothing we can do to handle it.
        return .error(error)
      }
    }

    /// Idempotent close.
    public func close() throws {
      try self.file.idempotentClose()
    }

    private func incrementPendingReadCount() {
      self.pendingReadCount += 1
    }

    private func decrementPendingReadCount() {
      self.pendingReadCount -= 1
      assert(self.pendingReadCount >= 0)

      if self.pendingReadCount == 0 {
        let close = self.closeContinuation
        self.closeContinuation = nil
        close?.resume()
      }
    }

    /// Uppercase - called from termination task.
    ///
    /// Wait until all long running reads finish and close the file.
    internal func CLOSE_AFTER_FINISHING_PENDING_READS() async throws {
      if self.pendingReadCount > 0 {
        await withUnsafeContinuation { continuation in
          self.closeContinuation = continuation
        }
      }

      try self.file.idempotentClose()
    }
  }
}
