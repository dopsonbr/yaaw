import SwiftUI
import YAAWKit

struct FileBrowserPanel: View {
    let state: FileBrowserState
    @Binding var searchQuery: String
    let selectedRelativePath: String?
    let fileIconPack: FileIconPack
    let onRefresh: () -> Void
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void
    let onTreeBuilt: (Int, Int, Int) -> Void
    @State private var expandedFolders: Set<String> = []
    @State private var typedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var treeRows: [FileBrowserVisibleTreeRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search files", text: $typedQuery)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .foregroundStyle(dracula(.foreground))
                    .accessibilityLabel("Search files")
                    .onAppear { typedQuery = searchQuery }
                    .onChange(of: searchQuery) { _, new in
                        if new != typedQuery { typedQuery = new }
                    }
                    .onChange(of: typedQuery) { _, new in
                        debounceTask?.cancel()
                        let captured = new
                        debounceTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                if searchQuery != captured { searchQuery = captured }
                            }
                        }
                    }

                Button(action: onRefresh) {
                    Image(systemName: IconRole.reload.icon.systemSymbolName)
                }
                .buttonStyle(.plain)
                .foregroundStyle(dracula(.cyan))
                .help("Refresh files")
                .accessibilityLabel("Refresh files")
            }

            HStack(spacing: 6) {
                if state.isIndexing {
                    ProgressView()
                        .scaleEffect(0.55)
                        .controlSize(.small)
                        .accessibilityLabel("Indexing files")
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(dracula(.comment))
                    .lineLimit(1)
            }

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.orange))
                    .lineLimit(3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(treeRows) { row in
                            FileBrowserTreeRowView(
                                row: row,
                                selectedRelativePath: selectedRelativePath,
                                expandedFolders: $expandedFolders,
                                fileIconPack: fileIconPack,
                                onSelectFile: onSelectFile,
                                onOpenFile: onOpenFile,
                                onOpenInBrowser: onOpenInBrowser,
                                defaultExternalEditorTool: defaultExternalEditorTool,
                                onOpenExternally: onOpenExternally,
                                onCopyPath: onCopyPath
                            )
                        }
                    } else {
                        ForEach(state.visibleEntries) { entry in
                            FileBrowserSearchRow(
                                entry: entry,
                                isSelected: selectedRelativePath == entry.relativePath,
                                fileIconPack: fileIconPack,
                                onSelectFile: onSelectFile,
                                onOpenFile: onOpenFile,
                                onOpenInBrowser: onOpenInBrowser,
                                defaultExternalEditorTool: defaultExternalEditorTool,
                                onOpenExternally: onOpenExternally,
                                onCopyPath: onCopyPath
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: state.entries) {
                rebuildVisibleTreeRows()
            }
            .onChange(of: state.rootPath) {
                expandedFolders.removeAll()
                rebuildVisibleTreeRows()
            }
            .onChange(of: expandedFolders) {
                rebuildVisibleTreeRows()
            }
            .onAppear {
                rebuildVisibleTreeRows()
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var statusText: String {
        guard let metadata = state.metadata else {
            return state.isIndexing ? "Indexing..." : "No index yet"
        }
        let ignored =
            metadata.ignoredDirectoryCount == 1
            ? "1 ignored directory" : "\(metadata.ignoredDirectoryCount) ignored directories"
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching {
            if state.isVisibleEntryLimitApplied {
                return
                    "Showing \(state.visibleEntries.count) of \(metadata.fileCount) matches, \(ignored)"
            }
            return
                "\(state.visibleEntries.count) matches of \(metadata.fileCount) items, \(ignored)"
        }
        if treeRows.count >= FileBrowserPanelConstants.maxVisibleTreeRows {
            return
                "Tree truncated at \(FileBrowserPanelConstants.maxVisibleTreeRows) rows - collapse folders to see more"
        }
        return "\(metadata.fileCount) items, \(ignored)"
    }

    private func rebuildVisibleTreeRows() {
        let startedAt = Date()
        let rows = FileBrowserTreeBuilder.visibleRows(
            from: state.entries,
            expandedFolders: expandedFolders,
            limit: FileBrowserPanelConstants.maxVisibleTreeRows
        )
        treeRows = rows
        onTreeBuilt(
            state.entries.count, rows.count,
            max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))
    }
}

private enum FileBrowserPanelConstants {
    // Defensive ceiling. Normal use stays well below this, even a 145k-file repo
    // only renders rows for paths whose ancestors are all expanded. If a user ever
    // hits this, the status line tells them so they're not silently truncated.
    static let maxVisibleTreeRows = 50_000
}

private struct FileBrowserTreeRowView: View {
    let row: FileBrowserVisibleTreeRow
    let selectedRelativePath: String?
    @Binding var expandedFolders: Set<String>
    let fileIconPack: FileIconPack
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void

    var body: some View {
        Button {
            onSelectFile(row.entry)
            if row.entry.isDirectory {
                toggleExpanded()
            } else {
                onOpenFile(row.entry)
            }
        } label: {
            FileBrowserRowContent(
                entry: row.entry,
                displayName: row.displayName,
                depth: row.depth,
                fileIconPack: fileIconPack,
                isExpanded: isExpanded
            )
        }
        .buttonStyle(.plain)
        .help(row.entry.isDirectory ? row.entry.relativePath : "Open in nvim")
        .contextMenu {
            externalOpenMenuItems(for: row.entry)
        }
        .background(
            selectedRelativePath == row.entry.relativePath
                ? dracula(.currentLine) : dracula(.background))
    }

    private var isExpanded: Bool {
        expandedFolders.contains(row.entry.relativePath)
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedFolders.remove(row.entry.relativePath)
        } else {
            expandedFolders.insert(row.entry.relativePath)
        }
    }

    @ViewBuilder
    private func externalOpenMenuItems(for entry: FileBrowserEntry) -> some View {
        Button("Copy Relative Path") {
            onCopyPath(entry, .relative)
        }

        Button("Copy Full Path") {
            onCopyPath(entry, .full)
        }

        if !entry.isDirectory {
            if AppModel.isBrowserPreviewSupported(relativePath: entry.relativePath) {
                Button("Open in Browser") {
                    onOpenInBrowser(entry)
                }
            }
        }

        if let defaultExternalEditorTool {
            Button("Open in Default Editor") {
                onOpenExternally(entry, defaultExternalEditorTool)
            }
        }

        if !entry.isDirectory {
            Button("Open in Built-in Editor") {
                onOpenFile(entry)
            }
        }
    }
}

