import Foundation

public struct LayoutState: Equatable, Sendable {
    public static let defaultSidebarWidth = 250.0
    public static let defaultRightPanelWidth = 360.0
    public static let defaultGlobalTerminalHeight = 140.0
    public static let minimumSidebarWidth = 180.0
    public static let maximumSidebarWidth = 420.0
    public static let minimumRightPanelWidth = 300.0
    public static let maximumRightPanelWidth = 420.0
    public static let minimumGlobalTerminalHeight = 96.0
    public static let maximumGlobalTerminalHeight = 320.0

    public var sidebarWidth: Double
    public var rightPanelWidth: Double
    public var globalTerminalHeight: Double
    public var isSidebarCollapsed: Bool
    public var isRightPanelCollapsed: Bool
    public var isGlobalTerminalExpanded: Bool

    public init(
        sidebarWidth: Double = LayoutState.defaultSidebarWidth,
        rightPanelWidth: Double = LayoutState.defaultRightPanelWidth,
        globalTerminalHeight: Double = LayoutState.defaultGlobalTerminalHeight,
        isSidebarCollapsed: Bool = false,
        isRightPanelCollapsed: Bool = false,
        isGlobalTerminalExpanded: Bool = false
    ) {
        self.sidebarWidth = Self.clamp(
            sidebarWidth,
            minimum: Self.minimumSidebarWidth,
            maximum: Self.maximumSidebarWidth
        )
        self.rightPanelWidth = Self.clamp(
            rightPanelWidth,
            minimum: Self.minimumRightPanelWidth,
            maximum: Self.maximumRightPanelWidth
        )
        self.globalTerminalHeight = Self.clamp(
            globalTerminalHeight,
            minimum: Self.minimumGlobalTerminalHeight,
            maximum: Self.maximumGlobalTerminalHeight
        )
        self.isSidebarCollapsed = isSidebarCollapsed
        self.isRightPanelCollapsed = isRightPanelCollapsed
        self.isGlobalTerminalExpanded = isGlobalTerminalExpanded
    }

    public static var defaults: LayoutState {
        LayoutState()
    }

    public static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}
