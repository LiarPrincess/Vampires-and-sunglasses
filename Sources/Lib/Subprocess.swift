#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation
import SystemPackage

// swiftlint:disable file_length

// swiftlint:disable:next line_length
private let stdinIsNotPipeError = "Subprocess.stdin can only be used if 'pipeFromParent' was selected during initialization."
// swiftlint:disable:next line_length
private let stdoutIsNotPipeError = "Subprocess.stdout can only be used if 'pipeToParent' was selected during initialization."
// swiftlint:disable:next line_length
private let stderrIsNotPipeError = "Subprocess.stderr can only be used if 'pipeToParent' was selected during initialization."

public actor Subprocess {

  private enum State {
    case running
    case terminated(exitStatus: CInt)
  }

  private typealias SuspensionFn = UnsafeContinuation<CInt, Error>

  /// `Suspension` is the state of a task waiting for termination.
  ///
  /// It is a class because instance identity helps `wait()` deal with both
  /// early and late cancellation.
  ///
  /// We make it `@unchecked Sendable` in order to prevent compiler warnings:
  /// instances are always protected by the `Subprocess` actor.
  ///
  /// Copied from the fantastic `AsyncSemaphore` library by Gwendal Roué:
  /// https://github.com/groue/Semaphore/blob/main/Sources/Semaphore/AsyncSemaphore.swift
  private final class Suspension: @unchecked Sendable {
    fileprivate enum State {
      case pending
      case suspended(SuspensionFn)
      case cancelled
    }

    /// Id is used only for printing.
    fileprivate var id: UInt8
    fileprivate var state: State

    fileprivate init(id: UInt8, state: State) {
      self.id = id
      self.state = state
    }
  }

  internal static let exitStatusIfWeDontKnowTheRealOne: CInt =  255

  public let pid: pid_t

  private let _stdin: Input?
  private let _stdout: Output?
  private let _stderr: Output?

  /// Useful only if you specified `pipe` during creation.
  ///
  /// Possible race if you do not `await` writes from multiple `tasks` before
  /// termination. In general all IO operations should belong to a single `Task`.
  public var stdin: Input {
    guard let s = self._stdin else { preconditionFailure(stdinIsNotPipeError) }
    return s
  }

  /// Useful only if you specified `pipe` during creation.
  ///
  /// Reads are non-blocking, meaning that they will return immediately if there
  /// is no data waiting in a buffer.
  ///
  /// This object can be used after the process termination. This allows reading
  /// the data collected in the pipe buffer after the is no longer running.
  public var stdout: Output {
    guard let s = self._stdout else { preconditionFailure(stdoutIsNotPipeError) }
    return s
  }

  /// Useful only if you specified `pipe` during creation.
  ///
  /// Reads are non-blocking, meaning that they will return immediately if there
  /// is no data waiting in a buffer.
  ///
  /// This object can be used after the process termination. This allows reading
  /// the data collected in the pipe buffer after the is no longer running.
  public var stderr: Output {
    guard let s = self._stderr else { preconditionFailure(stderrIsNotPipeError) }
    return s
  }

  /// Suspended `Tasks` waiting for termination.
  private var suspensions = [Suspension]()
  /// Last known state of the process.
  private var state = State.running

  internal init(
    pid: pid_t,
    stdinNonBlockingWriter stdinWriter: FileDescriptor?,
    stdoutNonBlockingReader stdoutReader: FileDescriptor?,
    stderrNonBlockingReader stderrReader: FileDescriptor?
  ) {
    self.pid = pid
    self._stdin = stdinWriter.map(Input.init(nonBlockingFile:))
    self._stdout = stdoutReader.map(Output.init(nonBlockingFile:))
    self._stderr = stderrReader.map(Output.init(nonBlockingFile:))
  }

  deinit {
    // Explicitly empty :)
    // Did you know that actor->deinit is called in 'async' manner?
    // Actor instances are not scope based. They live a little bit longer.
  }

  /// Terminate the process with `SIGTERM`.
  ///
  /// ## Race condition
  ///
  /// This method respects cancellation, so sending the signal, and then canceling
  /// the `Task` before the completion will throw `CancellationError`.
  /// In such case is undefined whether the signal was delivered or not.
  ///
  /// - Returns: `true` if the signal was delivered. `false` if the process
  /// was already terminated.
  @discardableResult
  public func terminate() throws -> Bool { try self.sendSignal(.terminate) }

  /// Kill the process with `SIGKILL`.
  ///
  /// ## Race condition
  ///
  /// This method respects cancellation, so sending the signal, and then canceling
  /// the `Task` before the completion will throw `CancellationError`.
  /// In such case is undefined whether the signal was delivered or not.
  ///
  /// - Returns: `true` if the signal was delivered. `false` if the process
  /// was already terminated.
  @discardableResult
  public func kill() throws -> Bool { try self.sendSignal(.kill) }

  /// Sends the `signal` to the child process.
  ///
  /// ## Race condition
  ///
  /// This method respects cancellation, so sending the signal, and then canceling
  /// the `Task` before the completion will throw `CancellationError`.
  /// In such case is undefined whether the signal was delivered or not.
  ///
  /// - Parameter signal: Signal to send.
  ///
  /// - Returns: `true` if the signal was delivered. `false` if the process
  /// was already terminated.
  @discardableResult
  public func sendSignal(_ signal: Signal) throws -> Bool {
    try Task.checkCancellation()

    switch self.state {
    case .running: break
    case .terminated: return false
    }

    guard let errno = system_kill(pid: self.pid, signal: signal.rawValue) else {
      return true
    }

    try Task.checkCancellation()

    switch errno {
    case .noSuchProcess:
      // Race between termination watcher and 'kill'.
      return false
    default:
      throw errno
    }
  }

  /// Wait for the child process to terminate.
  ///
  /// ## Deadlock
  ///
  /// This method can deadlock when using `stdout=PIPE` or `stderr=PIPE` and the
  /// child process generates so much output that it blocks waiting for the OS
  /// pipe buffer to accept more data. Use the `closePipesAndWait()` method when
  /// using pipes to avoid this condition.
  ///
  /// - Returns: The exit status.
  @discardableResult
  public func waitForTermination() async throws -> CInt {
    try Task.checkCancellation()

    switch self.state {
    case .running: break
    case .terminated(let exitStatus):
      print("[\(self.pid)] Wait for terminated process returns immediately.")
      return exitStatus
    }

    // Copied from the fantastic 'AsyncSemaphore' library by Gwendal Roué:
    // https://github.com/groue/Semaphore/blob/main/Sources/Semaphore/AsyncSemaphore.swift

    let id = UInt8.random(in: 0...UInt8.max) // For printing.
    let suspension = Suspension(id: id, state: .pending)

    // Get ready for being suspended waiting for a continuation, or early cancellation.
    return try await withTaskCancellationHandler {
      try await withUnsafeThrowingContinuation { (continuation: SuspensionFn) in
        // There will be no suspension when calling this method as we are in the
        // same execution context.
        self.onWait(suspension: suspension, continuation: continuation)
      }
    } onCancel: {
      // 'withTaskCancellationHandler' may immediately call this block (if the current
      // task is cancelled), or call it later (if the task is cancelled later).
      Task { await self.onWaitCancellation(suspension: suspension) }
    }
  }

  private func onWait(suspension: Suspension, continuation: SuspensionFn) {
    switch suspension.state {
    case .pending:
      // Current task is not cancelled: register the continuation that
      // termination will resume.
      print("[\(self.pid)] [Wait: \(suspension.id)] Suspending.")
      suspension.state = .suspended(continuation)
      self.suspensions.append(suspension)
    case .cancelled:
      // Early cancellation: 'wait()' is called from a cancelled task, and the
      // 'onWaitCancellation(suspension:)' has marked the suspension as cancelled.
      print("[\(self.pid)] [Wait: \(suspension.id)] Early cancellation.")
      continuation.resume(throwing: CancellationError())
    case .suspended:
      fatalError("Subprocess: 'wait' suspended upon creation?")
    }
  }

  private func onWaitCancellation(suspension: Suspension) {
    // We're no longer waiting for the termination.
    if let index = self.suspensions.firstIndex(where: { $0 === suspension }) {
      self.suspensions.remove(at: index)
    }

    switch suspension.state {
    case .pending:
      // Early cancellation: 'wait()' is called from a cancelled task. The next
      // step is the `onWait(suspension:continuation:)` operation right above.
      suspension.state = .cancelled
    case .cancelled:
      fatalError("Subprocess: 'wait' is cancelled twice?")
    case .suspended(let continuation):
      // Late cancellation: the task is cancelled while waiting.
      print("[\(self.pid)] [Wait: \(suspension.id)] Late cancellation.")
      continuation.resume(throwing: CancellationError())
    }
  }

  public struct ReadOutputAndWaitResult: Sendable {
    public let exitStatus: CInt
    public let stdout: Data
    public let stderr: Data
  }

  /// Wait for the child process to terminate.
  ///
  /// 1. Read the data from `stdout` and `stderr` until end-of-file is reached.
  /// 2. Wait for the process to terminate.
  ///
  /// Reads are important because some native platforms only provide limited
  /// buffer size for standard input and output streams. Failure to promptly
  /// read the output stream may cause the subprocess to block, or even deadlock.
  ///
  /// Importanties:
  /// - output is collected only if `pipeToParent` was used when creating
  ///   the `Subprocess`.
  /// - this method should be called from the same task that does the IO.
  ///   Configurations where one task does `process.stdout.read` and the other
  ///   does `process.readOutputAndWaitForTermination` are not deterministic,
  ///   since both of those tasks are performing `read` at the same time.
  /// - you can disable output collection by setting `collectStdout` or
  ///   `collectStderr` to `false`.
  /// - the data read is buffered in memory, so do not use this method if the
  ///   data size is large or unlimited.
  @discardableResult
  public func readOutputAndWaitForTermination(
    collectStdout: Bool = true,
    collectStderr: Bool = true
  ) async throws -> ReadOutputAndWaitResult {
    @Sendable
    func read(_ out: Output?, collect: Bool) async throws -> Data {
      guard let out = out else {
        return Data()
      }

      do {
        if collect {
          return try await out.readAll()
        }

        try await out.readAllDiscardingResult()
        return Data()
      } catch Errno.badFileDescriptor {
        // File is closed.
        return Data()
      }
    }

    // Read stdout/stderr in parallel as we do not know to which one the process
    // writes. We can do this because those are 2 different pipes.
    async let stdout = read(self._stdout, collect: collectStdout)
    async let stderr = read(self._stderr, collect: collectStderr)

    // Remember to await for streams before the 'wait'!
    let streams = try await (stdout, stderr)
    let exitStatus = try await self.waitForTermination()

    return ReadOutputAndWaitResult(
      exitStatus: exitStatus,
      stdout: streams.0,
      stderr: streams.1
    )
  }

  private enum TerminateAfterResult<R> {
  case success(R)
  case cancelled
  case failure(Error)
  }

  /// Runs a closure and then terminates the process, even if an error or `Task`
  /// cancellation occurs.
  ///
  /// This is similar to `FileDescriptor.closeAfter(body:)`. We could allow
  /// users to specify their own termination routine, this would end up being
  /// similar to `withTaskCancellationHandler(operation:onCancel:)`.
  ///
  /// - Returns: The value returned by the closure.
  public func terminateAfter<R: Sendable>(
    signal: Signal = .terminate,
    body: () async throws -> R
  ) async throws -> R {
    let result: TerminateAfterResult<R>

    do {
      let r = try await body()
      result = .success(r)
    } catch let e where e is CancellationError {
      result = .cancelled
    } catch {
      result = .failure(error)
    }

    // Returns 'false' if already terminated.
    try self.terminate()
    // Synchronize. Returns immediately if already terminated.
    try await self.waitForTermination()

    try Task.checkCancellation()

    switch result {
    case .success(let r): return r
    case .cancelled: throw CancellationError()
    case .failure(let e): throw e
    }
  }

  /// Uppercase because Death SPEAKS IN UPPERCASE.
  ///
  /// DO NOT CALL❗❗❗❗❗ Only the background helper can call this method.
  /// (Yes, those are 5 exclamation marks. Another Discworld reference.)
  internal func TERMINATION_CALLBACK(exitStatus: CInt) async {
    self.state = .terminated(exitStatus: exitStatus)

    print("[\(self.pid)] Closing files.")

    // Stdin can be closed without any problems.
    try? await self._stdin?.close()

    // Race condition: there may be a pending read on stdout/stderr (for example
    // from 'self.readOutputAndWaitForTermination'). We need to allow it to
    // finish reading data from the pipe buffer.
    try? await self._stdout?.CLOSE_AFTER_FINISHING_PENDING_READS()
    try? await self._stderr?.CLOSE_AFTER_FINISHING_PENDING_READS()

    print("[\(self.pid)] Resuming 'wait' suspensions.")

    // Clean the global suspension list, we will no longer need it.
    let suspensions = self.suspensions
    self.suspensions = []

    for suspension in suspensions {
      switch suspension.state {
      case .suspended(let continuation):
        print("[\(self.pid)] [Wait: \(suspension.id)] Resuming.")
        continuation.resume(returning: exitStatus)
      case .pending:
        fatalError("Subprocess: pending suspension after termination?")
      case .cancelled:
        fatalError("Subprocess: cancelled suspension after termination?")
      }
    }
  }
}
