#if os(Linux)
import CLib
import Foundation
import SystemPackage

private struct Pipe {

  fileprivate let readEnd: FileDescriptor
  fileprivate let writeEnd: FileDescriptor

  fileprivate var bufferSize: Int {
    let result = _clib_fcntl_2(self.readEnd.rawValue, _clib_F_GETPIPE_SZ)
    assert(result >= 0)
    return Int(result)
  }

  fileprivate init(blocking: Bool) throws {
    (self.readEnd, self.writeEnd) = try FileDescriptor.pipe()

    if !blocking {
      var result = _clib_fcntl_3(self.readEnd.rawValue, F_SETFL, O_NONBLOCK)
      assert(result != -1)
      result = _clib_fcntl_3(self.writeEnd.rawValue, F_SETFL, O_NONBLOCK)
      assert(result != -1)
    }
  }

  fileprivate func write(_ elements: [UInt8]) throws {
    try self.writeEnd.writeAll(elements)
  }

  fileprivate func write(count: Int) throws -> Int? {
    do {
      let elements = [UInt8](repeating: 1, count: count)
      return try self.writeEnd.writeAll(elements)
    } catch Errno.resourceTemporarilyUnavailable, Errno.wouldBlock {
      return nil
    }
  }

  // Empty pipe returns empty `Array`.
  fileprivate func read(byteCount: Int) throws -> [UInt8] {
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 1)
    defer { buffer.deallocate() }

    do {
      let readCount = try self.readEnd.read(into: buffer)
      let readBuffer = buffer[..<readCount]
      return [UInt8](readBuffer)
    } catch Errno.resourceTemporarilyUnavailable, Errno.wouldBlock {
      return []
    }
  }

  fileprivate func closeWrite() throws {
    try self.writeEnd.close()
  }

  fileprivate func closeRead() throws {
    try self.readEnd.close()
  }
}

internal enum Pipes {

  private static func read100_fromEmpty() throws {
    print("\nread_fromEmpty")

    print("BLOCK - hangs waiting for write")
    // let block = try Pipe(blocking: true)
    // let read = try block.read(byteCount: 100)
    // print("  Read \(read.count) bytes")

    print("NONBLOCK - reads 0")
    let p = try Pipe(blocking: false)
    let read = try p.read(byteCount: 100)
    print("  Read \(read.count) bytes")
  }

  private static func write100_read100_read100() throws {
    print("\nwrite100_read100_read100")

    print("BLOCK - hangs waiting for write")
    // let p = try Pipe(blocking: true)
    // print("  Writing 100")
    // try p.write(count: 100)
    // let read1 = try p.read(byteCount: 100)
    // print("  Read1 \(read1.count) bytes")
    // let read2 = try p.read(byteCount: 100)
    // print("  Read2 \(read2.count) bytes")

    print("NONBLOCK - reads 0")
    let p = try Pipe(blocking: false)
    print("  Writing 100")
    _ = try p.write(count: 100)
    let read1 = try p.read(byteCount: 100)
    print("  Read1 \(read1.count) bytes")
    let read2 = try p.read(byteCount: 100)
    print("  Read2 \(read2.count) bytes")
  }

  private static func writeFull_closeWrite_readFull() throws {
    print("\nwriteFull_closeWrite_readFull")

    // Same result for both
    for (name, isBlocking) in [("BLOCK", true), ("NONBLOCK", false)] {
      print(name, "- reads full buffer")

      let p = try Pipe(blocking: isBlocking)
      let bufferSize = p.bufferSize

      print("  Writing \(bufferSize) bytes")
      _ = try p.write(count: bufferSize)

      print("  Closing write")
      try p.closeWrite()

      let read = try p.read(byteCount: bufferSize)
      print("  Read \(read.count) bytes")
    }
  }

  private static func writeFull_closeWrite_readMoreThanFull() throws {
    print("\nwriteFull_closeWrite_readMoreThanFull")

    // Same result for both
    for (name, isBlocking) in [("BLOCK", true), ("NONBLOCK", false)] {
      print(name, "- reads full buffer")

      let p = try Pipe(blocking: isBlocking)
      let bufferSize = p.bufferSize

      print("  Writing \(bufferSize) bytes")
      _ = try p.write(count: bufferSize)
      print("  Closing write")
      try p.closeWrite()

      let readByteCount = bufferSize + 10_000
      let read = try p.read(byteCount: readByteCount)
      print("  Read \(read.count) bytes instead of \(readByteCount)")
    }
  }

  private static func closeRead_write100_isSIGPIPE() throws {
    print("\ncloseRead_write100_isSIGPIPE")
    print("BLOCK - SIGPIPE")
    print("NONBLOCK - SIGPIPE")

/*
    let p = try Pipe(blocking: true)

    print("Closing read")
    try p.closeRead()

    print("Before write")
    _ = try p.write(count: 100)
*/
  }

  private static func writeMoreThanFull() throws {
    print("\nwriteMoreThanFull")

    print("BLOCK - hangs waiting for read")
    // let p = try Pipe(blocking: true)
    // let bufferSize = p.bufferSize
    // print("Before write")
    // _ = try p.write(count: bufferSize + 1)
    // print("After write")
    // try p.closeWrite()

    print("NONBLOCK - writes nothing, throws blocked")
    print("  READ THE DOCS! Especially the PIPE_BUF section.")

    let p = try Pipe(blocking: false)
    let bufferSize = p.bufferSize

    var byteCount = try p.write(count: bufferSize - 100)
    print(byteCount.map { "  Wrote \($0) bytes" } ?? "  Writing was BLOCKED")

    byteCount = try p.write(count: 150)
    print(byteCount.map { "  Wrote \($0) bytes" } ?? "  Writing was BLOCKED")

    var readResult = try p.read(byteCount: bufferSize)
    print("  Read \(readResult.count)/\(bufferSize) bytes \(100*readResult.count/bufferSize)%")

    readResult = try p.read(byteCount: bufferSize)
    print("  Read \(readResult.count)/\(bufferSize) bytes \(100*readResult.count/bufferSize)%")
  }

  private static func dupWriteEnd_isInfiniteLoop() throws {
    print("\ndupWriteEnd_isInfiniteLoop")
    print("BLOCK - SIGPIPE")
    print("NONBLOCK - SIGPIPE")

/*
    let (readEnd, writeEnd) = try FileDescriptor.pipe()
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 10, alignment: 1)

    // let writeEnd2 = dup(writeEnd.rawValue)
    try writeEnd.close()

    print("Before")
    while try readEnd.read(into: buffer) != 0 {}
    print("After")
*/
  }

  internal static func runAll() {
    do {
      try Self.read100_fromEmpty()
      try Self.write100_read100_read100()
      try Self.writeFull_closeWrite_readFull()
      try Self.writeFull_closeWrite_readMoreThanFull()

      try Self.closeRead_write100_isSIGPIPE()
      try Self.writeMoreThanFull()
      try Self.dupWriteEnd_isInfiniteLoop()
    } catch {
      print(error)
    }
  }
}
#endif
