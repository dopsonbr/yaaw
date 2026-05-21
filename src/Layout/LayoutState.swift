import Foundation

public struct LayoutState: Equatable, Sendable {
    public static let defaultSidebarWidth = 250.0
    public static let defaultRightPanelWidth = 360.0
    public static let defaultGlobalTerminalHeight = 140.0
    public static let minimumSidebarWidth = 180.0
    public static let maximumSidebarWidth = 520.0
    public static let minimumRightPanelWidth = 280.0
    public static let maximumRightPanelWidth = 720.0
    public static let minimumMainWorkspaceWidth = 420.0
    public static let minimumGlobalTerminalHeight = 96.0
    public static let maximumGlobalTerminalHeight = 420.0

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

    public static func maximumGlobalTerminalHeight(for availableWindowHeight: Double?) -> Double {
        guard let availableWindowHeight, availableWindowHeight > 0 else {
            return maximumGlobalTerminalHeight
        }
        return max(
            minimumGlobalTerminalHeight,
            min(maximumGlobalTerminalHeight, availableWindowHeight * 0.45)
        )
    }

    public static func clampedGlobalTerminalHeight(
        _ value: Double,
        availableWindowHeight: Double? = nil
    ) -> Double {
        clamp(
            value,
            minimum: minimumGlobalTerminalHeight,
            maximum: maximumGlobalTerminalHeight(for: availableWindowHeight)
        )
    }

    public mutating func resetSidebarWidth() {
        sidebarWidth = Self.defaultSidebarWidth
    }

    public mutating func resetRightPanelWidth() {
        rightPanelWidth = Self.defaultRightPanelWidth
    }

    public mutating func resetGlobalTerminalHeight() {
        globalTerminalHeight = Self.defaultGlobalTerminalHeight
    }
}
