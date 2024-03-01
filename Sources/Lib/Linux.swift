#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import CLib
import Foundation
import SystemPackage

// swiftlint:disable function_parameter_count
// swiftlint:disable cyclomatic_complexity
// swiftlint:disable function_body_length

#if os(macOS)
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
) -> Result<pid_t, Errno> {
  func cleanupAndThrow(errno: CInt) -> Result<pid_t, Errno> {
    return .failure(Errno(rawValue: errno))
  }

  // ============
  // === Argv ===
  // ============

  var argv = [UnsafeMutablePointer<CChar>?]()
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

  var env: [UnsafeMutablePointer<CChar>?] = []
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
  // === Files ===
  // =============

#if os(macOS)
  var fileActions: posix_spawn_file_actions_t?
#elseif os(Linux)
  var fileActions = posix_spawn_file_actions_t()
#endif

  posix_spawn_file_actions_init(&fileActions)
  defer { posix_spawn_file_actions_destroy(&fileActions) }

  var result = posix_spawn_file_actions_adddup2(&fileActions, stdin.rawValue, 0)
  if result != 0 {
    return cleanupAndThrow(errno: result)
  }

  result = posix_spawn_file_actions_adddup2(&fileActions, stdout.rawValue, 1)
  if result != 0 {
    return cleanupAndThrow(errno: result)
  }

  result = posix_spawn_file_actions_adddup2(&fileActions, stderr.rawValue, 2)
  if result != 0 {
    return cleanupAndThrow(errno: result)
  }

// TODO: For other files: fcntl(fd, F_SETFD, FD_CLOEXEC);
// https://stackoverflow.com/questions/21950549/close-all-file-handles-when-calling-posix-spawn

  // ==================
  // === Attributes ===
  // ==================

#if os(macOS)
  var spawnAttributes: posix_spawnattr_t?
#elseif os(Linux)
  var spawnAttributes = posix_spawnattr_t()
#endif

  posix_spawnattr_init(&spawnAttributes)
  defer { posix_spawnattr_destroy(&spawnAttributes) }

  // Set blocked signals to none.
  var signalBlocked = sigset_t()
  sigemptyset(&signalBlocked)
  result = posix_spawnattr_setsigmask(&spawnAttributes, &signalBlocked)

  if result != 0 {
    return cleanupAndThrow(errno: result)
  }

  // Set signal handling to default.
  var signalDefault = sigset_t()
  sigfillset(&signalDefault)
  result = posix_spawnattr_setsigdefault(&spawnAttributes, &signalDefault)

  if result != 0 {
    return cleanupAndThrow(errno: result)
  }

  // | POSIX_SPAWN_CLOEXEC_DEFAULT
  let flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
  result = posix_spawnattr_setflags(&spawnAttributes, Int16(flags))

  if result != 0 {
    return cleanupAndThrow(errno: result)
  }

// TODO: QualityOfService
// TODO: CWD

  // =============
  // === Spawn ===
  // =============

  var pid: pid_t = 0

  // Sometimes we need to fork-exec, but for our simple needs we can:
  result = executablePath.withCString { exePath in
    posix_spawn(&pid, exePath, &fileActions, &spawnAttributes, argv, env)
  }

  if result != 0 {
    return cleanupAndThrow(errno: result)
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
  let result = _clib_fcntl_3(writeEnd.rawValue, _clib_F_SETPIPE_SZ, sizeInBytes)

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

/// Uppercase because Death SPEAKS IN UPPERCASE.
/// https://en.wikipedia.org/wiki/Death_(Discworld)
internal func SYSTEM_WAIT_FOR_TERMINATION_IN_BACKGROUND(process: Subprocess) {
  Task.detached {
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
    await ThreadedMort.startWaiting(for: process)
  }
}

/// Mort is a Death helper.
/// Mort does not speak in uppercase.
/// (Unless Mort takes Death duties, but that's a spoiler.)
@MainActor
private enum ThreadedMort {

  private struct SubprocessInfo {
    fileprivate let process: Subprocess
    fileprivate let threadId: pthread_t
  }

  private static var pidToInfo = [pid_t: SubprocessInfo]()

  fileprivate static func startWaiting(for process: Subprocess) {
    let pid = process.pid
    print("[\(pid)] Starting termination watcher.")

    let args = UnsafeMutablePointer<pid_t>.allocate(capacity: 1)
    args.initialize(to: process.pid)

// TODO: Things here may not be correct. Review later.
// TODO: Low priority/QoS? This leads to priority inversion, but it is implied anyway.

#if os(macOS)
    var threadId: pthread_t?
    let result = pthread_create(&threadId, nil, threadedMort_waitFn(args:), args)
#elseif os(Linux)
    var threadId: pthread_t = 0
    let result = pthread_create(&threadId, nil, threadedMort_waitFn_linux(args:), args)
#endif

    if result != 0 {
      fatalError("Process wait thread: creation failed.")
    }

#if os(macOS)
    guard let threadId = threadId else {
      fatalError("Process wait thread: creation failed - no threadId.")
    }
#endif

    Self.pidToInfo[pid] = SubprocessInfo(process: process, threadId: threadId)
  }

  fileprivate static func callProcessTerminationCallback(pid: pid_t, exitStatus: CInt) async {
    print("[\(pid)] Terminated, status: \(exitStatus).")

    guard let info = Self.pidToInfo[pid] else {
      fatalError("Process wait thread: no process?")
    }

    // We no longer wait for the process.
    Self.pidToInfo[pid] = nil

    // Mort assumes the duties of Death. (Spoiler!)
    await info.process.TERMINATION_CALLBACK(exitStatus: exitStatus)

    // 'join' duration should be ~650 ns
    // let start = DispatchTime.now()
    var result: UnsafeMutableRawPointer?
    pthread_join(info.threadId, &result)
    // let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    // print("[\(pid)] 'waitpid' thread: joined in \(duration) ns.")
  }
}

#if os(Linux)
// On Linux we have 'args: UnsafeMutableRawPointer?'.
private func threadedMort_waitFn_linux(args: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  guard let args = args else {
    fatalError("Process wait thread: arguments without pid.")
  }

  return threadedMort_waitFn(args: args)
}
#endif

private func threadedMort_waitFn(args: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  let pidPtr = args.bindMemory(to: pid_t.self, capacity: 1)
  let pid = pidPtr.pointee

  var exitStatus: CInt = Subprocess.exitStatusIfWeDontKnowTheRealOne
  var isRunning = true

  while isRunning {
    var status: CInt = -1
    let result = waitpid(pid, &status, 0)

    switch result {
    case 0:
      // No change
      break

    case pid:
      // https://github.com/python/cpython/blob/main/Modules/posixmodule.c#L16390
      isRunning = false

      if _clib_WIFEXITED(status) != 0 {
        exitStatus = _clib_WEXITSTATUS(status)

        // Sanity check to provide warranty on the function behavior.
        // It should not occur in practice
        if exitStatus < 0 {
          fatalError("Process wait thread: WEXITSTATUS < 0.")
        }
      } else if _clib_WIFSIGNALED(status) != 0 {
        let signum = _clib_WTERMSIG(status)

        // Sanity check to provide warranty on the function behavior.
        // It should not occurs in practice
        if signum <= 0 {
          fatalError("Process wait thread: WTERMSIG <= 0.")
        }

        exitStatus = -signum
      } else {
        fatalError("Process wait thread: unknown exit status: \(status).")
      }

    case -1:
      // https://www.man7.org/linux/man-pages/man2/waitpid.2.html
      switch Errno.current {
      case .resourceTemporarilyUnavailable:
        // EAGAIN The PID file descriptor specified in id is nonblocking and
        //        the process that it refers to has not terminated.
        break
      case .noChildProcess:
        // ECHILD (for waitpid() or waitid()) The process specified by pid
        //        (waitpid()) or idtype and id (waitid()) does not exist or
        //        is not a child of the calling process.  (This can happen
        //        for one's own child if the action for SIGCHLD is set to
        //        SIG_IGN.  See also the Linux Notes section about threads.)
        isRunning = false
      case .interrupted:
        // EINTR WNOHANG was not set and an unblocked signal or a SIGCHLD
        //       was caught; see signal(7).
        isRunning = false
      case .invalidArgument:
        // EINVAL The options argument was invalid.
        fatalError("Process wait thread: waitpid -> EINVAL.")
      case .noSuchProcess:
        // ESRCH (for wait() or waitpid()) pid is equal to INT_MIN.
        fatalError("Process wait thread: waitpid -> ESRCH.")
      default:
        fatalError("Process wait thread: unknown waitpid errno: \(errno)")
      }
    default:
      fatalError("Process wait thread: unknown waitpid result: \(result)")
    }
  }

  let exitStatusCapture = exitStatus
  Task.detached {
    await ThreadedMort.callProcessTerminationCallback(pid: pid, exitStatus: exitStatusCapture)
  }

  return nil
}
