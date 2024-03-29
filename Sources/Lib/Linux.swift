#if canImport(Darwin) || canImport(Glibc)

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import CLib
import Foundation
import SystemPackage

// swiftlint:disable file_length
// swiftlint:disable function_parameter_count
// swiftlint:disable cyclomatic_complexity
// swiftlint:disable function_body_length

#if canImport(Darwin)
internal var system_errno: CInt {
  get { Darwin.errno }
  set { Darwin.errno = newValue }
}
#elseif canImport(Glibc)
internal var system_errno: CInt {
  get { Glibc.errno }
  set { Glibc.errno = newValue }
}
#endif

internal func system_spawn(
  executablePath: String,
  arguments: Arguments,
  environment: Environment,
  stdin: FileDescriptor,
  stdout: FileDescriptor,
  stderr: FileDescriptor
) -> Result<pid_t, InitError> {
  func cleanupAndThrow(_ e: InitError) -> Result<pid_t, InitError> {
    // No cleanup
    return .failure(e)
  }

  // ============
  // === Argv ===
  // ============

  var argv = [UnsafePointer<CChar>?]()
  defer { for s in argv { s?.deallocate() } }

  if let arg0 = arguments.executablePathOverride {
    argv.append(arg0.createRawBytes())
  } else {
    argv.append(strdup(executablePath))
  }

  for arg in arguments.storage {
    argv.append(arg.createRawBytes())
  }

  argv.append(nil)

  // ===========
  // === Env ===
  // ===========

  func createEnvEntry(
    key: StringOrRawBytes,
    value: StringOrRawBytes
  ) -> UnsafeMutablePointer<CChar> {
    let keyBytes: UnsafeMutablePointer<CChar> = key.createRawBytes()
    let valueBytes: UnsafeMutablePointer<CChar> = value.createRawBytes()
    defer {
        keyBytes.deallocate()
        valueBytes.deallocate()
    }

    // length = `key` + `=` + `value` + `\null`
// TODO: [CRITICAL] strlen does not work on bytes? Check Linux kernel.
    let keyLength = strlen(keyBytes)
    let valueLength = strlen(valueBytes)
    let length = keyLength + 1 + valueLength + 1

    let result = UnsafeMutablePointer<CChar>.allocate(capacity: length)
    result.initialize(from: keyBytes, count: keyLength)
    result.advanced(by: keyLength).initialize(to: 61) // =
    result.advanced(by: keyLength + 1).initialize(from: valueBytes, count: valueLength)
    result.advanced(by: keyLength + 1 + valueLength).initialize(to: 0) // NULL
    // _ = snprintf(result, length, "%s=%s", keyBytes, valueBytes)

    return result
  }

  var env: [UnsafePointer<CChar>?] = []
  defer { for s in env { s?.deallocate() } }

  switch environment.config {
  case .inherit(let updates):
    var old = ProcessInfo.processInfo.environment

    for (key, value) in updates {
      if let stringKey = key.stringValue {
        old.removeValue(forKey: stringKey)
      }

      env.append(createEnvEntry(key: key, value: value))
    }

    for (key, value) in old {
      let fullString = "\(key)=\(value)"
      env.append(strdup(fullString))
    }

  case .custom(let customValues):
    for (key, value) in customValues {
      env.append(createEnvEntry(key: key, value: value))
    }
  }

  env.append(nil)

  // =============
  // === Spawn ===
  // =============

// TODO: QualityOfService
// TODO: CWD

  var forkErrno: CInt = 0

  let pid = executablePath.withCString { exePath in
    _clib_fork_exec(
      exePath,
      argv,
      env,
      stdin.rawValue,
      stdout.rawValue,
      stderr.rawValue,
      &forkErrno
    )
  }

  if pid < 0 {
    let error: InitError

    switch pid {
    case _CLIB_FORK_EXEC_ERR_FORK:
      error = .fork("Unable to fork subprocess", forkErrno)
    case _CLIB_FORK_EXEC_CHILD_ERR_DUP2:
      error = .fork("Unable to set subprocess stdin/stdout/stderr", forkErrno)

    case _CLIB_FORK_EXEC_ERR_PIPE_OPEN:
      error = .fork("Unable to open exec pipe", forkErrno)
    case _CLIB_FORK_EXEC_ERR_PIPE_READ:
      error = .fork("Unable to read exec pipe", forkErrno)
    case _CLIB_FORK_EXEC_CHILD_ERR_PIPE_CLOEXEC:
      error = .fork("Unable to set exec pipe FD_CLOEXEC", forkErrno)

    case _CLIB_FORK_EXEC_CHILD_ERR_EXEC:
      error = .exec(forkErrno)

    default:
      // We added a new operation in C, but forgot to update Swift code?
      fatalError("system_spawn: Unknown fork/exec error: \(forkErrno)")
    }

    return cleanupAndThrow(error)
  }

  return .success(pid)
}

