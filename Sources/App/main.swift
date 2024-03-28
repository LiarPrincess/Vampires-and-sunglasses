import Lib
import Foundation
import SystemPackage

let second: UInt64 = 1_000_000_000

private func getExecutablePath(_ executableName: String) -> String {
  let dirs = [
    "/usr/bin/",
    "/bin/",
    "/usr/sbin/",
    "/sbin/",
    "/usr/local/bin/"
  ]

  for dir in dirs {
    let path = dir + executableName
    if FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
  }

  preconditionFailure("Unable to find executable: \(executableName).")
}

/// We need to find the file in the repository root. Because Xcode… ehh…
private func getFileFromRepositoryRoot(name: String) -> String {
  var dir = URL(fileURLWithPath: #file)

  while dir.path != "/" {
    dir.deleteLastPathComponent()
    let tested = dir.appendingPathComponent(name)

    if FileManager.default.fileExists(atPath: tested.path) {
      return tested.path
    }
  }

  fatalError("Unable to find '\(name)' from the repository root.")
}

print("[Parent] Start <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")

/// Helper that spawns `sleep`.
func sleep(seconds: Int) throws -> Subprocess {
  return try Subprocess(
    executablePath: getExecutablePath("sleep"),
    arguments: [String(seconds)]
  )
}

/// Other task kills the process that we wait.
func kill() async throws {
  print("\n=== Kill ===")
  let process = try sleep(seconds: 24 * 60 * 60) // 24h, lets hope it works!

  Task.detached {
    try await Task.sleep(nanoseconds: 1 * second)
    print("⚪ Different task sends kill")
    try await process.kill()
  }

  let status = try await process.waitForTermination()
  print(status == -9 ? "🟢" : "🔴", "Exit status:", status)
}

/// Just wait for the process to end.
func wait_fullSleep() async throws {
  print("\n=== Wait ===")
  let process = try sleep(seconds: 1)
  let status = try await process.waitForTermination()
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status)
}

/// Cancel `Task` that waits.
func wait_lateCancellation() async throws {
  print("\n=== Wait - late cancellation ===")
  let process = try sleep(seconds: 2)

  let cancelledTask = Task.detached {
    do {
      let status = try await process.waitForTermination()
      print("🔴 Exit status:", status, "<-- cancelled task")
    } catch {
      if error is CancellationError {
        print("🟢 Error:", error, "<-- cancelled task")
      } else {
        print("🔴 Invalid error:", error, "<-- cancelled task")
      }
    }
  }

  // Wait until it hits 'process.waitForTermination()'
  try await Task.sleep(nanoseconds: 1 * second)
  print("⚪ Cancelling task")
  cancelledTask.cancel()

  // Just sync.
  let status = try await process.waitForTermination()
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status, "<-- main task")
}

/// Many tasks wait for the process
func wait_multipleTasks() async throws {
  print("\n=== Wait - multiple tasks ===")
  let process = try sleep(seconds: 2)
  let semaphore = Semaphore()

  Task.detached {
    let status = try await process.waitForTermination()
    print(status == 0 ? "🟢" : "🔴", "Exit status:", status, "<-- task 1")
    await semaphore.signal()
  }

  Task.detached {
    let status = try await process.waitForTermination()
    print(status == 0 ? "🟢" : "🔴", "Exit status:", status, "<-- task 2")
    await semaphore.signal()
  }

  let status = try await process.waitForTermination()
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status, "<-- main task")

  try await semaphore.wait(until: 2)
}

/// Wait after the termination.
func wait_afterTermination() async throws {
  print("\n=== Wait - after termination ===")
  let process = try sleep(seconds: 2)

  print("⚪ Waiting BEFORE termination")
  let status0 = try await process.waitForTermination()
  print(status0 == 0 ? "🟢" : "🔴", "Exit status:", status0)

  print("⚪ Waiting AFTER termination")
  let status1 = try await process.waitForTermination()
  print(status1 == 0 ? "🟢" : "🔴", "Exit status:", status1)
}

private func stdin() async throws {
  print("\n=== Stdin ===")

  let process = try Subprocess(
    executablePath: getExecutablePath("wc"),
    arguments: ["-l"],
    stdin: .pipeFromParent,
    stdout: .pipeToParent
  )

  let s = "1\n2\n3"
  print("⚪ Writing:", s.replacingOccurrences(of: "\n", with: "\\n"))
  try await process.stdin.writeAll(s, encoding: .ascii)
  try await process.stdin.close()

  let result = try await process.readOutputAndWaitForTermination()

  if var stdout = String(data: result.stdout, encoding: .utf8) {
    stdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    print("⚪ For 'wc' line has to end with '\\n', we only have 2 of them")
    print(stdout == "2" ? "🟢":"🔴", "Output:", stdout)
  } else {
    print("🔴 Output: <decoding_error>")
  }

  let status = result.exitStatus
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status)
}

/// Scoped termination.
func terminateAfter() async throws {
  print("\n=== Terminate after ===")
  let process = try sleep(seconds: 24 * 60 * 60) // 24h, lets hope it works!

  try await process.terminateAfter { @Sendable in
    print("⚪ Terminate after - doing important work…")
    try await Task.sleep(nanoseconds: 3 * second)
    print("⚪ Terminate after - finished")
  }

  let status = try await process.waitForTermination()
  print(status == -15 ? "🟢" : "🔴", "Exit status:", status)
}

