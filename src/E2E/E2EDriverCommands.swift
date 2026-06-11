import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Headless e2e driver subcommands. Unlike System Events keystrokes and
/// region screenshots, these work without the target app being frontmost:
/// key/mouse events are posted straight to the target pid, and screenshots
/// composite the app's windows through ScreenCaptureKit so occlusion by
/// other apps is irrelevant.
///
/// Ported verbatim from the pre-rewrite `src/E2E/E2EDriverCommands.swift`; the
/// only addition is the `kill-helper` subcommand used by the crash-isolation
/// probe (it `SIGKILL`s a render-host helper pid so the script can assert the
/// app + sibling panes survive and the killed pane recovers).
enum E2EDriverCommands {
    /// Returns true when the invocation was a driver subcommand (handled
    /// here); false hands control back to the artifacts runner.
    static func run(arguments: [String]) async throws -> Bool {
        guard arguments.count > 1 else { return false }
        switch arguments[1] {
        case "screenshot":
            try await screenshot(arguments: arguments)
            return true
        case "send-key":
            try sendKey(arguments: arguments)
            return true
        case "send-click":
            try sendClick(arguments: arguments)
            return true
        case "kill-helper":
            try killHelper(arguments: arguments)
            return true
        case "frontmost":
            print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")
            return true
        default:
            return false
        }
    }

    // MARK: - screenshot

    private static func screenshot(arguments: [String]) async throws {
        guard let outputPath = value(after: "--output", in: arguments),
            let mainPid = value(after: "--main-pid", in: arguments).flatMap(pid_t.init)
        else {
            throw E2EDriverFailure(
                "usage: YAAWE2E screenshot --output <png> --main-pid <pid> [--owner-pid <pid>]...")
        }
        let ownerPids = Set(values(after: "--owner-pid", in: arguments).compactMap(pid_t.init))

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard
            let mainWindow = content.windows
                .filter({ $0.owningApplication?.processID == mainPid })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            throw E2EDriverFailure("screenshot: no on-screen window for pid \(mainPid)")
        }
        let mainFrame = mainWindow.frame
        let overlayWindows = content.windows.filter { window in
            guard let ownerPid = window.owningApplication?.processID else { return false }
            return ownerPids.contains(ownerPid) && window.frame.intersects(mainFrame)
        }
        // The window can sit on any display (or graze a neighboring one);
        // capture on the display holding most of it, clamped to that
        // display's bounds — an out-of-bounds sourceRect fails the stream.
        guard
            let display = content.displays.max(by: { lhs, rhs in
                let lhsArea = lhs.frame.intersection(mainFrame)
                let rhsArea = rhs.frame.intersection(mainFrame)
                return lhsArea.width * lhsArea.height < rhsArea.width * rhsArea.height
            })
        else {
            throw E2EDriverFailure("screenshot: no display found")
        }
        let captureRect = mainFrame.intersection(display.frame)
        guard captureRect.width > 1, captureRect.height > 1 else {
            throw E2EDriverFailure("screenshot: window for pid \(mainPid) is off-screen")
        }

        let filter = SCContentFilter(display: display, including: [mainWindow] + overlayWindows)
        let configuration = streamConfiguration(
            captureRect: captureRect, displayOrigin: display.frame.origin,
            scale: CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        try writePNG(image, to: outputPath)
    }

    private static func streamConfiguration(
        captureRect: CGRect, displayOrigin: CGPoint, scale: CGFloat
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: captureRect.origin.x - displayOrigin.x,
            y: captureRect.origin.y - displayOrigin.y,
            width: captureRect.width,
            height: captureRect.height
        )
        configuration.width = Int(captureRect.width * scale)
        configuration.height = Int(captureRect.height * scale)
        configuration.showsCursor = false
        return configuration
    }

    private static func writePNG(_ image: CGImage, to outputPath: String) throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw E2EDriverFailure("screenshot: could not create \(outputPath)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw E2EDriverFailure("screenshot: could not write \(outputPath)")
        }
    }

    // MARK: - send-key

    private static let virtualKeyCodesByName: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "lbracket": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38,
        "k": 40, "rbracket": 30, "comma": 43, "n": 45, "m": 46, "period": 47, "space": 49,
    ]

    private static func sendKey(arguments: [String]) throws {
        guard let pid = value(after: "--pid", in: arguments).flatMap(pid_t.init) else {
            throw E2EDriverFailure(
                "usage: YAAWE2E send-key --pid <pid> (--key <name> | --key-code <n>) "
                    + "[--modifiers command,shift]")
        }
        let keyCode = try resolveKeyCode(arguments: arguments)
        let flags = try resolveModifiers(arguments: arguments)
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            throw E2EDriverFailure("send-key: could not create key events")
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        usleep(60000)
        keyUp.postToPid(pid)
        usleep(60000)
    }

    private static func resolveKeyCode(arguments: [String]) throws -> CGKeyCode {
        if let name = value(after: "--key", in: arguments) {
            guard let code = virtualKeyCodesByName[name.lowercased()] else {
                throw E2EDriverFailure("send-key: unknown key name \(name)")
            }
            return code
        }
        if let raw = value(after: "--key-code", in: arguments).flatMap(UInt16.init) {
            return CGKeyCode(raw)
        }
        throw E2EDriverFailure("send-key: --key or --key-code is required")
    }

    private static let modifierFlagsByName: [String: CGEventFlags] = [
        "command": .maskCommand, "shift": .maskShift,
        "option": .maskAlternate, "control": .maskControl,
    ]

    private static func resolveModifiers(arguments: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in (value(after: "--modifiers", in: arguments) ?? "").split(separator: ",") {
            guard let flag = modifierFlagsByName[String(modifier)] else {
                throw E2EDriverFailure("send-key: unknown modifier \(modifier)")
            }
            flags.insert(flag)
        }
        return flags
    }

    // MARK: - send-click

    private static func sendClick(arguments: [String]) throws {
        guard let pid = value(after: "--pid", in: arguments).flatMap(pid_t.init),
            let x = value(after: "--x", in: arguments).flatMap(Double.init),
            let y = value(after: "--y", in: arguments).flatMap(Double.init)
        else {
            throw E2EDriverFailure("usage: YAAWE2E send-click --pid <pid> --x <n> --y <n>")
        }
        let point = CGPoint(x: x, y: y)
        guard
            let mouseDown = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left),
            let mouseUp = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)
        else {
            throw E2EDriverFailure("send-click: could not create mouse events")
        }
        mouseDown.postToPid(pid)
        usleep(60000)
        mouseUp.postToPid(pid)
        usleep(60000)
    }

    // MARK: - kill-helper (crash-isolation probe)

    /// `SIGKILL`s a render-host helper pid so the crash-isolation probe can
    /// assert the app process + sibling helpers survive and the killed pane
    /// recovers. Equivalent to `kill -9 <pid>`; provided as a subcommand so the
    /// probe never has to shell out to `kill`.
    private static func killHelper(arguments: [String]) throws {
        guard let pid = value(after: "--pid", in: arguments).flatMap(pid_t.init) else {
            throw E2EDriverFailure("usage: YAAWE2E kill-helper --pid <pid>")
        }
        if kill(pid, SIGKILL) != 0 {
            throw E2EDriverFailure("kill-helper: could not SIGKILL pid \(pid)")
        }
    }

    // MARK: - argument helpers

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func values(after flag: String, in arguments: [String]) -> [String] {
        var found: [String] = []
        for (index, argument) in arguments.enumerated()
        where argument == flag && index + 1 < arguments.count {
            found.append(arguments[index + 1])
        }
        return found
    }
}

struct E2EDriverFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
