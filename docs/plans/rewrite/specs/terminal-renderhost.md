# Chunk D Port Specification: RenderHost + RenderHostClient + XPC + Compositing

**Status:** Ready for implementation  
**Scope:** Terminal/browser rendering helper, XPC protocol, main-app client lifecycle, cross-process compositing  
**Ports from:** `/src/Terminal/*`, `/src/ToolHost/main.swift`, `/src/App/IsolatedToolRuntime.swift`, `/src/IsolatedTools/IsolatedToolProtocol.swift`, `/src/ToolHostSupport/TerminalHostRenderingConfiguration.swift`

---

## Summary of Changes

This chunk reimplements the out-of-process terminal + browser rendering system from an NDJSON base64 overlay-window model to:

1. **Helper process (YAAWRenderHost):** Hosts PTY + libghostty emulator in a headless (no NSWindow) process per surface
2. **XPC transport:** Typed Codable message envelopes replacing NDJSON; IOSurface or `CAContext`/`CALayerHost` published natively (not base64)
3. **Cross-process compositing:** Frames composited natively inside panes; no viewport polling, no z-order repair, no floating windows
4. **Recoverable helper death:** App + sibling panes survive; affected pane goes to "reconnecting" state and relaunch + viewport replay + CLI session resume
5. **Hot-reload vs relaunch:** Rendering changes (theme/font/ligatures) applied to live process; command/env/cwd changes trigger relaunch

**Plan calls to:**
- **KEEP verbatim:** TerminalBackpressureGate (1MB/256KB), AgentTerminalProcess (forkpty/read loop), AgentTerminalOutputPump (32KB chunks), AgentTerminalCaptureWriter (8MB circular)
- **DELETE:** IsolatedToolViewportReporter (0.15s timer), visibility leases, orphan watchdogs, z-order repair, NDJSON framing, floating windows, base64 encoding

---

## Public API Surface (YAAWRenderProtocol)

### XPC Service & Client Protocols

```swift
// MARK: - XPC Service Protocol (exposed by YAAWRenderHost process)
@objc protocol YAAWRenderServiceProtocol: NSObjectProtocol {
  /// Async message passing (main → helper).
  /// reply block called with @escaping to unblock main thread immediately.
  func handleMessage(
    _ messageData: Data,
    reply: @escaping (NSXPCListenerEndpoint?) -> Void
  )
}

// MARK: - XPC Reply Protocol (from helper → main via async stream)
@objc protocol YAAWRenderReplyProtocol: NSObjectProtocol {
  /// Frame ready with new IOSurface or CAContext.contextID.
  func frameReady(
    generation: UInt64,
    ioSurfaceRef: NSValue?,
    contextID: UInt32
  )
  
  /// Events from the helper surface (title, activity, lifecycle).
  func eventReceived(_ eventData: Data)
}
```

### Codable Message Envelopes

Downbound (main → helper):

```swift
enum RenderMessage: Codable {
  case launch(LaunchPayload)           // Initial setup
  case resize(ResizePayload)           // Pane size change
  case input(InputPayload)             // Keyboard/paste
  case setRendering(RenderingPayload)  // Theme/font/ligatures hot-reload
  case shutdown                        // Terminate cleanly
}

struct LaunchPayload: Codable {
  var toolKind: String                 // "terminal" or "browser"
  var command: [String]                // exec argv
  var environment: [String: String]    // Full env or empty (inherit)
  var workingDirectory: String
  var captureLogPath: String?          // Terminal: PTY capture output
  var captureLogMaximumBytes: Int?
  var startupInput: String?            // Terminal: initial paste
  var agentCLI: String?                // Terminal: "claude"/"codex"/etc.
  var themeID: String?
  var terminalFontFamily: String?
  var terminalFontSize: Double?
  var terminalFontLigatures: Bool?     // nil = default (enabled)
  var appShortcutSignatures: [String]  // Cmd shortcuts to pass through
}

struct ResizePayload: Codable {
  var columns: UInt32
  var rows: UInt32
  var widthPixels: UInt32
  var heightPixels: UInt32
  var contentsScale: Double             // Backing scale (2.0 or 3.0)
}

struct InputPayload: Codable {
  var data: Data                        // Raw bytes (binary-safe, no base64)
}

struct RenderingPayload: Codable {
  var themeID: String?
  var terminalFontFamily: String?
  var terminalFontSize: Double?
  var terminalFontLigatures: Bool?
  var appShortcutSignatures: [String]
}

enum RenderEvent: Codable {
  case frameReady(generation: UInt64, ioSurfaceRef: UInt64?, caContextID: UInt32)
  case title(String)
  case activity(ActivityPayload)       // Parsed from capture log
  case sessionId(String)
  case bell
  case notification(title: String, body: String)
  case pwd(String)                     // Working directory from shell integration
  case commandFinished(exitCode: Int?, durationNanos: UInt64)
  case exited(Int32?)                  // Process exit code
  case captureTruncated(truncatedAtByte: UInt64)  // Circular buffer overflow
}

struct ActivityPayload: Codable {
  var activity: String                 // Parsed invocation or command
  var isRunning: Bool
}
```