func executablePath_doesNotExist() async throws {
  print("\n=== Executable path - does not exist ===")

  do {
    let executablePath = "/usr/bin/404_not_found"
    _ = try Subprocess(executablePath: executablePath)
    print("🔴 We somehow executed:", executablePath)
  } catch {
    guard let initError = error as? Subprocess.InitError else {
      print("🔴 Invalid error:", error)
      return
    }

    if initError.code == .exec && (initError.source as? Errno) == Errno.noSuchFileOrDirectory {
      print("🟢", error)
    } else {
      print("🔴 Invalid init error:", error)
    }
  }
}

private func catPrideAndPrejudice(
  stdin: Subprocess.InitStdin = .none,
  stdout: Subprocess.InitStdout = .discard,
  stderr: Subprocess.InitStderr = .discard
) throws -> Subprocess {
  let executablePath = getExecutablePath("cat")
  let path = getFileFromRepositoryRoot(name: "Pride and Prejudice.txt")
  return try Subprocess(
    executablePath: executablePath,
    arguments: [path],
    stdin: stdin,
    stdout: stdout,
    stderr: stderr
  )
}

private func prideAndPrejudice_readAll() async throws {
  print("\n=== Pride and prejudice - read all ===")
  let process = try catPrideAndPrejudice(stdout: .pipeToParent)

  print("⚪ Reading stdout")
  if let s = try await process.stdout.readAll(encoding: .utf8) {
    print(s.count == 748152 ? "🟢" : "🔴", "Got \(s.count) characters")
  } else {
    print("🔴 Decoding failed?")
  }

  let status = try await process.waitForTermination()
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status)
}

private func prideAndPrejudice_discardAll() async throws {
  print("\n=== Pride and prejudice - discard all ===")
  let process = try catPrideAndPrejudice(stdout: .pipeToParent)

  print("⚪ Reading stdout discarding data")
  let result = try await process.readOutputAndWaitForTermination(
    collectStdout: false,
    collectStderr: false
  )

  print(result.stdout.isEmpty ? "🟢" : "🔴", "stdout.count:", result.stdout.count)
  print(result.stderr.isEmpty ? "🟢" : "🔴", "stderr.count:", result.stderr.count)

  let status = result.exitStatus
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status)
}

private func prideAndPrejudice_deadlockWhenPipeIsFull() async throws {
  print("\n=== Pride and prejudice - deadlock when pipe is full ===")
  print("⚪ Uncomment the code below…")

/*
  let process = try catPrideAndPrejudice(stdout: .pipe)
  let status = try await process.waitForTermination() // Hangs
*/
}

private func prideAndPrejudice_copy() async throws {
  print("\n=== Pride and prejudice - copy ===")

  let fileName = "Pride and Prejudice - copy.txt"
  print("⚪ Writing to: \(fileName)")

  let file = try FileDescriptor.open(
    fileName,
    .writeOnly,
    options: .create,
    permissions: [.ownerReadWrite, .otherReadWrite, .groupReadWrite]
  )

  let process = try catPrideAndPrejudice(
    stdout: .writeToFile(file)
  )

  let status = try await process.waitForTermination()
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status)
}

private func prideAndPrejudice_cat_grep_wc() async throws {
  print("\n=== Pride and prejudice - cat | grep | wc ===")

  let path = getFileFromRepositoryRoot(name: "Pride and Prejudice.txt")
  let catToGrep = try FileDescriptor.pipe()
  let grepToWc = try FileDescriptor.pipe()

  // Start the child process. It DOES NOT block waiting for it finish.
  // Use 'waitForTermination' methods for synchronization.
  _ = try Subprocess(
    executablePath: getExecutablePath("cat"),
    arguments: [path],
    stdout: .writeToFile(catToGrep.writeEnd) // close by default
  )

  _ = try Subprocess(
    executablePath: getExecutablePath("grep"),
    arguments: ["-o", "Elizabeth"],
    stdin: .readFromFile(catToGrep.readEnd),
    stdout: .writeToFile(grepToWc.writeEnd)
  )

  let wc = try Subprocess(
    executablePath: getExecutablePath("wc"),
    arguments: ["-l"],
    stdin: .readFromFile(grepToWc.readEnd),
    stdout: .pipeToParent
  )

  print("⚪ wc -> read all and wait for termination")
  let result = try await wc.readOutputAndWaitForTermination()

  if var stdout = String(data: result.stdout, encoding: .utf8) {
    stdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    print(stdout == "645" ? "🟢" : "🔴", "Output:", stdout)
  } else {
    print("🔴 Output: <decoding_error>")
  }

  let status = result.exitStatus
  print(status == 0 ? "🟢" : "🔴", "Exit status:", status)
}

try await kill()

try await wait_fullSleep()
try await wait_lateCancellation()
try await wait_multipleTasks()
try await wait_afterTermination()

try await stdin()
try await terminateAfter()
try await executablePath_doesNotExist()

try await prideAndPrejudice_readAll()
try await prideAndPrejudice_discardAll()
try await prideAndPrejudice_deadlockWhenPipeIsFull()
try await prideAndPrejudice_copy()
try await prideAndPrejudice_cat_grep_wc()

// Pipes.runAll()

print("[Parent] End <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
