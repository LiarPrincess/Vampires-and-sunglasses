import Foundation

public struct Signal: Hashable, Sendable {
    public let rawValue: Int32

    private init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static var interrupt: Self { .init(rawValue: SIGINT) }
    public static var terminate: Self { .init(rawValue: SIGTERM) }
    public static var suspend: Self { .init(rawValue: SIGSTOP) }
    public static var resume: Self { .init(rawValue: SIGCONT) }
    public static var kill: Self { .init(rawValue: SIGKILL) }
    public static var terminalClosed: Self { .init(rawValue: SIGHUP) }
    public static var quit: Self { .init(rawValue: SIGQUIT) }
    public static var userDefinedOne: Self { .init(rawValue: SIGUSR1) }
    public static var userDefinedTwo: Self { .init(rawValue: SIGUSR2) }
    public static var alarm: Self { .init(rawValue: SIGALRM) }
    public static var windowSizeChange: Self { .init(rawValue: SIGWINCH) }
}
