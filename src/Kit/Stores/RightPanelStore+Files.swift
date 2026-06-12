import Foundation

extension RightPanelStore {
    // MARK: - Path resolution

    /// The standardized URL for a relative path under the selected thread's
    /// working directory, rejecting paths that escape the root.
    public func fileBrowserURL(relativePath: String) -> URL? {
        selectedThreadFileURL(relativePath: relativePath)?.url
    }

    func selectedThreadFileURL(relativePath: String) -> (normalizedPath: String, url: URL)? {
        guard let root = selectedThreadWorkingDirectory?(),
            isExistingDirectory(root)
        else { return nil }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard !normalizedPath.isEmpty else { return nil }
        let standardizedRoot = root.standardizedFileURL
        let url = standardizedRoot.appendingPathComponent(normalizedPath).standardizedFileURL
        let rootPath = standardizedRoot.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return nil }
        return (normalizedPath, url)
    }

    /// An "open externally" target for the file at the given relative path, or
    /// `nil` if it cannot be resolved under the selected thread's root.
    public func externalOpenFileTarget(relativePath: String) -> ExternalOpenTarget? {
        fileBrowserExternalOpenTarget(relativePath: relativePath, isDirectory: false)
    }

    /// An "open externally" target for the file or directory at the given relative
    /// path, or `nil` if it cannot be resolved under the selected thread's root.
    public func fileBrowserExternalOpenTarget(relativePath: String, isDirectory: Bool)
        -> ExternalOpenTarget?
    {
        guard let url = fileBrowserURL(relativePath: relativePath) else { return nil }
        return ExternalOpenTarget(url: url, kind: isDirectory ? .directory : .file)
    }

    /// An "open externally" target for the currently selected file, if any.
    public var selectedExternalOpenFileTarget: ExternalOpenTarget? {
        guard let selectedFileRelativePath else { return nil }
        return externalOpenFileTarget(relativePath: selectedFileRelativePath)
    }

    // MARK: - Open in nvim

    /// Opens the currently selected file in an nvim tab, if a file is selected.
    public func openSelectedFileInNvim() {
        guard let selectedFileRelativePath else { return }
        openFileInNvim(relativePath: selectedFileRelativePath)
    }

    /// Opens the file at the given relative path in an nvim tab (reusing an
    /// existing tab if already open), switches the panel to nvim, and persists.
    public func openFileInNvim(relativePath: String) {
        guard let selectedThreadID,
            let resolvedFile = selectedThreadFileURL(relativePath: relativePath)
        else { return }
        let normalizedPath = resolvedFile.normalizedPath
        setSelectedFile(normalizedPath)
        var state = selectedRightPanelState
        let existingTabID = RightPanelTab.nvimTabID(relativePath: normalizedPath)
        let alreadyOpen = state.tabs.contains { $0.id == existingTabID }
        let tab = state.openNvimTab(relativePath: normalizedPath)
        state.nvimPath = normalizedPath
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .nvim
        if !alreadyOpen {
            nvimRelaunchTokensByTabKey[nvimTabKey(threadID: selectedThreadID, tabID: tab.id)] =
                UUID()
            surfaceManager.shutdown(role: .nvimTab(threadID: selectedThreadID, tabID: tab.id))
        }
        nvimRelaunchTokensByThreadID[selectedThreadID] = UUID()
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Opens a file from the browser's primary action: routes markdown/HTML to the
    /// browser preview when `markdownAndHTMLToBrowser` is set and it succeeds,
    /// otherwise opens the file in nvim.
    public func openFileFromBrowserPrimary(relativePath: String, markdownAndHTMLToBrowser: Bool) {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard
            markdownAndHTMLToBrowser,
            Self.isMarkdownOrHTML(relativePath: normalizedPath),
            openFileInBrowser(relativePath: normalizedPath)
        else {
            openFileInNvim(relativePath: relativePath)
            return
        }
    }

    // MARK: - Open in browser

    /// Opens a new browser tab (optionally at a normalized URL), switches the
    /// panel to browser mode, and persists.
    public func openBrowserTab(urlString: String? = nil) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        _ = state.openBrowserTab(urlString: Self.normalizedBrowserURLString(urlString))
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .browser
        browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Navigates the selected browser tab to a normalized URL, no-op unless the
    /// selected tab is a browser tab.
    public func updateSelectedBrowserTab(urlString: String) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        guard state.selectedTab.kind == .browser else { return }
        state.updateBrowserTab(
            id: state.selectedTabID, urlString: Self.normalizedBrowserURLString(urlString))
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .browser
        browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Opens a local file at the given relative path in the browser preview after
    /// validating type, path containment, and existence. Returns `true` on
    /// success; on failure sets a browser-unavailable message and returns `false`.
    @discardableResult
    public func openFileInBrowser(relativePath: String) -> Bool {
        guard let selectedThreadID, let root = selectedThreadWorkingDirectory?() else {
            return false
        }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            setBrowserUnavailableMessage(
                "Browser preview requires a file path.", threadID: selectedThreadID)
            return false
        }
        guard Self.isBrowserPreviewSupported(relativePath: normalizedPath) else {
            setBrowserUnavailableMessage(
                "Unsupported browser preview type: \(normalizedPath)", threadID: selectedThreadID)
            return false
        }
        guard !normalizedPath.split(separator: "/").contains("..") else {
            setBrowserUnavailableMessage(
                "Browser preview is limited to files under the selected thread.",
                threadID: selectedThreadID)
            return false
        }
        let standardizedRoot = root.standardizedFileURL
        let fileURL = standardizedRoot.appendingPathComponent(normalizedPath).standardizedFileURL
        let rootPath =
            standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path : "\(standardizedRoot.path)/"
        guard fileURL.path.hasPrefix(rootPath) else {
            setBrowserUnavailableMessage(
                "Browser preview is limited to files under the selected thread.",
                threadID: selectedThreadID)
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            setBrowserUnavailableMessage(
                "Browser preview file does not exist: \(normalizedPath)", threadID: selectedThreadID
            )
            return false
        }
        setSelectedFile(normalizedPath)
        var state = selectedRightPanelState
        _ = state.openBrowserTab(urlString: fileURL.absoluteString, relativePath: normalizedPath)
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .browser
        browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        persistRightPanel(threadID: selectedThreadID)
        return true
    }

    private func setBrowserUnavailableMessage(_ message: String, threadID: UUID) {
        browserUnavailableMessagesByThreadID[threadID] = message
    }

    // MARK: - Type helpers

    /// Whether the file at the given relative path has an extension the browser
    /// preview can render (HTML, images, PDF, markdown, text, JSON, XML).
    public static func isBrowserPreviewSupported(relativePath: String) -> Bool {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        let supportedExtensions: Set<String> = [
            "html", "htm", "svg", "pdf", "png", "jpg", "jpeg", "gif", "webp", "txt", "json", "xml",
            "md", "markdown",
        ]
        return supportedExtensions.contains(
            URL(fileURLWithPath: normalizedPath).pathExtension.lowercased())
    }

    /// Whether the file at the given relative path is markdown or HTML.
    public static func isMarkdownOrHTML(relativePath: String) -> Bool {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        return ["md", "markdown", "html", "htm"].contains(
            URL(fileURLWithPath: normalizedPath).pathExtension.lowercased())
    }

    static func normalizedBrowserURLString(_ urlString: String?) -> String? {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty
        else { return nil }
        if urlString.contains("://") || urlString.hasPrefix("file:") { return urlString }
        if urlString.hasPrefix("localhost") || urlString.hasPrefix("127.0.0.1")
            || urlString.hasPrefix("[::1]")
        {
            return "http://\(urlString)"
        }
        return "https://\(urlString)"
    }

    func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