/// Set pipe buffer size to `sizeInBytes`.
internal func system_fcntl_F_SETPIPE_SZ(
  writeEnd: FileDescriptor,
  sizeInBytes: CInt
) -> Errno? {
  assert(sizeInBytes >= 0)

#if os(Linux)
  let result = _clib_fcntl_3(writeEnd.rawValue, _CLIB_F_SETPIPE_SZ, sizeInBytes)

  if result == -1 {
    return .current
  }
#else
  print("Custom pipe size is only for Linux. I'm too lazy to write #ifs.")
#endif

  return nil
}

/// Set pipe read end to `O_NONBLOCK`.
internal func system_fcntl_set_O_NONBLOCK(_ fd: FileDescriptor) -> Errno? {
  let oldFlags = fcntl(fd.rawValue, F_GETFL)

  if oldFlags == -1 {
    return .current
  }

  let newFlags = oldFlags | O_NONBLOCK
  if oldFlags == newFlags {
    return nil
  }

  let result = _clib_fcntl_3(fd.rawValue, F_SETFL, newFlags)

  if result == -1 {
    return .current
  }

  return nil
}

internal func system_kill(pid: pid_t, signal: CInt) -> Errno? {
  let result = kill(pid, signal)

  if result == -1 {
    return .current
  }

  return nil
}

internal protocol System_ChildWatcher {
  /// Fork success: `waitpid`. Can't fail.
  func resume(process: Subprocess)
  /// Fork failure: cancel `waitpid`. Can't fail.
  func cancel()
}

/// Create the child watcher.
/// Don't forget to call `watcher.resume()` or `watcher.cancel()` later!
///
/// Uppercase because Death SPEAKS IN UPPERCASE.
/// https://en.wikipedia.org/wiki/Death_(Discworld)
internal func SYSTEM_INIT_CHILD_WATCHER() -> Result<some System_ChildWatcher, InitError> {
  // Threaded solution is not the best, but it is ultra portable :)
  //
  // Python has a nice collection of possible watchers:
  // https://github.com/python/cpython/blob/main/Lib/asyncio/unix_events.py#L868
  //
  // - PidfdChildWatcher - golden standard, but only on Linux.
  // - SafeChildWatcher - waitpid(pid, os.WNOHANG) in a loop.
  // - FastChildWatcher - waitpid(-1,  os.WNOHANG) in a loop.
  // - MultiLoopChildWatcher - signals. Ugh… nope.
  // - ThreadedChildWatcher - what we have here.
  return System_ThreadedChildWatcher.create()
}

internal final class System_ThreadedChildWatcher: System_ChildWatcher {