### Helper Rendering Configuration DTO

(Shared; moved into YAAWRenderProtocol)

```swift
public struct TerminalHostRenderingConfiguration {
  public let terminalTheme: TerminalTheme
  public let terminalConfiguration: TerminalConfiguration
  public let appKitAppearanceName: NSAppearance.Name
  public let swiftUIColorScheme: ColorScheme
  
  // Factory methods (preserve existing signature & behavior).
  public static func make(for rendering: IsolatedTerminalRendering) 
    -> TerminalHostRenderingConfiguration
  public static func make(
    for theme: ThemeDefinition,
    fontSize: Float,
    fontFamily: String?,
    ligatures: Bool = true
  ) -> TerminalHostRenderingConfiguration
}
```

---

## Terminal Subsystem — Behavioral Specification

### TerminalBackpressureGate (KEEP VERBATIM)

**File:** `/src/Terminal/TerminalBackpressureGate.swift`

**Constants:**
- `highWaterMark: Int = 1_048_576` (1 MB)
- `lowWaterMark: Int = 262_144` (256 KB)

**Public API:**
```swift
public final class TerminalBackpressureGate: @unchecked Sendable {
  public init(highWaterMark: Int = 1_048_576, lowWaterMark: Int = 262_144)
  
  public func produced(_ byteCount: Int)        // Producer: record bytes read
  public func waitUntilReadable()               // Producer: block if paused
  public func consumed(_ byteCount: Int)        // Consumer: record delivery
  public func close()                           // Terminal closed
  
  public var pendingByteCount: Int { get }
  public var isPaused: Bool { get }
}
```

**Behavior (tests: `TerminalBackpressureGateTests.swift`):**
- Hysteresis: pause at `>=highWaterMark`, resume at `<=lowWaterMark` (not at zero)
- Producer blocks in `waitUntilReadable()` while `paused && !closed`
- Consumer unblocks producer when drained below low water
- Concurrent produce/consume with no byte loss (test: 5000×64B chunks)
- Close unblocks parked producer immediately

**Test assertion:** `testNoBytesLostUnderConcurrentProduceConsume` verifies no dropped bytes under concurrent stress.

---

### AgentTerminalProcess (KEEP VERBATIM)

**File:** `/src/Terminal/AgentTerminalProcess.swift`

**Public API:**
```swift
public final class AgentTerminalProcess: @unchecked Sendable {
  public struct AgentTerminalViewport: Equatable, Sendable {
    public var columns: UInt32
    public var rows: UInt32
    public var widthPixels: UInt32
    public var heightPixels: UInt32
  }
  
  public init(
    command: [String],
    workingDirectory: URL,
    environment: [String: String],
    backpressureGate: TerminalBackpressureGate? = nil,
    output: @escaping @Sendable (Data) -> Void,
    onExit: @escaping @Sendable (Int32?) -> Void = { _ in }
  )
  
  public func start(initialViewport: AgentTerminalViewport? = nil) throws
  public func write(_ data: Data)
  public func resize(to viewport: AgentTerminalViewport)
  public func terminate()
  
  public var isRunning: Bool { get }
}
```

**Behavior (tests: `TerminalDriverTests.swift` partial):**
- `forkpty(2)` with `O_CLOEXEC`; child `execve` → `execvp` fallback
- Read loop: 16 KB buffer, `darwin.read(fd, ...)` with backpressure gate checks
- Output handler called with chunks as read; exit handler called once with process exit code
- `SIGHUP` + `SIGTERM` (0.5s timeout) + `SIGKILL` on terminate
- Propagates `SIGWINCH` to process group on resize
- Environment merged with `TERM=xterm-256color` default

**Known behavior:**
- Read loop blocks at backpressure gate before each read (lossless)
- No partial writes — write loop until all bytes sent or FD broken
- Exit code extracted via WIFEXITED/WIFSIGNALED macros

---

### AgentTerminalOutputPump (KEEP VERBATIM)

**File:** `/src/Terminal/AgentTerminalDriver.swift` (lines ~1–177)

