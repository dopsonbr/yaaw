import YAAWKit
import AppKit
import SwiftUI

struct WorkspaceSplitLayout: Equatable {
    var sidebarWidth: Double
    var rightPanelWidth: Double
    var globalTerminalHeight: Double
    var availableWindowHeight: Double
}

enum WorkspaceSplitResizePhase {
    case live
    case ended
}

enum WorkspaceSplitDivider {
    case sidebar
    case rightPanel
    case bottomTerminal
}

struct WorkspaceSplitView<Sidebar: View, Main: View, Right: View, Bottom: View>: NSViewControllerRepresentable {
    let layoutState: LayoutState
    let isSidebarCollapsed: Bool
    let isRightPanelCollapsed: Bool
    let isBottomTerminalExpanded: Bool
    let theme: ThemeDefinition
    let onResize: (WorkspaceSplitLayout, WorkspaceSplitResizePhase) -> Void
    let onReset: (WorkspaceSplitDivider) -> Void
    private let sidebar: Sidebar
    private let main: Main
    private let right: Right
    private let bottom: Bottom

    init(
        layoutState: LayoutState,
        isSidebarCollapsed: Bool,
        isRightPanelCollapsed: Bool,
        isBottomTerminalExpanded: Bool,
        theme: ThemeDefinition,
        onResize: @escaping (WorkspaceSplitLayout, WorkspaceSplitResizePhase) -> Void,
        onReset: @escaping (WorkspaceSplitDivider) -> Void,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder main: () -> Main,
        @ViewBuilder right: () -> Right,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.layoutState = layoutState
        self.isSidebarCollapsed = isSidebarCollapsed
        self.isRightPanelCollapsed = isRightPanelCollapsed
        self.isBottomTerminalExpanded = isBottomTerminalExpanded
        self.theme = theme
        self.onResize = onResize
        self.onReset = onReset
        self.sidebar = sidebar()
        self.main = main()
        self.right = right()
        self.bottom = bottom()
    }

    func makeNSViewController(context: Context) -> WorkspaceSplitViewController {
        WorkspaceSplitViewController()
    }

    func updateNSViewController(_ controller: WorkspaceSplitViewController, context: Context) {
        controller.update(
            sidebar: AnyView(sidebar),
            main: AnyView(main),
            right: AnyView(right),
            bottom: AnyView(bottom),
            configuration: WorkspaceSplitConfiguration(
                layoutState: layoutState,
                isSidebarCollapsed: isSidebarCollapsed,
                isRightPanelCollapsed: isRightPanelCollapsed,
                isBottomTerminalExpanded: isBottomTerminalExpanded,
                theme: theme
            ),
            onResize: onResize,
            onReset: onReset
        )
    }
}

final class WorkspaceSplitViewController: NSViewController {
    private let splitView = WorkspaceSplitHostView()

    override func loadView() {
        view = splitView
    }

    func update(
        sidebar: AnyView,
        main: AnyView,
        right: AnyView,
        bottom: AnyView,
        configuration: WorkspaceSplitConfiguration,
        onResize: @escaping (WorkspaceSplitLayout, WorkspaceSplitResizePhase) -> Void,
        onReset: @escaping (WorkspaceSplitDivider) -> Void
    ) {
        splitView.update(
            sidebar: sidebar,
            main: main,
            right: right,
            bottom: bottom,
            configuration: configuration,
            onResize: onResize,
            onReset: onReset
        )
    }
}

struct WorkspaceSplitConfiguration: Equatable {
    var layoutState: LayoutState
    var isSidebarCollapsed: Bool
    var isRightPanelCollapsed: Bool
    var isBottomTerminalExpanded: Bool
    var theme: ThemeDefinition
}

private final class WorkspaceSplitHostView: NSView {
    private enum Constants {
        static let dividerThickness = 10.0
        static let collapsedDividerThickness = 1.0
        static let collapsedRailWidth = 44.0
        static let collapsedBottomHeight = 42.0
        static let minimumContentHeight = 260.0
    }

    private let sidebarHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let mainHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let rightHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let bottomHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let sidebarDivider = WorkspaceDividerView(orientation: .vertical)
    private let rightDivider = WorkspaceDividerView(orientation: .vertical)
    private let bottomDivider = WorkspaceDividerView(orientation: .horizontal)

