/// In some examples we have to wait for detached tasks to finish.
actor Semaphore {
  private var value = 0

  func signal() {
    self.value += 1
  }

  func wait(until target: Int) async throws {
    while true {
      if self.value == target {
        break
      }

      let millisecond: UInt64 = 1_000_000
      try await Task.sleep(nanoseconds: 200 * millisecond)
    }
  }
}