**Public API:**
```swift
public final class AgentTerminalOutputPump: @unchecked Sendable {
  public typealias ReceiveHandler = @Sendable (Data) -> Void
  public typealias FinishHandler = @Sendable (UInt32, UInt64) -> Void
  
  public init(
    maximumDeliveryBytes: Int = 32_768,              // 32 KB chunks
    slowDeliveryThreshold: TimeInterval = 0.1,       // 100 ms warning
    blockedDeliveryThreshold: TimeInterval = 2.0,    // 2 s alert
    diagnostics: DiagnosticEventRecording? = nil,
    queueLabel: String = "...",
    receive: @escaping ReceiveHandler,
    finish: @escaping FinishHandler,
    onDelivered: (@Sendable (Int) -> Void)? = nil   // For backpressure
  )
  
  public func enqueueOutput(_ data: Data)
  public func enqueueFinish(exitCode: UInt32, runtimeMilliseconds: UInt64)
}
```

**Behavior (tests: `TerminalDriverTests.swift` lines 6–100):**
- Queues data on dedicated `deliveryQueue` (GCD, `userInitiated` QoS)
- Batches adjacent `enqueueOutput` calls into single delivery (no artificial chunking overhead)
- Chunks large enqueued data to `maximumDeliveryBytes` per delivery, in order
- Calls `onDelivered(count)` after each delivery (drives backpressure gate `consumed()`)
- Defers `finish` until all pending data drained
- Records diagnostics: "delivery_blocked" if `receive` handler takes >2s; "delivery_slow" if >100ms
- Delivery continues until both data queue empty and finish delivered

**Test assertions:**
- Batching: `enqueueOutput("first"); enqueueOutput("second")` → single delivery "firstsecond"
- Chunking: `enqueueOutput("abcdefghijk")` with `maximumDeliveryBytes: 5` → ["abcde", "fghij", "k"]
- Finish deferred: output + finish queued → finish delivered only after all output chunks

---

### AgentTerminalCaptureWriter (KEEP VERBATIM)

**File:** `/src/Terminal/AgentTerminalCaptureLog.swift`

**Public API:**
```swift
public enum AgentTerminalCaptureLog {
  public static let maximumBytes: UInt64 = 8_388_608  // 8 MB
}

public final class AgentTerminalCaptureWriter: @unchecked Sendable {
  public init(
    url: URL,
    maximumBytes: UInt64 = AgentTerminalCaptureLog.maximumBytes
  )
  
  public func append(_ data: Data)
}
```

**Behavior:**
- Circular buffer: append to file; when size would exceed `maximumBytes`, truncate file and restart
- Lock protected (NSLock); concurrent appends serialized
- Creates parent directory if missing
- On overflow: `FileManager.removeItem` + file recreated, cache invalidated (`knownSize = 0`)
- Silent on file I/O errors (no throwing)

**Design note:** New code MUST surface truncation as a `RenderEvent.captureTruncated(truncatedAtByte:)` event so the main app can notify the user (no silent loss).

---

### IsolatedTerminalLaunch & IsolatedTerminalRendering (PRESERVE STRUCTURE)

**File:** `/src/IsolatedTools/IsolatedToolProtocol.swift`

**Public types & methods:**

```swift
public struct IsolatedTerminalLaunch: Equatable, Sendable {
  public var command: [String]
  public var environment: [String: String]
  public var workingDirectory: String
  public var captureLogPath: String?
  public var captureLogMaximumBytes: Int?
  public var startupInput: String?
  public var agentCLI: String?
  public var themeID: String?
  public var terminalFontFamily: String?
  public var terminalFontSize: Double?
  public var terminalFontLigatures: Bool?       // nil = enabled (default)
  public var appShortcutSignatures: [String]
  
  public func payload() -> [String: String]
  public static func from(payload: [String: String]) -> IsolatedTerminalLaunch?
  
  public var rendering: IsolatedTerminalRendering { get }
  public mutating func applyRendering(_ rendering: IsolatedTerminalRendering)
  
  /// True if both launches host the same process (all fields except rendering match).
  /// Used to distinguish hot-reload (renderingonly) from relaunch (process change).
  public func processIdentityMatches(_ other: IsolatedTerminalLaunch) -> Bool
}

public enum IsolatedTerminalLaunchTransition: Equatable, Sendable {
  case launchNew                // No prior launch
  case noChange                 // Identical to prior
  case updateRendering          // Only rendering fields changed
  case relaunchProcess          // Process changed (command/env/cwd)
  
  public static func between(
    _ existing: IsolatedTerminalLaunch?,
    _ next: IsolatedTerminalLaunch
  ) -> Self
}

public struct IsolatedTerminalRendering: Equatable, Sendable {
  public var themeID: String?
  public var terminalFontFamily: String?
  public var terminalFontSize: Double?
  public var terminalFontLigatures: Bool?
  public var appShortcutSignatures: [String]
  
  public func payload() -> [String: String]
  public static func from(payload: [String: String]) -> IsolatedTerminalRendering
}
```