    private var configuration = WorkspaceSplitConfiguration(
        layoutState: .defaults,
        isSidebarCollapsed: false,
        isRightPanelCollapsed: false,
        isBottomTerminalExpanded: false,
        theme: ThemeCatalog.defaultTheme
    )
    private var onResize: (WorkspaceSplitLayout, WorkspaceSplitResizePhase) -> Void = { _, _ in }
    private var onReset: (WorkspaceSplitDivider) -> Void = { _ in }
    private var dragStartLayout: LayoutState?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(
        sidebar: AnyView,
        main: AnyView,
        right: AnyView,
        bottom: AnyView,
        configuration: WorkspaceSplitConfiguration,
        onResize: @escaping (WorkspaceSplitLayout, WorkspaceSplitResizePhase) -> Void,
        onReset: @escaping (WorkspaceSplitDivider) -> Void
    ) {
        sidebarHost.rootView = sidebar
        mainHost.rootView = main
        rightHost.rootView = right
        bottomHost.rootView = bottom
        self.configuration = configuration
        self.onResize = onResize
        self.onReset = onReset
        applyTheme()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let metrics = layoutMetrics()
        sidebarHost.frame = metrics.sidebarFrame
        sidebarDivider.frame = metrics.sidebarDividerFrame
        mainHost.frame = metrics.mainFrame
        rightDivider.frame = metrics.rightDividerFrame
        rightHost.frame = metrics.rightFrame
        bottomDivider.frame = metrics.bottomDividerFrame
        bottomHost.frame = metrics.bottomFrame
        sidebarDivider.isEnabled = !configuration.isSidebarCollapsed
        rightDivider.isEnabled = !configuration.isRightPanelCollapsed
        bottomDivider.isEnabled = configuration.isBottomTerminalExpanded
    }

    private func setup() {
        wantsLayer = true
        [sidebarHost, mainHost, rightHost, bottomHost, sidebarDivider, rightDivider, bottomDivider].forEach {
            addSubview($0)
        }
        sidebarDivider.accessibilityLabel = "Resize sidebar"
        rightDivider.accessibilityLabel = "Resize right panel"
        bottomDivider.accessibilityLabel = "Resize bottom terminal"
        sidebarDivider.onDragBegan = { [weak self] in self?.beginResizeDrag() }
        sidebarDivider.onDragChanged = { [weak self] delta in self?.resizeSidebar(by: delta) }
        sidebarDivider.onDragEnded = { [weak self] in self?.endResizeDrag() }
        sidebarDivider.onDoubleClick = { [weak self] in self?.onReset(.sidebar) }
        rightDivider.onDragBegan = { [weak self] in self?.beginResizeDrag() }
        rightDivider.onDragChanged = { [weak self] delta in self?.resizeRightPanel(by: delta) }
        rightDivider.onDragEnded = { [weak self] in self?.endResizeDrag() }
        rightDivider.onDoubleClick = { [weak self] in self?.onReset(.rightPanel) }
        bottomDivider.onDragBegan = { [weak self] in self?.beginResizeDrag() }
        bottomDivider.onDragChanged = { [weak self] delta in self?.resizeBottomTerminal(by: delta) }
        bottomDivider.onDragEnded = { [weak self] in self?.endResizeDrag() }
        bottomDivider.onDoubleClick = { [weak self] in self?.onReset(.bottomTerminal) }
        applyTheme()
    }

    private func applyTheme() {
        layer?.backgroundColor = NSColor(hex: configuration.theme.hex(for: .background)).cgColor
        let fill = NSColor(hex: configuration.theme.hex(for: .currentLine))
        let line = NSColor(hex: configuration.theme.hex(for: .comment))
        let active = NSColor(hex: configuration.theme.hex(for: .cyan))
        [sidebarDivider, rightDivider, bottomDivider].forEach {
            $0.fillColor = fill
            $0.lineColor = line
            $0.activeLineColor = active
        }
    }

    private func beginResizeDrag() {
        dragStartLayout = configuration.layoutState
    }

    private func resizeSidebar(by delta: Double) {
        guard var layout = dragStartLayout else { return }
        layout.sidebarWidth = LayoutState.clamp(
            layout.sidebarWidth + delta,
            minimum: LayoutState.minimumSidebarWidth,
            maximum: LayoutState.maximumSidebarWidth
        )
        publish(layout, phase: .live)
    }

    private func resizeRightPanel(by delta: Double) {
        guard var layout = dragStartLayout else { return }
        layout.rightPanelWidth = LayoutState.clamp(
            layout.rightPanelWidth - delta,
            minimum: LayoutState.minimumRightPanelWidth,
            maximum: LayoutState.maximumRightPanelWidth
        )
        publish(layout, phase: .live)
    }

