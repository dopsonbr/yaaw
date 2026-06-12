import SwiftUI
import YAAWKit

enum FileBrowserCopyPathStyle {
    case relative
    case full
}

/// Files tab UI: search field (debounced), refresh, status line, and the tree
/// (or search results). Consumes the `ActivityStore`'s `FileBrowserState` plus
/// the `RightPanelStore`'s per-thread expanded folders and selection — all passed
/// in as bindings/closures so the view itself holds no store reference.
struct FileBrowserPanel: View {
    let state: FileBrowserState
    @Binding var searchQuery: String
    @Binding var expandedFolders: Set<String>
    let selectedRelativePath: String?
    let fileIconPack: FileIconPack
    let onRefresh: () -> Void
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void
    @State private var typedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var treeRows: [FileBrowserVisibleTreeRow] = []
    @State private var treeChildrenIndex: [String: [FileBrowserEntry]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search files", text: $typedQuery)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .foregroundStyle(dracula(.foreground))
                    .accessibilityIdentifier("files-search-field")
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
                .accessibilityIdentifier("files-refresh-button")
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
                rebuildTreeIndexAndRows()
            }
            .onChange(of: state.rootPath) {
                rebuildTreeIndexAndRows()
            }
            .onChange(of: expandedFolders) {
                rebuildVisibleTreeRows()
            }
            .onAppear {
                rebuildTreeIndexAndRows()
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var statusText: String {
        guard let metadata = state.metadata else {
            return state.isIndexing ? "Indexing..." : "No index yet"
        }
        if state.isIndexTruncated {
            // Loud, not silent: the project is too large to fully index, so the
            // browser shows the first N entries (deeper folders still expand, and
            // search runs over the indexed subset).
            return
                "Large project - indexed first \(metadata.fileCount) items; expand folders or search for more"
        }
        let ignored =
            metadata.ignoredDirectoryCount == 1
            ? "1 collapsed directory" : "\(metadata.ignoredDirectoryCount) collapsed directories"
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching {
            if state.isVisibleEntryLimitApplied {
                return
                    "Showing \(state.visibleEntries.count) of \(metadata.fileCount) matches, \(ignored)"
            }
            return
                "\(state.visibleEntries.count) matches of \(metadata.fileCount) items, \(ignored)"
        }
        if state.isBrowseEntryLimitApplied {
            return
                "Showing \(state.entries.count) of \(state.indexedEntryCount) indexed items, \(ignored)"
        }
        if treeRows.count >= FileBrowserPanelConstants.maxVisibleTreeRows {
            return
                "Tree truncated at \(FileBrowserPanelConstants.maxVisibleTreeRows) rows - collapse folders to see more"
        }
        return "\(metadata.fileCount) items, \(ignored)"
    }

    private func rebuildTreeIndexAndRows() {
        treeChildrenIndex = FileBrowserTreeBuilder.childrenIndex(from: state.entries)
        rebuildVisibleTreeRows()
    }

    private func rebuildVisibleTreeRows() {
        treeRows = FileBrowserTreeBuilder.visibleRows(
            childrenIndex: treeChildrenIndex,
            expandedFolders: expandedFolders,
            limit: FileBrowserPanelConstants.maxVisibleTreeRows
        )
    }
}

private enum FileBrowserPanelConstants {
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
        .help(row.entry.isDirectory ? row.entry.relativePath : "Open file")
        .contextMenu {
            FileBrowserContextMenu(
                entry: row.entry,
                defaultExternalEditorTool: defaultExternalEditorTool,
                onOpenFile: onOpenFile,
                onOpenInBrowser: onOpenInBrowser,
                onOpenExternally: onOpenExternally,
                onCopyPath: onCopyPath
            )
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
            .onTapGesture { onSelectFile(entry) }
            .contextMenu {
                FileBrowserContextMenu(
                    entry: entry,
                    defaultExternalEditorTool: defaultExternalEditorTool,
                    onOpenFile: onOpenFile,
                    onOpenInBrowser: onOpenInBrowser,
                    onOpenExternally: onOpenExternally,
                    onCopyPath: onCopyPath
                )
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
            .help("Open file")
            .contextMenu {
                FileBrowserContextMenu(
                    entry: entry,
                    defaultExternalEditorTool: defaultExternalEditorTool,
                    onOpenFile: onOpenFile,
                    onOpenInBrowser: onOpenInBrowser,
                    onOpenExternally: onOpenExternally,
                    onCopyPath: onCopyPath
                )
            }
        }
    }
}

private struct FileBrowserContextMenu: View {
    let entry: FileBrowserEntry
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void

    var body: some View {
        Button("Copy Relative Path") { onCopyPath(entry, .relative) }
        Button("Copy Full Path") { onCopyPath(entry, .full) }

        if !entry.isDirectory,
            RightPanelStore.isBrowserPreviewSupported(relativePath: entry.relativePath)
        {
            Button("Open in Browser") { onOpenInBrowser(entry) }
        }

        if let defaultExternalEditorTool {
            Button("Open in Default Editor") { onOpenExternally(entry, defaultExternalEditorTool) }
        }

        if !entry.isDirectory {
            Button("Open in Built-in Editor") { onOpenFile(entry) }
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
        .opacity(entry.isPruned ? 0.55 : 1)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(entry.isPruned ? "Not indexed — expand to load and search its contents" : "")
        .background(
            isHovered
                ? AnyShapeStyle(dracula(.currentLine).opacity(0.45)) : AnyShapeStyle(Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(entry.isDirectory ? "Folder" : "File") \(entry.relativePath)")
    }
}