**Behavior:**
- `processIdentityMatches`: normalizes rendering on copies and compares; any new field defaults to process identity (triggers relaunch if changed, safe)
- `IsolatedTerminalLaunchTransition.between`: determines whether to relaunch, hot-reload, or do nothing
- `payload()` / `from()` enable JSON round-trip (used by IPC)

---

## Cross-Process Compositing: IOSurface + CALayerHost Compositing Handshake

### Design Decision: IOSurface (Candidate 2)

The spike (Chunk 0.1) chooses **IOSurface** + `CALayerHost` over `CAContext`/`CALayerHost` remote-layer hosting because:
- Helper renders into IOSurface (existing libghostty path via InMemoryTerminalSession)
- IOSurface is `NSSecureCoding`-compliant; passes natively over XPC without base64
- CALayerHost compositing provides native clipping/layering in pane
- No requirement to patch libghostty render target

### IOSurface Publishing Flow

**Helper side:**
1. Ghostty surface renders each frame to IOSurface (existing in-memory backend)
2. On frame ready, extract IOSurface reference: `surface.surfaceRef()` or similar
3. Encode as `NSValue(nonretainedObject:)` for XPC NSSecureCoding
4. Send `RenderEvent.frameReady(generation:, ioSurfaceRef:, caContextID: 0)` with generation counter

