/*
private struct File: ~Copyable {
  let raw: Int
}

private func borrow(_ f: borrowing File) {}
private func consume(_ f: consuming File) {}

private struct CollectedOutputMethodXxx: ~Copyable {
  private enum Storage: ~Copyable, Sendable {
    case discarded
    case consuming(File)
    case borrowing(File)
    case collected(Int)
  }

  private let raw: Storage

  fileprivate static func writeAndClose(_ f: consuming File) -> CollectedOutputMethodXxx {
    return CollectedOutputMethodXxx(raw: .consuming(f))
  }

  fileprivate static func write(_ f: borrowing File) -> CollectedOutputMethodXxx {
    let copy = File(raw: f.raw)
    return CollectedOutputMethodXxx(raw: .borrowing(copy))
  }
}

private func ala() {
  func run(stdout: consuming CollectedOutputMethodXxx) {}

  let f1 = File(raw: 0)
  run(stdout: .writeAndClose(f1))
  // print(f1.raw)

  let f2 = File(raw: 0)
  run(stdout: .write(f2))
  print(f2.raw)
}
*/