  /// Args that we pass to the child thread.
  fileprivate struct Args {

    fileprivate let ptr: UnsafeMutablePointer<System_ThreadedChildWatcher>

    fileprivate init(_ watcher: System_ThreadedChildWatcher) {
      self.ptr = UnsafeMutablePointer<System_ThreadedChildWatcher>.allocate(capacity: 1)
      self.ptr.initialize(to: watcher)
    }

    /// Extract `System_ThreadedChildWatcher` and deallocate.
    fileprivate static func consume(_ ptr: UnsafeMutableRawPointer) -> System_ThreadedChildWatcher {
      let bind = ptr.bindMemory(to: System_ThreadedChildWatcher.self, capacity: 1)
      let result = bind.pointee
      Self.deallocate(bind)
      return result
    }

    fileprivate func deallocate() {
      Self.deallocate(self.ptr)
    }

    private static func deallocate(_ ptr: UnsafeMutablePointer<System_ThreadedChildWatcher>) {
      ptr.deinitialize(count: 1)
      ptr.deallocate()
    }
  }

  private var process: Subprocess?
  /// Synchronization primitive between us and our child.
  ///
  /// 1. Parent acquires `lock`
  /// 2. Parent forks
  /// 3. Parent sets `pid` and releases the `lock`
  /// 4. Child resumes
  private let lock = NSLock()

#if DEBUG
  private var hasResumedChild = false
#endif

  deinit {
    let pid = self.process?.pid
    let pidString = pid.map(String.init) ?? "<fork_failed>"
    print("[\(pidString)] ThreadedChildWatcher.deinit")

#if DEBUG
    assert(
      self.hasResumedChild,
      "[ThreadedChildWatcher] Missing call to resume/cancel?"
    )
#endif
  }

  internal typealias CreateResult = Result<System_ThreadedChildWatcher, InitError>

  /// [Parent] Start the `waitpid` thread.
  internal static func create() -> CreateResult {
    let watcher = System_ThreadedChildWatcher()
    let args = Args(watcher)

    // Pause the child as we do not know the 'pid' yet.
    // (The child is not even running…)
    watcher.lock.lock()

    func cleanupAndReturnError(
      _ message: String,
      _ errno: Errno? = nil
    ) -> CreateResult {
      args.deallocate()
      return .failure(InitError(
        code: .terminationWatcher,
        message: message,
        source: errno
      ))
    }

    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    defer { pthread_attr_destroy(&attr) }

    // Make it detached, so that we do not have to join it.
    var result = pthread_attr_setdetachstate(&attr, CInt(PTHREAD_CREATE_DETACHED))
    if result != 0 {
      return cleanupAndReturnError("Unable to set detach attribute", Errno.current)
    }

#if canImport(Darwin)
    var threadId: pthread_t?
    result = pthread_create(&threadId, &attr, threaded_child_watcher_fn(args:), args.ptr)
#elseif canImport(Glibc)
    var threadId: pthread_t = 0
    result = pthread_create(&threadId, &attr, threaded_child_watcher_fn_linux(args:), args.ptr)
#endif

    if result != 0 {
      return cleanupAndReturnError("Unable to start thread", Errno.current)
    }

#if canImport(Darwin)
    if threadId == nil {
      return cleanupAndReturnError("Unable to start thread: no threadId")
    }
#endif

    // We still hold the lock!
    return .success(watcher)
  }

  /// [Parent] Resume the child thread with process to `waitpid`.
  internal func resume(process: Subprocess) {
#if DEBUG
    self.hasResumedChild = true
#endif
    self.process = process
    self.lock.unlock()
  }

  /// [Parent] Resume the child thread without the process.
  internal func cancel() {
#if DEBUG
    self.hasResumedChild = true
#endif
    self.lock.unlock()
  }

  /// [Child] Wait until we know whether the `fork` succeeded.
  fileprivate func waitUntilFork() -> pid_t? {
    self.lock.lock()
    let pid = self.process?.pid
    self.lock.unlock()
    return pid
  }

  // [Child] Notify that the process has terminated.
  fileprivate func onTermination(exitStatus: CInt) {
    guard let process = self.process else {
      fatalError("[ThreadedChildWatcher] no process?")
    }

    let pid = process.pid
    print("[\(pid)] Terminated, status: \(exitStatus).")

    Task.detached {
      await process.TERMINATION_CALLBACK(exitStatus: exitStatus)
    }
  }
}