**Main side:**
1. Receive IOSurface; set as `CALayer.contents` on pane's `wantsLayer` view
2. Handle resize via `ResizePayload` with new pixel dimensions
3. Enforce correct `contentsScale` per display backing scale (replicate libghostty coordinator's `onPostRender` correction)

### CAContext.contextID Publishing (Fallback)

If IOSurface extraction unavailable:
1. Wrap ghostty's CAMetalLayer in CAContext to publish a `contextID`
2. Send `frameReady(contextID: UInt32)` over XPC
3. Main app hosts with `CALayerHost(contextID:)` inside pane

### Frame Handshake

```swift
// Helper → Main (XPC reply protocol)
func frameReady(
  generation: UInt64,       // Monotonic counter; main tracks to drop stale frames
  ioSurfaceRef: NSValue?,   // IOSurface or nil if using CAContext
  contextID: UInt32         // CAContext.contextID or 0 if using IOSurface
)
```

**Main side:**
- Track `lastGenerationRendered` to drop out-of-order frames
- On resize, main → helper sends new pixel dimensions; helper re-fits grid and re-renders
- `contentsScale` enforcement (libghostty coordinator pattern):
  ```swift
  var contentsScale = window.backingScaleFactor
  layer.contentsScale = contentsScale
  if let metalLayer = layer as? CAMetalLayer {
    metalLayer.drawableSize = CGSize(
      width: bounds.width * contentsScale,
      height: bounds.height * contentsScale
    )
  }
  ```

---

## IPC Protocol v2 (Current) vs YAAWRenderProtocol (New)

### Current NDJSON v2 Protocol

**Format:** One JSON object per line (NDJSON), all fields `[String: String]`, bytes base64-encoded.

**Downbound messages:**
- `launchTool`: { toolKind, instanceID, type: "launchTool" }
- `launchTerminal`: { command: "["..."]", environment: "{...}", workingDirectory, captureLogPath, ... }
- `setViewport`: { x, y, width, height, visible, shouldFloat, parentWindowNumber }
- `input`: { bytes: "base64..." }  ← 33% overhead
- `setRenderingConfiguration`: { themeID, terminalFontFamily, terminalFontSize, terminalFontLigatures, ... }
- `resize`, `terminate`, `shutdown`, `show`, `hide`, `focus`, `blur`, `load`, `goBack`, `goForward`, `reload`, `stop`, `crashForTesting`

**Upbound messages:**
- `ready`: Signal ready
- `stateChanged`: { title, urlString, isLoading, canGoBack, canGoForward }
- `titleChanged`: { title }
- `desktopNotification`: { title, body }
- `focusChanged`: { focused }
- `closed`: { processAlive }
- `commandFinished`: { exitCode, durationNanos }
- `error`: { message }
- `exited`: { exitCode }
- `newSurfaceRequested`: { urlString }
- `keyboardShortcut`: { key, modifiers: "ctrl,shift,..." }

### New YAAWRenderProtocol (Typed Codable)

**Format:** Typed Codable envelopes (binary-safe); IOSurface/contextID passed natively via XPC NSSecureCoding.

**Downbound (`RenderMessage`):**
- `launch(LaunchPayload)` — single message with all init params
- `resize(ResizePayload)` — columns, rows, pixel dims, contentsScale
- `input(InputPayload)` — raw Data (no base64)
- `setRendering(RenderingPayload)` — hot-reload (theme/font/ligatures)
- `shutdown` — clean exit

**Removed:** `setViewport` (viewport polling → frame handshake), floating window logic, z-order repair

**Upbound (`RenderEvent`):**
- `frameReady(generation, ioSurfaceRef?, caContextID)` — compositing handshake
- `title(String)`
- `activity(ActivityPayload)` — parsed command state
- `sessionId(String)` — shell integration
- `bell`, `notification`, `pwd`, `commandFinished`, `exited`, `captureTruncated`

**Removed:** `stateChanged`, `focusChanged`, `closed`, viewport polling events

---

## RenderHostClient Actor (Main App Side)

**Location:** `src/App/RenderHostClient.swift` (new; replaces `IsolatedToolRuntime` terminal logic)

**Responsibility:** Manage XPC lifecycle per surface, forward events as `AsyncStream`, handle helper crashes/recovery.

### Public API

```swift
@MainActor
actor RenderHostClient: Sendable {
  /// One client per surface (identified by `surfaceID`).
  init(
    surfaceID: String,
    toolKind: IsolatedToolKind,
    helperURL: URL,
    onEvent: @escaping (RenderEvent) -> Void,
    onExit: @escaping (Bool) -> Void  // wasExpected
  )
  
  /// Launch helper and send initial config.
  func ensureLaunched(
    kind: IsolatedToolKind,
    launch: IsolatedTerminalLaunch
  ) async throws
  
  /// Apply rendering-only change to live helper (hot-reload).
  func applyRendering(_ rendering: IsolatedTerminalRendering) async throws
  
  /// Send resize (pane frame + display backing scale).
  func setViewport(
    columns: UInt32,
    rows: UInt32,
    widthPixels: UInt32,
    heightPixels: UInt32,
    contentsScale: Double
  ) async throws
  
  /// Send input bytes (keyboard, paste, host-injected).
  func sendInput(_ data: Data) async throws
  
  /// Clean termination + XPC disconnect.
  func shutdown() async throws
  
  /// Helper crash recovery state.
  var isConnected: Bool { get async }
  var phase: RenderPhase { get async }  // .idle, .launching, .ready, .failed, .crashed, .exited
}

enum RenderPhase: Equatable, Sendable {
  case idle
  case launching
  case ready
  case failed(String)
  case crashed(String)
  case exited(Int32?)
}

enum RenderEvent: Codable, Sendable {
  case frameReady(generation: UInt64, ioSurfaceRef: IOSurface?, contextID: UInt32)
  case title(String)
  case activity(ActivityPayload)
  case sessionId(String)
  case bell
  case notification(title: String, body: String)
  case pwd(String)
  case commandFinished(exitCode: Int?, durationNanos: UInt64)
  case exited(Int32?)
  case captureTruncated(truncatedAtByte: UInt64)
}
```

### Behavior (Design)

**Helper Lifecycle:**
1. `ensureLaunched()` spawns helper process if not running; sends `RenderMessage.launch(...)`
2. Helper responds with `RenderEvent` stream (upbound)
3. Main app consumes events in a `Task` (cancellation on view dismiss)
4. Helper crash or XPC drop detected via `invalidationHandler` → `phase = .crashed(...)`
5. `setViewport()` retried on next pane layout with cached viewport (replay mechanism)

**Hot-Reload vs Relaunch:**
- `IsolatedTerminalLaunchTransition.between(existing, next)` determines action
- `.updateRendering` → send `setRendering` message to live helper
- `.relaunchProcess` → shutdown helper, cache viewport, spawn new one

**Helper Death Recovery:**
- Pane shows "reconnecting" overlay
- Main app relaunches helper and replays cached viewport
- CLI session resumes via bound CLI's session storage (outside YAAW's scope; platform-dependent)

---

## YAAWRenderHost (Helper Process)

**Location:** `src/RenderHost/main.swift` (rework of `src/ToolHost/main.swift`)

**Responsibility:** Host PTY + emulator + browser in headless faceless process; publish frames + events over XPC.

### Executable Entry

```swift
@main
struct YAAWRenderHost {
  static func main() {
    let listener = NSXPCListener.service()
    let delegate = RenderServiceDelegate()
    listener.delegate = delegate
    listener.resume()
  }
}
```

### RenderServiceDelegate

