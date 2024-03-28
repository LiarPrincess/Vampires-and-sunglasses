import Foundation
import SystemPackage

// swiftlint:disable function_body_length
// swiftlint:disable cyclomatic_complexity

extension Subprocess {

  public enum InitStdin: Sendable {
    /// No input.
    case none
    /// Read from `Subprocess.stdin` in the current process.
    case pipeFromParent(pipeSizeInBytes: CInt?)
    /// Read from file.
    case readFromFile(_ fd: FileDescriptor, close: Bool)

    /// Read from `Subprocess.stdin` in the current process.
    public static var pipeFromParent: Self { .pipeFromParent(pipeSizeInBytes: nil) }
    /// Read from file.
    public static func readFromFile(_ fd: FileDescriptor) -> Self { .readFromFile(fd, close: true) }
  }

  public enum InitStdout: Sendable {
    /// Send to the black hole.
    case discard
    /// Write to `Subprocess.stdout` or `Subprocess.stderr` in the current process.
    case pipeToParent(pipeSizeInBytes: CInt?)
    /// Write to file.
    case writeToFile(_ fd: FileDescriptor, close: Bool)

    /// Write to `Subprocess.stdout` or `Subprocess.stderr` in the current process.
    public static var pipeToParent: Self { .pipeToParent(pipeSizeInBytes: nil) }
    /// Write to file.
    public static func writeToFile(_ fd: FileDescriptor) -> Self { .writeToFile(fd, close: true) }
  }

  // TODO: InitStderr.stdout that merges to stdout
  public typealias InitStderr = InitStdout

  /// Error that occurred during `init`.
  public struct InitError: Swift.Error, Sendable, CustomStringConvertible {

    public enum Code: Equatable, Hashable, Sendable {
      /// Error when opening `stdin`.
      case stdin
      /// Error when opening `stdout`.
      case stdout
      /// Error when opening `stderr`.
      case stderr
      /// Error when creating the child process.
      case fork
      /// Error when running the executable.
      case exec
    }

    public var code: Code
    public var message: String
    public var source: Swift.Error?

    public init(code: Code, message: String, source: Swift.Error?) {
      self.code = code
      self.message = message
      self.source = source
    }

    public var description: String {
      let name: String

      switch self.code {
      case .stdin: name = "stdin"
      case .stdout: name = "stdout"
      case .stderr: name = "stderr"
      case .fork: name = "fork"
      case .exec: name = "exec"
      }

      let suffix = self.source.map { " (\($0))" } ?? ""
      return "\(name): \(message)\(suffix)"
    }

    internal static func io_openDevNull(_ code: Code, _ error: Error) -> Self {
      return Self(code: code, message: "Unable to open /dev/null", source: error)
    }

    internal static func io_setO_NONBLOCK(_ code: Code, _ error: Error) -> Self {
      return Self(code: code, message: "Unable to set O_NONBLOCK", source: error)
    }

    internal static func io_setPipeBufferSize(_ code: Code, _ error: Error) -> Self {
      return Self(code: code, message: "Unable to set pipe buffer size", source: error)
    }

    internal static func fork(_ message: String, _ error: CInt) -> Self {
      let e = Errno(rawValue: error)
      return Self(code: .fork, message: "\(message): \(e)", source: e)
    }

    internal static func exec(_ error: CInt) -> Self {
      let e = Errno(rawValue: error)
      return Self(code: .exec, message: "Unable to run executable", source: e)
    }
  }

