/*
public struct Subprocess2 {

  private let _executable: Executable
  public var arguments: Arguments
  public var environment: Environment
  public var workingDirectory: FilePath?
  public var platformOptions: PlatformOptions

  public var executable: String {
    switch self._executable.storage {
    case let .executable(name): return name
    case let .path(path): return path.string
    }
  }

  /// PATH lookup
  public init(
    executableName: String,
    arguments: Arguments = Arguments(),
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = .default
  ) {
    self._executable = .named(executableName)
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.platformOptions = platformOptions
  }

  /// Absolute/relative path
  public init(
    executablePath: FilePath,
    arguments: Arguments = Arguments(),
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = .default
  ) {
    self._executable = .at(executablePath)
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.platformOptions = platformOptions
  }

  public func runCollectingOutput(
    input: InputMethod = .noInput,
    output: CollectedOutputMethod = .collect,
    error: CollectedOutputMethod = .collect
  ) async throws -> CollectedResult {
    fatalError()
  }

  public func runCollectingOutput(
    input: some Sequence<UInt8>,
    output: CollectedOutputMethod = .collect,
    error: CollectedOutputMethod = .collect
  ) async throws -> CollectedResult {
    fatalError()
  }

  public func runCollectingOutput<S: AsyncSequence>(
    input: S,
    output: CollectedOutputMethod = .collect,
    error: CollectedOutputMethod = .collect
  ) async throws -> CollectedResult where S.Element == UInt8 {
    fatalError()
  }

  // This name sux.
  // I also renamed 'Subprocess' to 'RunningSubprocess' in 'body'.
  public func runInteractively<R>(
    input: InputMethod = .noInput,
    output: RedirectedOutputMethod = .redirect,
    error: RedirectedOutputMethod = .discard,
    _ body: (@Sendable @escaping (RunningSubprocess) async throws -> R)
  ) async throws -> Result<R> {
    fatalError()
  }

  public func runInteractively<R>(
    input: some Sequence<UInt8>,
    output: RedirectedOutputMethod = .redirect,
    error: RedirectedOutputMethod = .discard,
    _ body: (@Sendable @escaping (RunningSubprocess) async throws -> R)
  ) async throws -> Result<R> {
    fatalError()
  }

  public func runInteractively<R, S: AsyncSequence>(
    input: S,
    output: RedirectedOutputMethod = .redirect,
    error: RedirectedOutputMethod = .discard,
    _ body: (@Sendable @escaping (RunningSubprocess) async throws -> R)
  ) async throws -> Result<R> where S.Element == UInt8 {
    fatalError()
  }
}
*/
