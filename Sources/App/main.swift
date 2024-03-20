import Lib
import Foundation
import SystemPackage

#if os(macOS)
let bin = "/bin"
#elseif os(Linux)
let bin = "/usr/bin"
#endif

// On macOS some executables (wc, grep) are in '/usr/bin'.
let usr_bin = "/usr/bin"

let second: UInt64 = 1_000_000_000

print("[Parent] Start <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")

/// Helper that spawns `sleep`.
func sleep(seconds: Int) throws -> Subprocess {
  return try Subprocess(
    executablePath: "\(bin)/sleep",
    arguments: [String(seconds)]
  )
}

/// Other task kills the process that we wait.
func kill() async throws {
  print("\n=== kill ===")
  let process = try sleep(seconds: 24 * 60 * 60) // 24h, lets hope it works!

  Task.detached {
    try await Task.sleep(nanoseconds: 1 * second)
    print("Different task sends kill")
    try await process.kill()
  }

  let status = try await process.waitForTermination()
  print("Exit status:", status)
  assert(status == -9)
}

/// Just wait for the process to end.
func wait_fullSleep() async throws {
  print("\n=== wait ===")
  let process = try sleep(seconds: 1)
  let status = try await process.waitForTermination()
  print("Exit status:", status)
  assert(status == 0)
}

/// Cancel `Task` that waits.
func wait_lateCancellation() async throws {
  print("\n=== wait - late cancellation ===")
  let process = try sleep(seconds: 2)

  let cancelledTask = Task.detached {
    let status = try? await process.waitForTermination()
    print("Exit status:", status.map(String.init) ?? "nil", "<-- cancelled task")
    assert(status == nil)
  }

  // Wait until it hits 'process.waitForTermination()'
  try await Task.sleep(nanoseconds: 1 * second)
  print("Cancelling task")
  cancelledTask.cancel()

  // Just sync.
  let status = try await process.waitForTermination()
  print("Exit status:", status, "<-- main task")
  assert(status == 0)
}

/// Many tasks wait for the process
func wait_multipleTasks() async throws {
  print("\n=== wait - multiple tasks ===")
  let process = try sleep(seconds: 2)
  let semaphore = Semaphore()

  Task.detached {
    let status = try await process.waitForTermination()
    print("Exit status:", status, "<-- task 1")
    assert(status == 0)
    await semaphore.signal()
  }

  Task.detached {
    let status = try await process.waitForTermination()
    print("Exit status:", status, "<-- task 2")
    assert(status == 0)
    await semaphore.signal()
  }

  let status = try await process.waitForTermination()
  print("Exit status:", status, "<-- main task")
  assert(status == 0)

  try await semaphore.wait(until: 2)
}

/// Wait after the termination.
func wait_afterTermination() async throws {
  print("\n=== wait - after termination ===")
  let process = try sleep(seconds: 2)

  print("Waiting BEFORE termination")
  let status0 = try await process.waitForTermination()
  print("Exit status:", status0)
  assert(status0 == 0)

  print("Waiting AFTER termination")
  let status1 = try await process.waitForTermination()
  print("Exit status:", status1)
  assert(status1 == 0)
}

/// Scoped termination.
func terminateAfter() async throws {
  print("\n=== terminateAfter ===")
  let process = try sleep(seconds: 24 * 60 * 60) // 24h, lets hope it works!

  try await process.terminateAfter { @Sendable in
    print("Terminate after - doing important work…")
    try await Task.sleep(nanoseconds: 3 * second)
    print("Terminate after - finished")
  }

  let status = try await process.waitForTermination()
  print("Exit status:", status)
  assert(status == -15)
}

func executablePath_doesNotExist() async throws {
  print("\n=== executable path - does not exist ===")

  do {
    let executablePath = "\(bin)/404_not_found"
    _ = try Subprocess(executablePath: executablePath)
    print("We somehow executed:", executablePath)
    assert(false, executablePath)
  } catch {
    print("Error (as expected):", error)
  }
}