    private func resizeBottomTerminal(by delta: Double) {
        guard var layout = dragStartLayout else { return }
        layout.globalTerminalHeight = LayoutState.clampedGlobalTerminalHeight(
            layout.globalTerminalHeight + delta,
            availableWindowHeight: bounds.height
        )
        publish(layout, phase: .live)
    }

    private func endResizeDrag() {
        onResize(currentLayout(), .ended)
        dragStartLayout = nil
    }

    private func publish(_ layout: LayoutState, phase: WorkspaceSplitResizePhase) {
        configuration.layoutState = layout
        needsLayout = true
        layoutSubtreeIfNeeded()
        onResize(currentLayout(), phase)
    }

    private func currentLayout() -> WorkspaceSplitLayout {
        WorkspaceSplitLayout(
            sidebarWidth: configuration.layoutState.sidebarWidth,
            rightPanelWidth: configuration.layoutState.rightPanelWidth,
            globalTerminalHeight: configuration.layoutState.globalTerminalHeight,
            availableWindowHeight: bounds.height
        )
    }

    private func layoutMetrics() -> WorkspaceSplitMetrics {
        let totalWidth = max(0, bounds.width)
        let totalHeight = max(0, bounds.height)
        let leftDividerWidth = configuration.isSidebarCollapsed
            ? Constants.collapsedDividerThickness
            : Constants.dividerThickness
        let rightDividerWidth = configuration.isRightPanelCollapsed
            ? Constants.collapsedDividerThickness
            : Constants.dividerThickness
        let bottomDividerHeight = configuration.isBottomTerminalExpanded
            ? Constants.dividerThickness
            : Constants.collapsedDividerThickness

        let bottomHeight = resolvedBottomHeight(totalHeight: totalHeight, dividerHeight: bottomDividerHeight)
        let contentHeight = max(0, totalHeight - bottomDividerHeight - bottomHeight)
        var sidebarWidth = resolvedSidebarWidth(totalWidth: totalWidth, dividerWidth: leftDividerWidth)
        var rightWidth = resolvedRightPanelWidth(totalWidth: totalWidth, dividerWidth: rightDividerWidth)
        let fixedWidth = leftDividerWidth + rightDividerWidth
        let availablePaneWidth = max(0, totalWidth - fixedWidth)
        var mainWidth = availablePaneWidth - sidebarWidth - rightWidth

        if mainWidth < LayoutState.minimumMainWorkspaceWidth {
            var deficit = LayoutState.minimumMainWorkspaceWidth - mainWidth
            if !configuration.isRightPanelCollapsed {
                let reducedRightWidth = max(LayoutState.minimumRightPanelWidth, rightWidth - deficit)
                deficit -= rightWidth - reducedRightWidth
                rightWidth = reducedRightWidth
            }
            if deficit > 0, !configuration.isSidebarCollapsed {
                let reducedSidebarWidth = max(LayoutState.minimumSidebarWidth, sidebarWidth - deficit)
                deficit -= sidebarWidth - reducedSidebarWidth
                sidebarWidth = reducedSidebarWidth
            }
            mainWidth = max(0, availablePaneWidth - sidebarWidth - rightWidth)
        }

        let sidebarFrame = NSRect(x: 0, y: 0, width: sidebarWidth, height: totalHeight)
        let sidebarDividerFrame = NSRect(
            x: sidebarFrame.maxX,
            y: 0,
            width: leftDividerWidth,
            height: totalHeight
        )
        let workspaceX = sidebarDividerFrame.maxX
        let workspaceWidth = max(0, totalWidth - workspaceX)
        let mainFrame = NSRect(
            x: workspaceX,
            y: 0,
            width: mainWidth,
            height: contentHeight
        )
        let rightDividerFrame = NSRect(
            x: mainFrame.maxX,
            y: 0,
            width: rightDividerWidth,
            height: contentHeight
        )
        let rightFrame = NSRect(
            x: rightDividerFrame.maxX,
            y: 0,
            width: max(0, totalWidth - rightDividerFrame.maxX),
            height: contentHeight
        )
        let bottomDividerFrame = NSRect(
            x: workspaceX,
            y: contentHeight,
            width: workspaceWidth,
            height: bottomDividerHeight
        )
        let bottomFrame = NSRect(
            x: workspaceX,
            y: bottomDividerFrame.maxY,
            width: workspaceWidth,
            height: max(0, totalHeight - bottomDividerFrame.maxY)
        )
        return WorkspaceSplitMetrics(
            sidebarFrame: sidebarFrame,
            sidebarDividerFrame: sidebarDividerFrame,
            mainFrame: mainFrame,
            rightDividerFrame: rightDividerFrame,
            rightFrame: rightFrame,
            bottomDividerFrame: bottomDividerFrame,
            bottomFrame: bottomFrame
        )
    }

