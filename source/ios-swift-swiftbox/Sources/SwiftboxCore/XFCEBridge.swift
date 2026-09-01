import Foundation

/// Configuration for the **real-XFCE bridge** (ROADMAP Phase 6.4): the values
/// that shape the host `Xvnc` + `xfce4-session` launch a `swiftbox` desktop
/// delegates to where native exec is permitted (desktop / WSL).
public struct XFCEBridgeConfig: Equatable, Sendable {
    /// X display number (`:N`).
    public var display: Int
    public var width: Int
    public var height: Int
    public var depth: Int
    /// RFB/VNC port the X server listens on (conventionally `5900 + display`).
    public var rfbPort: Int
    /// The session/desktop command to launch against the X server.
    public var sessionCommand: [String]
    /// Candidate VNC X-server binaries, tried in order; the first the host can
    /// run is used.
    public var serverCandidates: [String]
    /// Extra environment variables to pass to the session (merged over `DISPLAY`).
    public var extraEnvironment: [String: String]

    public init(
        display: Int = 1,
        width: Int = 1280,
        height: Int = 800,
        depth: Int = 24,
        rfbPort: Int? = nil,
        sessionCommand: [String] = ["xfce4-session"],
        serverCandidates: [String] = ["Xvnc", "Xtigervnc"],
        extraEnvironment: [String: String] = [:]
    ) {
        self.display = display
        self.width = width
        self.height = height
        self.depth = depth
        self.rfbPort = rfbPort ?? (5900 + display)
        self.sessionCommand = sessionCommand
        self.serverCandidates = serverCandidates
        self.extraEnvironment = extraEnvironment
    }

    /// The `:N` display string.
    public var displayString: String { ":\(display)" }
    /// The `WxH` geometry string.
    public var geometry: String { "\(width)x\(height)" }
}

public enum XFCEBridgeError: Error, Equatable {
    /// No candidate VNC X server is runnable on this host.
    case serverUnavailable([String])
    /// The session command is not runnable on this host.
    case sessionUnavailable(String)
}

/// Bridges a `swiftbox desktop` to a **real** XFCE running under a host VNC X
/// server, the way people run XFCE on Termux (`vncserver` + `xfce4-session`).
///
/// This is the Phase 6.4 escape hatch *for platforms that allow native exec*
/// (desktop / WSL): instead of the pure-Swift compositor, delegate to the
/// genuine Xorg/GTK XFCE stack via the existing ``NativeProcessRunner`` seam
/// (the same one `--host-exec` uses). It is **gated off on stock iOS**, which
/// cannot exec and uses the built-in pure-Swift desktop instead.
///
/// The type is pure Swift over the seam, so the launch *plan* is reproducible
/// and unit-tested with a recording runner; the bundled CLI supplies the real
/// `HostProcessRunner`.
public final class XFCEBridge {
    public let config: XFCEBridgeConfig
    private let runner: NativeProcessRunner

    public init(runner: NativeProcessRunner, config: XFCEBridgeConfig = XFCEBridgeConfig()) {
        self.runner = runner
        self.config = config
    }

    /// The first server candidate the host can actually run, or `nil` if none
    /// (e.g. stock iOS, or a desktop without a VNC X server installed).
    public func availableServer() -> String? {
        config.serverCandidates.first { runner.canRun(ProcessInvocation(arguments: [$0])) }
    }

    /// Whether the configured session command is runnable on this host.
    public func sessionAvailable() -> Bool {
        guard let head = config.sessionCommand.first else { return false }
        return runner.canRun(ProcessInvocation(arguments: [head]))
    }

    /// Whether a full real-XFCE launch is possible here (a server **and** the
    /// session are runnable). When false, the caller should fall back to the
    /// built-in pure-Swift desktop.
    public func isAvailable() -> Bool {
        availableServer() != nil && sessionAvailable()
    }

    /// The X-server invocation for `server` on the configured display.
    public func serverInvocation(server: String) -> ProcessInvocation {
        ProcessInvocation(arguments: [
            server, config.displayString,
            "-geometry", config.geometry,
            "-depth", "\(config.depth)",
            "-rfbport", "\(config.rfbPort)",
        ])
    }

    /// The session invocation, with `DISPLAY` (and any extra env) set so it
    /// attaches to the bridge's X server.
    public func sessionInvocation() -> ProcessInvocation {
        var env = config.extraEnvironment
        env["DISPLAY"] = config.displayString
        return ProcessInvocation(arguments: config.sessionCommand, environment: env)
    }

    /// The ordered launch plan (server then session), or `nil` if no server is
    /// available. Pure — issues no processes; used for inspection and tests.
    public func plan() -> [ProcessInvocation]? {
        guard let server = availableServer() else { return nil }
        return [serverInvocation(server: server), sessionInvocation()]
    }

    /// The result of a real-XFCE launch.
    public struct LaunchResult: Equatable {
        public let server: String
        public let rfbPort: Int
        public let display: String
    }

    /// Launch the real XFCE stack via the runner: start the VNC X server, then
    /// the session attached to it. Throws ``XFCEBridgeError`` when the host lacks
    /// the tools (so the caller falls back to the built-in desktop).
    ///
    /// Intended for a runner whose server binary self-daemonizes (e.g.
    /// `vncserver`) or that backgrounds long-lived processes; the bundled CLI
    /// supplies such a runner. The session may run in the foreground.
    @discardableResult
    public func launch() throws -> LaunchResult {
        guard let server = availableServer() else {
            throw XFCEBridgeError.serverUnavailable(config.serverCandidates)
        }
        guard sessionAvailable() else {
            throw XFCEBridgeError.sessionUnavailable(config.sessionCommand.first ?? "")
        }
        _ = try runner.run(serverInvocation(server: server))
        _ = try runner.run(sessionInvocation())
        return LaunchResult(server: server, rfbPort: config.rfbPort, display: config.displayString)
    }
}
