import AppKit
import SwiftUI
import YAAWKit

/// Settings window: a `NavigationSplitView` (sidebar + detail) over the five
/// panes. Consumes `SettingsModel` (the YAML editor state machine) and reads the
/// live `SettingsStore` for the resolved theme + agent option catalog so the
/// window follows theme/appearance changes.
struct SettingsWindowView: View {
    @Bindable var model: SettingsModel
    let settings: SettingsStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
        .font(model.effectiveFonts.interfaceFont())
        .environment(\.fontSettings, model.effectiveFonts)
        .environment(\.appTheme, settings.resolvedTheme)
        .environment(\.colorScheme, settings.resolvedTheme.swiftUIColorScheme)
        .onAppear(perform: model.loadIfNeeded)
        .onChange(of: settings.configuration.themeName) { _, newThemeID in
            model.selectedThemeID = newThemeID
        }
        .confirmationDialog(
            "Discard unsaved settings changes?",
            isPresented: $model.isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                model.reloadFromDisk()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved YAML edits will be lost.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            TextField("Search", text: $model.sidebarSearchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(dracula(.currentLine))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .accessibilityIdentifier("settings-sidebar-search")

            List(selection: sidebarSelection) {
                ForEach(model.filteredSections) { section in
                    Label(section.title, systemImage: section.systemSymbolName)
                        .tag(section)
                        .accessibilityIdentifier("settings-sidebar-\(section.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if model.filteredSections.isEmpty {
                Text("No matching sections")
                    .font(model.effectiveFonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(dracula(.comment))
                    .padding(.bottom, 12)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .background(
            SidebarMaterialBackground(tintOpacity: settings.resolvedTheme.materialTintOpacity)
        )
        .toolbar(removing: .sidebarToggle)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let validationError = model.validationError {
                Label(validationError, systemImage: IconRole.warning.icon.systemSymbolName)
                    .font(model.effectiveFonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(dracula(.red))
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text(model.statusMessage)
                    .font(model.effectiveFonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(dracula(.comment))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dracula(.background))
        .navigationTitle(model.selectedSection.title)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.selectedSection {
        case .general:
            GeneralSettingsView(model: model)
        case .agents:
            AgentsSettingsView(model: model, agentCLIOptionCatalog: settings.agentCLIOptionCatalog)
        case .appearance:
            AppearanceSettingsView(model: model)
        case .keyboardShortcuts:
            KeyboardShortcutsSettingsView(model: model)
        case .configFile:
            ConfigFileSettingsView(model: model)
        }
    }

    /// List(selection:) wants an optional; the settings window always keeps a
    /// section selected, so deselection attempts are ignored.
    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(
            get: { model.selectedSection },
            set: { newValue in
                if let newValue { model.selectedSection = newValue }
            }
        )
    }
}

/// Behind-window sidebar material under the theme tint, matching the main
/// window's sidebar treatment. Reduce Transparency and high-contrast themes
/// (tint opacity 1) render fully opaque.
private struct SidebarMaterialBackground: View {
    let tintOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let effectiveOpacity = reduceTransparency ? 1.0 : tintOpacity
        ZStack {
            if effectiveOpacity < 1 {
                BehindWindowSidebarMaterial()
            }
            Rectangle()
                .fill(dracula(.background))
                .opacity(effectiveOpacity)
        }
        .ignoresSafeArea()
    }
}

private struct BehindWindowSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