    private func resolvedSidebarWidth(totalWidth: Double, dividerWidth: Double) -> Double {
        if configuration.isSidebarCollapsed {
            return Constants.collapsedRailWidth
        }
        let maximum = min(
            LayoutState.maximumSidebarWidth,
            max(
                LayoutState.minimumSidebarWidth,
                totalWidth - dividerWidth - LayoutState.minimumMainWorkspaceWidth
            )
        )
        return LayoutState.clamp(
            configuration.layoutState.sidebarWidth,
            minimum: LayoutState.minimumSidebarWidth,
            maximum: maximum
        )
    }

    private func resolvedRightPanelWidth(totalWidth: Double, dividerWidth: Double) -> Double {
        if configuration.isRightPanelCollapsed {
            return Constants.collapsedRailWidth
        }
        let maximum = min(
            LayoutState.maximumRightPanelWidth,
            max(
                LayoutState.minimumRightPanelWidth,
                totalWidth - dividerWidth - LayoutState.minimumMainWorkspaceWidth
            )
        )
        return LayoutState.clamp(
            configuration.layoutState.rightPanelWidth,
            minimum: LayoutState.minimumRightPanelWidth,
            maximum: maximum
        )
    }

    private func resolvedBottomHeight(totalHeight: Double, dividerHeight: Double) -> Double {
        guard configuration.isBottomTerminalExpanded else {
            return Constants.collapsedBottomHeight
        }
        let availableMaximum = max(
            LayoutState.minimumGlobalTerminalHeight,
            totalHeight - dividerHeight - Constants.minimumContentHeight
        )
        let maximum = min(
            LayoutState.maximumGlobalTerminalHeight(for: totalHeight),
            availableMaximum
        )
        return LayoutState.clamp(
            configuration.layoutState.globalTerminalHeight,
            minimum: LayoutState.minimumGlobalTerminalHeight,
            maximum: maximum
        )
    }
}

private struct WorkspaceSplitMetrics {
    var sidebarFrame: NSRect
    var sidebarDividerFrame: NSRect
    var mainFrame: NSRect
    var rightDividerFrame: NSRect
    var rightFrame: NSRect
    var bottomDividerFrame: NSRect
    var bottomFrame: NSRect
}

private final class WorkspaceDividerView: NSView {
    enum Orientation {
        case vertical
        case horizontal
    }

    var fillColor = NSColor.separatorColor {
        didSet { needsDisplay = true }
    }
    var lineColor = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var activeLineColor = NSColor.controlAccentColor {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }
    var accessibilityLabel = "" {
        didSet { setAccessibilityLabel(accessibilityLabel) }
    }
    var onDragBegan: () -> Void = {}
    var onDragChanged: (Double) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    private let orientation: Orientation
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isDragging = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        setAccessibilityRole(.splitter)
    }

    required init?(coder: NSCoder) {
        self.orientation = .vertical
        super.init(coder: coder)
        setAccessibilityRole(.splitter)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick()
            return
        }
        window?.makeFirstResponder(self)
        cursor.set()
        isDragging = true
        onDragBegan()
        let startLocation = event.locationInWindow

        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp {
                break
            }
            let location = nextEvent.locationInWindow
            let delta = orientation == .vertical
                ? location.x - startLocation.x
                : location.y - startLocation.y
            onDragChanged(delta)
        }

        onDragEnded()
        isDragging = false
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.withAlphaComponent(isHovered || isDragging ? 0.95 : 0.55).setFill()
        bounds.fill()

        let strokeColor = isHovered || isDragging ? activeLineColor : lineColor
        strokeColor.setFill()
        switch orientation {
        case .vertical:
            NSRect(
                x: floor(bounds.midX),
                y: 0,
                width: 1,
                height: bounds.height
            ).fill()
        case .horizontal:
            NSRect(
                x: 0,
                y: floor(bounds.midY),
                width: bounds.width,
                height: 1
            ).fill()
        }
    }

    private var cursor: NSCursor {
        switch orientation {
        case .vertical:
            .resizeLeftRight
        case .horizontal:
            .resizeUpDown
        }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255.0,
            green: CGFloat((rgb >> 8) & 0xff) / 255.0,
            blue: CGFloat(rgb & 0xff) / 255.0,
            alpha: 1
        )
    }
}
