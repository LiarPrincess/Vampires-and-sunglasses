import Foundation
import SystemPackage

// swiftlint:disable function_body_length
// swiftlint:disable cyclomatic_complexity

extension Subprocess {

  public enum InitStdin: Sendable {
    /// No input.
    case none
    /// Read from `Subprocess.stdin` in the current process.
    case readFromPipe(pipeSizeInBytes: CInt?)
    /// Read from file.
    case readFromFile(_ fd: FileDescriptor, close: Bool)

    /// Read from `Subprocess.stdin` in the current process.
    public static var readFromPipe: Self { .readFromPipe(pipeSizeInBytes: nil) }
    /// Read from file.
    public static func readFromFile(_ fd: FileDescriptor) -> Self { .readFromFile(fd, close: true) }
  }

  public enum InitStdout: Sendable {
    /// Send to the black hole.
    case discard
    /// Write to `Subprocess.stdout` or `Subprocess.stderr` in the current process.
    case writeToPipe(pipeSizeInBytes: CInt?)
    /// Write to file.
    case writeToFile(_ fd: FileDescriptor, close: Bool)

    /// Write to `Subprocess.stdout` or `Subprocess.stderr` in the current process.
    public static var writeToPipe: Self { .writeToPipe(pipeSizeInBytes: nil) }
    /// Write to file.
    public static func writeToFile(_ fd: FileDescriptor) -> Self { .writeToFile(fd, close: true) }
  }

  public typealias InitStderr = InitStdout

  /// Errors that occurred during `init`.
  public enum InitError: Swift.Error {
    case IOError(Swift.Error)
    case spawnError(SystemPackage.Errno)
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
    /// Combines: files provided by the user and the ones opened by us (pipes etc…).
    var filesToClose = [FileDescriptor]()
    /// After we spawn we can close the child end of the pipe.
    var childPipesToClose = [FileDescriptor]()

    func cleanupAndThrow(_ error: InitError) throws -> Never {
      filesToClose.closeAllIgnoringErrors()
      childPipesToClose.closeAllIgnoringErrors()
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
      filesToClose.append(result)
      return result
    }

    // ===============================
    // === Always close user files ===
    // ===============================

    switch stdinArg {
    case .none: break
    case .readFromPipe: break
    case let .readFromFile(fd, close): if close { filesToClose.append(fd) }
    }

    switch stdoutArg {
    case .discard: break
    case .writeToPipe: break
    case let .writeToFile(fd, close): if close { filesToClose.append(fd) }
    }

    switch stderrArg {
    case .discard: break
    case .writeToPipe: break
    case let .writeToFile(fd, close): if close { filesToClose.append(fd) }
    }

    // =============
    // === Stdin ===
    // =============
// TODO: O_CLOEXEC?

    let stdin: FileDescriptor
    let stdinWriter: FileDescriptor?

    do {
      switch stdinArg {
      case .none:
        stdin = try sharedDiscardFile()
        stdinWriter = nil

      case let .readFromPipe(sizeInBytes):
        let p = try FileDescriptor.pipe()
        stdin = p.readEnd
        stdinWriter = p.writeEnd
        childPipesToClose.append(p.readEnd)
        filesToClose.append(p.writeEnd)
        // Writing to full pipe should not block.
        try Self.setNonBlocking(p.writeEnd)
        try Self.setPipeBufferSize(writeEnd: p.writeEnd, sizeInBytes: sizeInBytes)

      case let .readFromFile(fd, _):
        stdin = fd
        stdinWriter = nil
      }
    } catch {
      try cleanupAndThrow(.IOError(error))
    }

    // =====================
    // === Stdout/stderr ===
    // =====================

    func createOutputFiles(
      _ o: InitStdout
    ) throws -> (write: FileDescriptor, read: FileDescriptor?) {
      switch o {
      case .discard:
        let fd = try sharedDiscardFile()
        return (fd, nil)

      case let .writeToPipe(sizeInBytes):
        let (readEnd, writeEnd) = try FileDescriptor.pipe()
        filesToClose.append(readEnd)
        childPipesToClose.append(writeEnd)
        // Reading from an empty pipe should not block.
        try Self.setNonBlocking(readEnd)
        try Self.setPipeBufferSize(writeEnd: writeEnd, sizeInBytes: sizeInBytes)
        return (writeEnd, readEnd)

      case let .writeToFile(fd, _):
        return (fd, nil)
      }
    }

    let stdout: FileDescriptor
    let stdoutNonBlockingReader: FileDescriptor?

    do {
      (stdout, stdoutNonBlockingReader) = try createOutputFiles(stdoutArg)
    } catch {
      try cleanupAndThrow(.IOError(error))
    }

    let stderr: FileDescriptor
    let stderrNonBlockingReader: FileDescriptor?

    do {
      (stderr, stderrNonBlockingReader) = try createOutputFiles(stderrArg)
    } catch {
      try cleanupAndThrow(.IOError(error))
    }

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
    case let .failure(e): try cleanupAndThrow(.spawnError(e))
    }

    // We can close the pipes that were moved to the child as 'dup2' was used.
    childPipesToClose.closeAllIgnoringErrors()
    // Skip those pipes if we ever call 'cleanupAndThrow'.
    // (Which currently does not happen, but maybe in the future.)
    childPipesToClose = []

    self.init(
      pid: pid,
      stdinNonBlockingWriter: stdinWriter,
      stdoutNonBlockingReader: stdoutNonBlockingReader,
      stderrNonBlockingReader: stderrNonBlockingReader,
      filesToClose: filesToClose
    )

    print("[\(pid)] \(executablePath)")
    SYSTEM_WAIT_FOR_TERMINATION_IN_BACKGROUND(process: self)
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