```swift
@MainActor
class RenderServiceDelegate: NSObject, NSXPCListenerDelegate {
  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    let interface = NSXPCInterface(with: YAAWRenderServiceProtocol.self)
    newConnection.exportedInterface = interface
    let exporter = RenderServiceExporter()
    newConnection.exportedObject = exporter
    newConnection.resume()
    return true
  }
}

class RenderServiceExporter: NSObject, YAAWRenderServiceProtocol {
  @MainActor
  func handleMessage(_ messageData: Data, reply: @escaping (NSXPCListenerEndpoint?) -> Void) {
    // Decode RenderMessage, dispatch to TerminalHostController or BrowserHostController
    // reply() immediately to unblock main app
  }
}
```

### TerminalHostController (Terminal Mode)

(Largely unchanged from `ToolHostApp` in `src/ToolHost/main.swift`, adapted for XPC dispatch instead of NDJSON stdin/stdout)

**Responsibilities:**
1. Manage `AgentTerminalProcess` + `AgentTerminalOutputPump` + capture writer
2. Host `TerminalView` (Ghostty surface) in a headless NSView (no visible NSWindow)
3. Forward delegate events (title, command finished, notifications) to XPC reply protocol
4. Publish IOSurface frames on render completion

**Key members:**
```swift
private let process: AgentTerminalProcess
private let pump: AgentTerminalOutputPump
private let gate: TerminalBackpressureGate
private let captureWriter: AgentTerminalCaptureWriter?
private let session: InMemoryTerminalSession
private let view: TerminalView
private let delegate: HelperTerminalDelegate
private let driver: AgentTerminalProcessDriver

// Send events back to main app over XPC.
private let onEvent: (RenderEvent) -> Void
```

**Flow on `launch(LaunchPayload)`:**
1. Create backpressure gate, pump, capture writer, process, session
2. Install delegate to capture surface events (title, notifications, command finished, pwd, bell)
3. Attach driver to process and pump
4. Call `driver.resizeOrStart()` with initial viewport
5. Pump batches PTY output in 32 KB chunks to session
6. Each session render delivers frame to onEvent callback

**Flow on each frame render:**
1. Extract IOSurface from Ghostty surface: `surface.surfaceRef()` → `IOSurface(ptr)`
2. Send `RenderEvent.frameReady(generation: counter, ioSurfaceRef:)`
3. Generation counter increments per frame (main app drops out-of-order)

**Flow on `setRendering(RenderingPayload)`:**
1. Build `TerminalHostRenderingConfiguration` from payload
2. Call `state.setTheme()` + `state.setTerminalConfiguration()` (in-place, no grid wipe)
3. Call `view.appearance = NSAppearance(...)` for color scheme
4. No relaunch; process continues

**Flow on `setViewport(ResizePayload)`:**
1. Extract `columns`, `rows`, `widthPixels`, `heightPixels`, `contentsScale`
2. Call `driver.resizeOrStart(viewport)` to resize live process or start if not yet
3. Helper grid reflows; Ghostty signals completion via render event

### BrowserHostController (Browser Mode)

(Similar to terminal, but hosts `WKWebView` instead of PTY)

**Simpler lifecycle:**
- `launch(LaunchPayload)` with `command = ["load", "urlString"]`
- Hosts `WKWebView` + navigation delegate
- Events: title, loading state, navigation (back/forward), errors
- No PTY, no capture, no resize grid

---

## TerminalSurfaceHostView (Main App Side)

**Location:** `src/App/TerminalSurfaceHostView.swift` (new)

**Responsibility:** SwiftUI view hosting IOSurface + forwarding input to helper.

### Implementation Sketch

```swift
struct TerminalSurfaceHostView: NSViewRepresentable {
  @EnvironmentObject var renderHostClient: RenderHostClient
  var surfaceID: String
  
  func makeNSView(context: Context) -> TerminalPaneView {
    let view = TerminalPaneView()
    Task {
      // Listen to frame ready events; update layer.contents
      for await event in await renderHostClient.events {
        if case .frameReady(_, let ioSurface, _) = event {
          view.layer?.contents = ioSurface
        }
      }
    }
    return view
  }
  
  func updateNSView(_ view: TerminalPaneView, context: Context) {
    // Forward keyDown, paste, focus changes to renderHostClient
  }
}

// Platform-specific pane view
class TerminalPaneView: NSView {
  var wantsLayer: Bool { true }
  
  override func layout() {
    super.layout()
    // Enforce contentsScale per display backing scale
    if let layer {
      layer.contentsScale = window?.backingScaleFactor ?? 2.0
    }
    // Send resize to helper
    Task {
      let pixelSize = CGSize(
        width: bounds.width * (window?.backingScaleFactor ?? 2.0),
        height: bounds.height * (window?.backingScaleFactor ?? 2.0)
      )
      await renderHostClient.setViewport(
        columns: UInt32(bounds.width / cellWidth),
        rows: UInt32(bounds.height / cellHeight),
        widthPixels: UInt32(pixelSize.width),
        heightPixels: UInt32(pixelSize.height),
        contentsScale: window?.backingScaleFactor ?? 2.0
      )
    }
  }
}
```

