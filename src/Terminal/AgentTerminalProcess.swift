import Darwin
import Foundation

public struct AgentTerminalViewport: Equatable, Sendable {
    public var columns: UInt32
    public var rows: UInt32
    public var widthPixels: UInt32
    public var heightPixels: UInt32

    public init(columns: UInt32, rows: UInt32, widthPixels: UInt32 = 0, heightPixels: UInt32 = 0) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

public enum AgentTerminalProcessError: Error, Equatable {
    case emptyCommand
    case launchFailed(errno: Int32)
}

public final class AgentTerminalProcess: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (Data) -> Void
    public typealias ExitHandler = @Sendable (Int32?) -> Void

    private let command: [String]
    private let workingDirectory: URL
    private let environment: [String: String]
    private let outputHandler: OutputHandler
    private let exitHandler: ExitHandler
    private let readQueue: DispatchQueue
    private let lock = NSLock()

    private var masterFileDescriptor: Int32 = -1
    private var childPID: pid_t = -1
    private var started = false
    private var finished = false

    public init(
        command: [String],
        workingDirectory: URL,
        environment: [String: String],
        output: @escaping OutputHandler,
        onExit: @escaping ExitHandler = { _ in }
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.outputHandler = output
        self.exitHandler = onExit
        self.readQueue = DispatchQueue(
            label: "dev.dopsonbr.yaaw.agent-terminal-process.\(UUID().uuidString)",
            qos: .userInitiated
        )
    }

    deinit {
        terminate()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !finished
    }

    public func start(initialViewport: AgentTerminalViewport? = nil) throws {
        lock.lock()
        if started {
            lock.unlock()
            if let initialViewport {
                resize(to: initialViewport)
            }
            return
        }
        started = true
        lock.unlock()

        guard !command.isEmpty else {
            markFinished()
            throw AgentTerminalProcessError.emptyCommand
        }

        let argvStorage = command.map { strdup($0) }
        var argv = argvStorage + [nil]
        let environmentEntries = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let environmentStorage = environmentEntries.map { strdup($0) }
        var envp = environmentStorage + [nil]
        let cwd = strdup(workingDirectory.path)
        defer {
            argvStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
            free(cwd)
        }

        var master: Int32 = -1
        var windowSize = winsize(
            ws_row: UInt16(clamping: Int(initialViewport?.rows ?? 24)),
            ws_col: UInt16(clamping: Int(initialViewport?.columns ?? 80)),
            ws_xpixel: UInt16(clamping: Int(initialViewport?.widthPixels ?? 0)),
            ws_ypixel: UInt16(clamping: Int(initialViewport?.heightPixels ?? 0))
        )
        let pid = forkpty(&master, nil, nil, &windowSize)
        guard pid >= 0 else {
            markFinished()
            throw AgentTerminalProcessError.launchFailed(errno: errno)
        }

        if pid == 0 {
            _ = setpgid(0, 0)
            if let cwd {
                _ = chdir(cwd)
            }
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    if command[0].contains("/") {
                        execve(argvBuffer[0], argvBuffer.baseAddress, envBuffer.baseAddress)
                    }
                    execvp(argvBuffer[0], argvBuffer.baseAddress)
                }
            }
            _exit(127)
        }

        _ = setpgid(pid, pid)
        lock.lock()
        masterFileDescriptor = master
        childPID = pid
        lock.unlock()

        if let initialViewport {
            resize(to: initialViewport)
        }

        let readMasterFileDescriptor = master
        readQueue.async { [weak self] in
            self?.readLoop(masterFileDescriptor: readMasterFileDescriptor, childPID: pid)
        }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = currentMasterFileDescriptor()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written <= 0 {
                    break
                }
                offset += written
            }
        }
    }

    public func resize(to viewport: AgentTerminalViewport) {
        let fd = currentMasterFileDescriptor()
        guard fd >= 0, viewport.columns > 0, viewport.rows > 0 else { return }
        var windowSize = winsize(
            ws_row: UInt16(clamping: Int(viewport.rows)),
            ws_col: UInt16(clamping: Int(viewport.columns)),
            ws_xpixel: UInt16(clamping: Int(viewport.widthPixels)),
            ws_ypixel: UInt16(clamping: Int(viewport.heightPixels))
        )
        _ = ioctl(fd, TIOCSWINSZ, &windowSize)
        let pid = currentChildPID()
        if pid > 0 {
            _ = kill(-pid, SIGWINCH)
            _ = kill(pid, SIGWINCH)
        }
    }

    public func terminate() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pid = childPID
        let fd = masterFileDescriptor
        masterFileDescriptor = -1
        lock.unlock()

        if pid > 0 {
            _ = kill(-pid, SIGHUP)
            _ = kill(pid, SIGHUP)
            _ = kill(-pid, SIGTERM)
            _ = kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
        }
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    private func readLoop(masterFileDescriptor fd: Int32, childPID pid: pid_t) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                outputHandler(Data(buffer.prefix(count)))
            } else {
                break
            }
        }

        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        markFinished(masterFileDescriptor: fd)
        exitHandler(Self.exitCode(from: status))
    }

    private func currentMasterFileDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return masterFileDescriptor
    }

    private func currentChildPID() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return childPID
    }

    private func markFinished(masterFileDescriptor fd: Int32? = nil) {
        lock.lock()
        let shouldClose = fd != nil && masterFileDescriptor == fd
        if shouldClose {
            masterFileDescriptor = -1
        }
        finished = true
        lock.unlock()
        if shouldClose, let fd {
            _ = Darwin.close(fd)
        }
    }

    private static func exitCode(from status: Int32) -> Int32? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        if signal != 0x7f {
            return 128 + signal
        }
        return nil
    }
}