private struct FileBrowserSearchRow: View {
    let entry: FileBrowserEntry
    let isSelected: Bool
    let fileIconPack: FileIconPack
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void

    var body: some View {
        if entry.isDirectory {
            FileBrowserRowContent(
                entry: entry,
                displayName: entry.relativePath,
                depth: 0,
                fileIconPack: fileIconPack,
                isExpanded: false
            )
            .background(isSelected ? dracula(.currentLine) : dracula(.background))
            .onTapGesture {
                onSelectFile(entry)
            }
            .contextMenu {
                fileMenuItems(for: entry)
            }
        } else {
            Button {
                onSelectFile(entry)
                onOpenFile(entry)
            } label: {
                FileBrowserRowContent(
                    entry: entry,
                    displayName: entry.relativePath,
                    depth: 0,
                    fileIconPack: fileIconPack,
                    isExpanded: false
                )
            }
            .buttonStyle(.plain)
            .background(isSelected ? dracula(.currentLine) : dracula(.background))
            .help("Open in nvim")
            .contextMenu {
                fileMenuItems(for: entry)
            }
        }
    }

    @ViewBuilder
    private func fileMenuItems(for entry: FileBrowserEntry) -> some View {
        Button("Copy Relative Path") {
            onCopyPath(entry, .relative)
        }

        Button("Copy Full Path") {
            onCopyPath(entry, .full)
        }

        if !entry.isDirectory, AppModel.isBrowserPreviewSupported(relativePath: entry.relativePath)
        {
            Button("Open in Browser") {
                onOpenInBrowser(entry)
            }
        }

        if let defaultExternalEditorTool {
            Button("Open in Default Editor") {
                onOpenExternally(entry, defaultExternalEditorTool)
            }
        }

        if !entry.isDirectory {
            Button("Open in Built-in Editor") {
                onOpenFile(entry)
            }
        }
    }
}

private struct FileBrowserRowContent: View {
    let entry: FileBrowserEntry
    let displayName: String
    let depth: Int
    let fileIconPack: FileIconPack
    var isExpanded = false
    @State private var isHovered = false
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        let fileIcon = FileIconResolver(pack: fileIconPack).icon(for: entry, isExpanded: isExpanded)

        HStack(spacing: 6) {
            Image(
                systemName: (isExpanded
                    ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed).icon
                    .systemSymbolName
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(dracula(.comment))
            .frame(width: 12)
            .opacity(entry.isDirectory ? 1 : 0)

            Image(systemName: fileIcon.systemSymbolName)
                .font(.system(size: 13))
                .foregroundStyle(
                    dracula(fileIcon.draculaRole ?? (entry.isDirectory ? .cyan : .purple))
                )
                .frame(width: 15)

            Text(displayName)
                .font(
                    fonts.fileBrowserFont(
                        sizeOffset: -1, weight: entry.isDirectory ? .semibold : .regular)
                )
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovered
                ? AnyShapeStyle(dracula(.currentLine).opacity(0.45)) : AnyShapeStyle(Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(entry.isDirectory ? "Folder" : "File") \(entry.relativePath)")
    }
}
