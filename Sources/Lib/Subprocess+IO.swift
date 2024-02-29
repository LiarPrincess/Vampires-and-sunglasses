import Foundation
import SystemPackage

/// Wrapper for `FileDescriptor` because actors do not support protocols/inheritance.
private struct File {

  /// `nil` if user has not specified `pipe` or the file was closed by the
  /// `idempotentClose` method.
  fileprivate var fd: FileDescriptor?

  fileprivate init(_ fd: FileDescriptor?) {
    self.fd = fd
  }

  fileprivate func checkCancellationAndGetFile() throws -> FileDescriptor {
    try Task.checkCancellation()

    guard let fd = self.fd else {
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
    if let fd = self.fd {
      // Set to `nil` before closing to prevent double closing on 'throw'.
      self.fd = nil
      try fd.close()
    }
  }
}

extension Subprocess {

  public actor Input {

    private var file: File

    internal init(file fd: FileDescriptor?) {
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
        let fd = try self.file.checkCancellationAndGetFile()
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
        let fd = try self.file.checkCancellationAndGetFile()
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

    public func close() throws {
      try self.file.idempotentClose()
    }
  }

  public actor Output {

    private var file: File
    private var hasProcessTerminated = false

    internal init(nonBlockingFile fd: FileDescriptor?) {
      self.file = File(fd)
    }

    deinit {
      // If the process was terminated then we will do the delayed close as the
      // user can no longer read the buffered content.
      //
      // If the process is still running we will allow writes to a pipe until:
      // a) process is terminated
      // b) pipe buffer is full - at which point we block the child process
      if self.hasProcessTerminated {
        try? self.file.idempotentClose()
      }
    }

    /// Read bytes from the pipe.
    ///
    /// - Returns: The number of bytes that were read or `nil` if there is no
    /// data available.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int? {
      let fd = try self.file.checkCancellationAndGetFile()

      switch try self.read(fd, into: buffer) {
      case .ok(let byteCount): return byteCount
      case .noDataAvailableOnNonBlockingFile: return nil
      case .error(let e): throw e
      }
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
      let fd = try self.file.checkCancellationAndGetFile()
      var accumulator = Data()

      try await self.readAll(fd) { (buffer: UnsafeMutableRawBufferPointer, count: Int) in
        let ptr = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        accumulator.append(ptr, count: count)
      }

      return String(data: accumulator, encoding: encoding)
    }

    /// Do nothing with the data.
    internal func readAllDiscardingResult() async throws {
      try Task.checkCancellation()

      if let fd = self.file.fd {
        try await self.readAll(fd) { (_, _) in }
      }
    }

    private func readAll(
      _ fd: FileDescriptor,
      onDataRead: (UnsafeMutableRawBufferPointer, Int) -> Void
    ) async throws {
      let count = 1024
      let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
      defer { buffer.deallocate() }

      while true {
        try Task.checkCancellation()

        switch try self.read(fd, into: buffer) {
        case .ok(let byteCount):
          // read(2)
          // If the file offset is at or past the end of file, no bytes are read,
          // and read() returns zero.
          // For pipes this means that the writing end is closed.
          if byteCount == 0 {
            return
          }

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
      case ok(byteCount: Int)
      case noDataAvailableOnNonBlockingFile
      case error(Error)
    }

    private func read(
      _ fd: FileDescriptor,
      into buffer: UnsafeMutableRawBufferPointer
    ) throws -> ReadResult {
      do {
        let byteCount = try fd.read(into: buffer)
        return .ok(byteCount: byteCount)
      } catch Errno.wouldBlock, Errno.resourceTemporarilyUnavailable {
        //  EAGAIN The file descriptor fd refers to a file other than a
        //         socket and has been marked nonblocking (O_NONBLOCK), and
        //         the read would block.  See open(2) for further details on
        //         the O_NONBLOCK flag.
        return .noDataAvailableOnNonBlockingFile
      } catch {
        // For example: somebody closed the file in different `Task`.
        // Nothing we can do to handle it.
        return .error(error)
      }
    }

    /// Automatic closing is delayed until `deinit` to allow users to read the
    /// buffer after the process is terminated. They can call `close` if they
    /// really want to SIGPIPE the child (not recommended).
    internal func markProcessAsTerminated() {
      self.hasProcessTerminated = true
    }

    public func close() throws {
      try self.file.idempotentClose()
    }
  }
}