---

## Hot-Reload vs Relaunch Logic

**Location:** `src/App/IsolatedToolRuntime.swift` (terminal section)

```swift
func ensureTerminalLaunched(
  instanceID: String,
  role: TerminalRole,
  launch: IsolatedTerminalLaunch,
  handlers: IsolatedTerminalEventHandlers
) {
  switch IsolatedTerminalLaunchTransition.between(
    terminalLaunchesByInstanceID[instanceID],
    launch
  ) {
  case .noChange, .launchNew:
    break
  case .updateRendering where hostsByInstanceID[instanceID] != nil:
    // Apply rendering change to live helper without restarting process.
    terminalLaunchesByInstanceID[instanceID] = launch
    send(
      type: "setRenderingConfiguration",
      payload: launch.rendering.payload())
    return
  case .updateRendering:
    // Host was killed; fall through to relaunch.
    break
  case .relaunchProcess:
    // Process changed (command/env/cwd) — relaunch.
    shutdown(instanceID: instanceID)
    terminalHandlersByInstanceID[instanceID] = (role, handlers)
  }
  
  // Launch or relaunch the helper.
  guard startHost(kind: .terminal, instanceID: instanceID) else { return }
  terminalLaunchesByInstanceID[instanceID] = launch
  send(
    type: "launchTerminal",
    payload: launch.payload())
  
  // Replay cached viewport if this is a relaunch.
  if let viewportPayload = terminalViewportPayloadsByInstanceID[instanceID] {
    send(type: "setViewport", payload: viewportPayload)
  }
}
```

---

## Error Handling & Resilience

### Graceful Degradation

1. **Helper launch fails:** Pane shows `phase = .failed(message)` overlay
2. **XPC connection breaks:** Pane shows "reconnecting" state; main app relaunch + replay
3. **Capture buffer overflow:** Send `captureTruncated(byte)` event; display overlay alert
4. **Input send fails:** Treat as helper dead; trigger relaunch flow
5. **Resize during relaunch:** Cache viewport; send on helper ready

### Loud vs Silent Failures

**Loud (visible to user):**
- Helper crash → "reconnecting" pane + relaunch + replay
- Capture buffer overflow → `captureTruncated` event + overlay alert
- Launch failure → `phase = .failed(...)` + error message in pane

**Silent (diagnostic only):**
- Input delivery latency → diagnostic event (already in output pump)
- Out-of-order frames → dropped (generation counter)

---

## Tests & Parity Specification

### Port from Current Codebase

| Test File | Assertions | New Behavior |
|-----------|-----------|---|
| `TerminalBackpressureGateTests.swift` | Hysteresis, concurrent produce/consume, no loss | KEEP unchanged |
| `TerminalDriverTests.swift` (partial) | Output batching, chunking, finish deferral | KEEP, rename for pump-only tests |
| `TerminalPasteTests.swift` | Paste input delivery | Port; verify via XPC InputPayload |
| `TerminalHostRenderingConfigurationTests.swift` | Theme/font config building | Move to YAAWRenderProtocol; test unchanged |
| `IsolatedToolProtocolTests.swift` | Message round-trip, validation | Rewrite for Codable envelopes + XPC |

### New Tests for Chunk D

1. **XPC message round-trip:** Encode `RenderMessage` → decode → verify fields match
2. **IOSurface handshake:** Mock frame ready; verify main app sets `layer.contents`
3. **Hot-reload vs relaunch:** `IsolatedTerminalLaunchTransition.between()` distinguishes correctly
4. **Helper death + recovery:** Kill helper process; verify pane goes "reconnecting" → relaunch → success
5. **Viewport replay:** Shutdown + relaunch; verify cached viewport sent to new helper
6. **Resize correctness:** Send resize; verify grid reflow and frame generation increments
7. **Capture truncation event:** Fill 8 MB capture buffer; verify `captureTruncated` event + UI alert

---

## Concurrency Model & Swift 6 Strict Concurrency

### Main App Side

**@MainActor:**
- `IsolatedToolRuntime` (snapshot observation)
- `TerminalSurfaceHostView` (SwiftUI view)
- `TerminalPaneView` (NSView + input forwarding)

**Actor:**
- `RenderHostClient` (one per surface; manages XPC lifecycle + events)