private func stdin() async throws {
  print("\n=== stdin ===")

  let process = try Subprocess(
    executablePath: "\(usr_bin)/wc",
    arguments: ["-l"],
    stdin: .pipeFromParent,
    stdout: .pipeToParent
  )

  let s = "1\n2\n3"
  print("Writing:", s.replacingOccurrences(of: "\n", with: "\\n"))
  try await process.stdin.writeAll(s, encoding: .ascii)
  try await process.stdin.close()

  let result = try await process.readOutputAndWaitForTermination()

  if var stdout = String(data: result.stdout, encoding: .utf8) {
    stdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    print("For 'wc' line has to end with '\\n', we only have 2 of them")
    print("Output:", stdout)
    assert(stdout == "2")
  } else {
    print("Output: <decoding_error>")
  }

  let status = result.exitStatus
  print("Exit status:", status)
  assert(status == 0)
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

private func catPrideAndPrejudice(
  stdin: Subprocess.InitStdin = .none,
  stdout: Subprocess.InitStdout = .discard,
  stderr: Subprocess.InitStderr = .discard
) throws -> Subprocess {
  let path = getFileFromRepositoryRoot(name: "Pride and Prejudice.txt")
  return try Subprocess(
    executablePath: "\(bin)/cat",
    arguments: [path],
    stdin: stdin,
    stdout: stdout,
    stderr: stderr
  )
}

private func prideAndPrejudice_readAll() async throws {
  print("\n=== Pride and prejudice - Read all ===")
  let process = try catPrideAndPrejudice(stdout: .pipeToParent)

  print("Read all")
  if let s = try await process.stdout.readAll(encoding: .utf8) {
    print("Got \(s.count) characters")
  } else {
    print("Decoding failed?")
  }

  let status = try await process.waitForTermination()
  print("Exit status:", status)
  assert(status == 0)
}

private func prideAndPrejudice_discardAndWait() async throws {
  print("\n=== Pride and prejudice - Discard and wait ===")
  let process = try catPrideAndPrejudice(stdout: .pipeToParent)

  print("readOutputAndWaitForTermination(discard reads)")
  let result = try await process.readOutputAndWaitForTermination(
    collectStdout: false,
    collectStderr: false
  )

  print("stdout.count:", result.stdout.count)
  print("stderr.count:", result.stderr.count)

  let status = result.exitStatus
  print("Exit status:", status)
  assert(status == 0)
}

private func prideAndPrejudice_deadlockWhenPipeIsFull() async throws {
  print("\n=== Pride and prejudice - Deadlock when pipe is full ===")
  print("Uncomment the code below…")

/*
  let process = try catPrideAndPrejudice(stdout: .pipe)
  let status = try await process.waitForTermination() // Hangs
*/
}

private func prideAndPrejudice_copy() async throws {
  print("\n=== Pride and prejudice - Copy ===")

  let fileName = "Pride and Prejudice - copy.txt"
  print("Writing to: \(fileName)")

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
  print("Exit status:", status)
  assert(status == 0)
}

private func prideAndPrejudice_cat_grep_wc() async throws {
  print("\n=== Pride and prejudice - cat | grep | wc ===")

  let path = getFileFromRepositoryRoot(name: "Pride and Prejudice.txt")
  let catToGrep = try FileDescriptor.pipe()
  let grepToWc = try FileDescriptor.pipe()

  // Start the child process. It DOES NOT block waiting for it finish.
  // Use 'waitForTermination' methods for synchronization.
  _ = try Subprocess(
    executablePath: "\(bin)/cat",
    arguments: [path],
    stdout: .writeToFile(catToGrep.writeEnd) // close by default
  )

  _ = try Subprocess(
    executablePath: "\(usr_bin)/grep",
    arguments: ["-o", "Elizabeth", path],
    stdin: .readFromFile(catToGrep.readEnd),
    stdout: .writeToFile(grepToWc.writeEnd)
  )

  let wc = try Subprocess(
    executablePath: "\(usr_bin)/wc",
    arguments: ["-l"],
    stdin: .readFromFile(grepToWc.readEnd),
    stdout: .pipeToParent
  )

  print("wc.readOutputAndWaitForTermination()")
  let result = try await wc.readOutputAndWaitForTermination()
  if var stdout = String(data: result.stdout, encoding: .utf8) {
    stdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    print("Output:", stdout)
    assert(stdout == "645")
  } else {
    print("Output: <decoding_error>")
  }

  let status = result.exitStatus
  print("Exit status:", status)
  assert(status == 0)
}

try await kill()

try await wait_fullSleep()
try await wait_lateCancellation()
try await wait_multipleTasks()
try await wait_afterTermination()

try await terminateAfter()
try await executablePath_doesNotExist()

try await stdin()

try await prideAndPrejudice_readAll()
try await prideAndPrejudice_discardAndWait()
try await prideAndPrejudice_deadlockWhenPipeIsFull()
try await prideAndPrejudice_copy()
try await prideAndPrejudice_cat_grep_wc()

// Pipes.runAll()

print("[Parent] End <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
