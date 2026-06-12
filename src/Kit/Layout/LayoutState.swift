import Foundation

/// Persisted geometry and visibility state for the window's chrome: sidebar,
/// right panel, bottom (global) terminal, and the swap of main/right workspace.
/// Widths and heights are clamped to their valid ranges on initialization.
public struct LayoutState: Equatable, Sendable {
    /// The default sidebar width, in points.
    public static let defaultSidebarWidth = 250.0
    /// The default right-panel width, in points.
    public static let defaultRightPanelWidth = 360.0
    /// The default bottom (global) terminal height, in points.
    public static let defaultGlobalTerminalHeight = 140.0
    /// The minimum allowed sidebar width, in points.
    public static let minimumSidebarWidth = 180.0
    /// The maximum allowed sidebar width, in points.
    public static let maximumSidebarWidth = 520.0
    /// The minimum allowed right-panel width, in points.
    public static let minimumRightPanelWidth = 280.0
    /// The minimum width reserved for the main workspace, in points.
    public static let minimumMainWorkspaceWidth = 420.0
    /// The minimum allowed bottom (global) terminal height, in points.
    public static let minimumGlobalTerminalHeight = 96.0
    /// The maximum allowed bottom (global) terminal height, in points.
    public static let maximumGlobalTerminalHeight = 420.0

    /// The current sidebar width, in points.
    public var sidebarWidth: Double
    /// The current right-panel width, in points.
    public var rightPanelWidth: Double
    /// The current bottom (global) terminal height, in points.
    public var globalTerminalHeight: Double
    /// Whether the sidebar is collapsed.
    public var isSidebarCollapsed: Bool
    /// Whether the right panel is collapsed.
    public var isRightPanelCollapsed: Bool
    /// Whether the bottom (global) terminal is expanded.
    public var isGlobalTerminalExpanded: Bool
    /// Whether the main and right workspace positions are swapped.
    public var isWorkspaceSwapped: Bool

    /// Creates a layout state, clamping each width and height to its valid range.
    public init(
        sidebarWidth: Double = LayoutState.defaultSidebarWidth,
        rightPanelWidth: Double = LayoutState.defaultRightPanelWidth,
        globalTerminalHeight: Double = LayoutState.defaultGlobalTerminalHeight,
        isSidebarCollapsed: Bool = false,
        isRightPanelCollapsed: Bool = false,
        isGlobalTerminalExpanded: Bool = false,
        isWorkspaceSwapped: Bool = false
    ) {
        self.sidebarWidth = Self.clamp(
            sidebarWidth,
            minimum: Self.minimumSidebarWidth,
            maximum: Self.maximumSidebarWidth
        )
        self.rightPanelWidth = Self.clampMinimum(
            rightPanelWidth,
            minimum: Self.minimumRightPanelWidth
        )
        self.globalTerminalHeight = Self.clamp(
            globalTerminalHeight,
            minimum: Self.minimumGlobalTerminalHeight,
            maximum: Self.maximumGlobalTerminalHeight
        )
        self.isSidebarCollapsed = isSidebarCollapsed
        self.isRightPanelCollapsed = isRightPanelCollapsed
        self.isGlobalTerminalExpanded = isGlobalTerminalExpanded
        self.isWorkspaceSwapped = isWorkspaceSwapped
    }

    /// A layout state with every value at its default.
    public static var defaults: LayoutState {
        LayoutState()
    }

    /// Returns `value` clamped to the closed range `minimum...maximum`.
    public static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// Returns `value` raised to at least `minimum`.
    public static func clampMinimum(_ value: Double, minimum: Double) -> Double {
        max(value, minimum)
    }

    /// Returns the maximum bottom-terminal height for the given available window
    /// height, capping it at 45% of the window (and the absolute maximum) while
    /// never dropping below the minimum.
    public static func maximumGlobalTerminalHeight(for availableWindowHeight: Double?) -> Double {
        guard let availableWindowHeight, availableWindowHeight > 0 else {
            return maximumGlobalTerminalHeight
        }
        return max(
            minimumGlobalTerminalHeight,
            min(maximumGlobalTerminalHeight, availableWindowHeight * 0.45)
        )
    }

    /// Returns `value` clamped to the valid bottom-terminal height range for the
    /// given available window height.
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

    /// Resets the sidebar width to its default.
    public mutating func resetSidebarWidth() {
        sidebarWidth = Self.defaultSidebarWidth
    }

    /// Resets the right-panel width to its default.
    public mutating func resetRightPanelWidth() {
        rightPanelWidth = Self.defaultRightPanelWidth
    }

    /// Resets the bottom (global) terminal height to its default.
    public mutating func resetGlobalTerminalHeight() {
        globalTerminalHeight = Self.defaultGlobalTerminalHeight
    }
}