  /// Absolute/relative executable path.
  ///
  /// Files with `close` property set to `True` will be closed even if the
  /// process creation fails (`Error` is thrown).
  public init(
    executablePath: String,
    arguments: Arguments = Arguments(),
    environment: Environment = .inherit,
    // workingDirectory: FilePath,
    // platformOptions: PlatformOptions,
    stdin stdinArg: InitStdin = .none,
    stdout stdoutArg: InitStdout = .discard,
    stderr stderrArg: InitStderr = .discard
  ) throws {
    // Files send to the child.
    var closeAfterSpawn = [FileDescriptor]()
    // Flies that stay in the parent (parent pipe ends).
    var closeAfterTermination = [FileDescriptor]()

    func cleanupAndThrow(_ error: InitError) throws -> Never {
      closeAfterSpawn.closeAllIgnoringErrors()
      closeAfterTermination.closeAllIgnoringErrors()
      throw error
    }

    // We can use a single file for both read and write.
    var discardFile: FileDescriptor?

    func sharedDiscardFile() throws -> FileDescriptor {
      if let fd = discardFile {
        return fd
      }

      let result = try FileDescriptor.open("/dev/null", .readWrite, options: .closeOnExec)
      discardFile = result
      closeAfterSpawn.append(result)
      return result
    }

    // ===============================
    // === Always close user files ===
    // ===============================

    func handleClose(_ fd: FileDescriptor, _ close: Bool) {
      if close { closeAfterSpawn.append(fd) }
    }

    switch stdinArg {
    case .none: break
    case .pipeFromParent: break
    case let .readFromFile(fd, close): handleClose(fd, close)
    }

    switch stdoutArg {
    case .discard: break
    case .pipeToParent: break
    case let .writeToFile(fd, close): handleClose(fd, close)
    }

    switch stderrArg {
    case .discard: break
    case .pipeToParent: break
    case let .writeToFile(fd, close): handleClose(fd, close)
    }

    // =============
    // === Stdin ===
    // =============

    let stdin: FileDescriptor
    let stdinNonBlockingWriter: FileDescriptor?

    switch stdinArg {
    case .none:
      do {
        stdin = try sharedDiscardFile()
        stdinNonBlockingWriter = nil
      } catch {
        try cleanupAndThrow(.io_openDevNull(.stdin, error))
      }

    case let .pipeFromParent(sizeInBytes):
      let p = try FileDescriptor.pipe()
      stdin = p.readEnd
      stdinNonBlockingWriter = p.writeEnd
      closeAfterSpawn.append(p.readEnd)
      closeAfterTermination.append(p.writeEnd)

      do {
        // Writing to full pipe should not block.
        try Self.setNonBlocking(p.writeEnd)
      } catch {
        try cleanupAndThrow(.io_setO_NONBLOCK(.stdin, error))
      }

      do {
        try Self.setPipeBufferSize(writeEnd: p.writeEnd, sizeInBytes: sizeInBytes)
      } catch {
        try cleanupAndThrow(.io_setPipeBufferSize(.stdin, error))
      }

    case let .readFromFile(fd, _):
      stdin = fd
      stdinNonBlockingWriter = nil
    }

    // =====================
    // === Stdout/stderr ===
    // =====================

    func createOutputFiles(
      _ errorCode: InitError.Code,
      _ o: InitStdout
    ) throws -> (write: FileDescriptor, read: FileDescriptor?) {
      switch o {
      case .discard:
        do {
          let fd = try sharedDiscardFile()
          return (fd, nil)
        } catch {
          try cleanupAndThrow(.io_openDevNull(errorCode, error))
        }

      case let .pipeToParent(sizeInBytes):
        let (readEnd, writeEnd) = try FileDescriptor.pipe()
        closeAfterTermination.append(readEnd)
        closeAfterSpawn.append(writeEnd)

        do {
          // Reading from an empty pipe should not block.
          try Self.setNonBlocking(readEnd)
        } catch {
          try cleanupAndThrow(.io_setO_NONBLOCK(errorCode, error))
        }

        do {
          try Self.setPipeBufferSize(writeEnd: writeEnd, sizeInBytes: sizeInBytes)
        } catch {
          try cleanupAndThrow(.io_setPipeBufferSize(errorCode, error))
        }

        return (writeEnd, readEnd)

      case let .writeToFile(fd, _):
        return (fd, nil)
      }
    }

    let (stdout, stdoutNonBlockingReader) = try createOutputFiles(.stdout, stdoutArg)
    let (stderr, stderrNonBlockingReader) = try createOutputFiles(.stderr, stderrArg)

    // =============
    // === Spawn ===
    // =============

    let spawnResult = system_spawn(
      executablePath: executablePath,
      arguments: arguments,
      environment: environment,
      stdin: stdin,
      stdout: stdout,
      stderr: stderr
    )

    let pid: pid_t

    switch spawnResult {
    case let .success(p): pid = p
    case let .failure(e): try cleanupAndThrow(e)
    }

    // We can close the pipes that were moved to the child as 'dup2' was used.
    closeAfterSpawn.closeAllIgnoringErrors()
    // Skip those pipes if we ever call 'cleanupAndThrow'.
    // (Which currently does not happen, but maybe in the future.)
    closeAfterSpawn = []

#if DEBUG
    // Sanity check. Only parent pipes should be closed after the termination.
    // Child ends should be already closed via 'closeAfterSpawn'.
    for fd in closeAfterTermination {
      let isParent = fd == stdinNonBlockingWriter
        || fd == stdoutNonBlockingReader
        || fd == stderrNonBlockingReader

      assert(isParent)
    }
#endif

    self.init(
      pid: pid,
      stdinNonBlockingWriter: stdinNonBlockingWriter,
      stdoutNonBlockingReader: stdoutNonBlockingReader,
      stderrNonBlockingReader: stderrNonBlockingReader
    )

    print("[\(pid)] \(executablePath)")
    SYSTEM_MONITOR_TERMINATION(process: self)
  }

  private static func setNonBlocking(_ fd: FileDescriptor) throws {
    if let e = system_fcntl_set_O_NONBLOCK(fd) {
      throw e
    }
  }

  private static func setPipeBufferSize(
    writeEnd: FileDescriptor,
    sizeInBytes: CInt?
  ) throws {
    guard let sizeInBytes = sizeInBytes else { return }
    precondition(sizeInBytes >= 0, "Pipe size must be >= 0.")

    guard let errno = system_fcntl_F_SETPIPE_SZ(
      writeEnd: writeEnd,
      sizeInBytes: sizeInBytes
    ) else {
      return
    }

    switch errno {
    case .resourceBusy: break // Current size is bigger
    default: throw errno
    }
  }
}