**Task cancellation replaces generation counters:**
- UI dismisses pane → cancel Task consuming frame events → XPC connection invalidated
- Settings change → old tasks cancelled; new task with updated config runs

**Sendable boundaries:**
- `RenderMessage`, `RenderEvent`, `RenderPhase` all `Sendable` (Codable, enums, struct value types)
- `AsyncStream<RenderEvent>` exposed by actor for Task consumption

### Helper Side (YAAWRenderHost)

**@MainActor:**
- `TerminalHostController` + delegate (Ghostty surface is main-thread-only)
- `RenderServiceDelegate` (NSXPCConnection dispatch)
- All frame rendering

**Sendable:**
- Process output handler (on background GCD queue) → @Sendable closure
- Backpressure gate operations (@unchecked Sendable OK; internal NSCondition + primitives)

---

## Plan Directives (Chunk D Scope)

| Directive | Status |
|-----------|--------|
| KEEP: TerminalBackpressureGate 1MB/256KB | ✓ Preserve exactly |
| KEEP: AgentTerminalProcess forkpty/read loop | ✓ Preserve, no changes |
| KEEP: AgentTerminalOutputPump 32KB chunks | ✓ Preserve, keep diagnostics |
| KEEP: AgentTerminalCaptureWriter 8MB circular | ✓ Preserve, surface truncation as event |
| DELETE: IsolatedToolViewportReporter 0.15s timer | ✓ Replace with frame handshake |
| DELETE: Visibility leases | ✓ No viewport polling; pane visible iff not dismissed |
| DELETE: Orphan watchdogs | ✓ XPC invalidation handler reaps + relaunches |
| DELETE: Z-order repair | ✓ No floating windows; native layer compositing |
| DELETE: Base64 encoding | ✓ Binary-safe Data, IOSurface/contextID native |
| NEW: XPC typed Codable protocol | ✓ Implement YAAWRenderProtocol |
| NEW: Cross-process compositing | ✓ IOSurface or CALayerHost (spike decides) |
| NEW: Hot-reload vs relaunch distinction | ✓ Implement via IsolatedTerminalLaunchTransition |
| NEW: Recoverable helper death | ✓ "reconnecting" state + relaunch + replay |

---

## File Structure

```
src/RenderProtocol/
  ├── YAAWRenderProtocol.swift           (Codable envelopes, Sendable types)
  └── TerminalHostRenderingConfiguration.swift (moved; shared DTO)

src/RenderHost/
  ├── main.swift                         (entry + NSXPCListener setup)
  ├── RenderServiceDelegate.swift
  ├── TerminalHostController.swift       (PTY + Ghostty surface hosting)
  ├── BrowserHostController.swift        (WKWebView hosting)
  └── HelperTerminalDelegate.swift       (surface → event dispatch)

src/App/
  ├── RenderHostClient.swift             (actor; XPC lifecycle + events)
  ├── TerminalSurfaceHostView.swift      (NSViewRepresentable; IOSurface compositing)
  └── (IsolatedToolRuntime updated for RenderHostClient integration)
```

---

## Test Acceptance Criteria

- Terminal renders in-pane with native clipping/layering (no overlay window)
- Resize lag ≈ **0** (synchronous with layout pass)
- Input path has **no base64 overhead** (binary-safe Data)
- Idle CPU ≈ **0** (no viewport polling timers)
- **Per-panel crash isolation verified:** Kill one terminal helper with `kill -9`; app + siblings survive; affected pane recovers (relaunch + replay + resume)
- Hot-reload of theme/font/ligatures applies to live terminals without restart
- Browser preview (HTML/MD/PDF/images + URL nav) works isolated
- No visible tearing or flicker on composite; correct scale on high-DPI displays
- Capture buffer overflow raises `captureTruncated` event; UI alerts user

---

## Risk Mitigations

| Risk | Mitigation |
|------|-----------|
| IOSurface extraction not available on 1.2.4 | Spike evaluates both IOSurface + CAContext; fallback to improved overlay window (still crash-isolated) |
| Compositing scale drift on resize | Replicate libghostty coordinator's `onPostRender` `contentsScale` correction; double-buffer with generation counter |
| Helper stuck in I/O; main app blocks | Separate write queue + pending-byte cap (4MB); hung helper detected + XPC disconnected |
| Frame ordering (out-of-order delivery) | Generation counter; main drops frames older than last rendered |
| IME/marked-text correctness | Spike minimum bar = ASCII/modifiers/paste/Enter; full IME tracked; record exceptions |

---

**Spec version:** 1.0  
**Last updated:** 2026-06-11  
**Ready for implementation:** Yes