#if os(Linux)
// On Linux we have 'args: UnsafeMutableRawPointer?'.
private func threaded_child_watcher_fn_linux(
  args: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
  guard let args = args else {
    fatalError("Process wait thread: arguments without pid.")
  }

  return threaded_child_watcher_fn(args: args)
}
#endif

private func threaded_child_watcher_fn(
  args: UnsafeMutableRawPointer
) -> UnsafeMutableRawPointer? {
  let watcher = System_ThreadedChildWatcher.Args.consume(args)

  guard let pid = watcher.waitUntilFork() else {
    return nil
  }

  var isRunning = true
  var exitStatus: CInt = Subprocess.exitStatusIfWeDontKnowTheRealOne

  while isRunning {
    switch System_Waitpid(pid: pid) {
    case .tryAgain:
      break
    case .terminated(exitStatus: let s):
      exitStatus = s
      isRunning = false
    case .noChildProcess:
      isRunning = false
    }
  }

  watcher.onTermination(exitStatus: exitStatus)
  return nil
}

private enum System_Waitpid {
  case tryAgain
  case terminated(exitStatus: CInt)
  case noChildProcess

  fileprivate init(pid: pid_t) {
    var status: CInt = -1
    let result = waitpid(pid, &status, 0)
    self = Self.create(pid: pid, result: result, status: status)
  }

#if canImport(Darwin)
  private typealias Result = pid_t
#elseif canImport(Glibc)
  private typealias Result = __pid_t
#endif

  private static func create(pid: pid_t, result: Result, status: CInt) -> Self {
    switch result {
    case 0:
      // Only possible with WNOHANG.
      return .tryAgain

    case pid:
      // https://github.com/python/cpython/blob/main/Modules/posixmodule.c#L16390
      if _CLIB_WIFEXITED(status) != 0 {
        let exitStatus = _CLIB_WEXITSTATUS(status)

        // Sanity check to provide warranty on the function behavior.
        // It should not occur in practice
        if exitStatus < 0 {
          fatalError("waitpid: WEXITSTATUS < 0.")
        }

        return .terminated(exitStatus: exitStatus)
      }

      if _CLIB_WIFSIGNALED(status) != 0 {
        let signum = _CLIB_WTERMSIG(status)

        // Sanity check to provide warranty on the function behavior.
        // It should not occurs in practice
        if signum <= 0 {
          fatalError("waitpid: WTERMSIG <= 0.")
        }

        // For signals we want negative 'exitStatus'.
        return .terminated(exitStatus: -signum)
      }

      fatalError("waitpid: unknown exit status: \(status).")

    case -1:
      // https://www.man7.org/linux/man-pages/man2/waitpid.2.html
      switch Errno.current {
      case .resourceTemporarilyUnavailable:
        // EAGAIN The PID file descriptor specified in id is nonblocking and
        //        the process that it refers to has not terminated.
        return .tryAgain
      case .noChildProcess:
        // ECHILD (for waitpid() or waitid()) The process specified by pid
        //        (waitpid()) or idtype and id (waitid()) does not exist or
        //        is not a child of the calling process.  (This can happen
        //        for one's own child if the action for SIGCHLD is set to
        //        SIG_IGN. See also the Linux Notes section about threads.)
        return .noChildProcess
      case .interrupted:
        // EINTR WNOHANG was not set and an unblocked signal or a SIGCHLD
        //       was caught; see signal(7).
        return .tryAgain
      case .invalidArgument:
        // EINVAL The options argument was invalid.
        fatalError("waitpid: EINVAL.")
      case .noSuchProcess:
        // ESRCH (for wait() or waitpid()) pid is equal to INT_MIN.
        fatalError("waitpid: ESRCH.")
      default:
        fatalError("waitpid: unknown error: \(errno)")
      }
    default:
      fatalError("waitpid: unknown result \(result)")
    }
  }
}

#endif // canImport(Darwin) || canImport(Glibc)
