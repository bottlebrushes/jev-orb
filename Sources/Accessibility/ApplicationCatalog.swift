import AppKit
import ApplicationServices

/// Workspace discovery and AX window control. Window handles never leave the catalog API.
@MainActor
final class ApplicationCatalog {
    enum Scope { case running, installed, all }

    private struct WindowRecord {
        let id: String
        let element: AXUIElement
    }

    private let workspace: NSWorkspace
    private let aliases: [String: String]
    private let applicationDirectories: [URL]
    private var installedCache: [ApplicationDescriptor]?
    private var directoryDates: [URL: Date] = [:]
    private var windowRecords: [pid_t: [WindowRecord]] = [:]
    private let metadataQuery = NSMetadataQuery()
    private var metadataObservers: [NSObjectProtocol] = []

    init(workspace: NSWorkspace = .shared, aliases: [String: String] = [:]) {
        self.workspace = workspace
        self.aliases = aliases
        applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]
        metadataQuery.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "com.apple.application-bundle")
        metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            metadataObservers.append(NotificationCenter.default.addObserver(forName: name, object: metadataQuery, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.installedCache = nil }
            })
        }
        metadataQuery.start()
    }

    deinit {
        metadataQuery.stop()
        for observer in metadataObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Discovery is available without AX permission. Explicit window reads report typed AX failures.
    func runningApplications(includeWindows: Bool = true) -> [ApplicationDescriptor] {
        let applications = workspace.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let pids = Set(applications.map(\.processIdentifier))
        windowRecords = windowRecords.filter { pids.contains($0.key) }
        return sorted(applications.map { app in
            let windows = includeWindows ? try? self.windows(for: app.processIdentifier) : nil
            return descriptor(app, windows: windows ?? [], accessible: windows != nil)
        })
    }

    func installedApplications(refresh: Bool = false) -> [ApplicationDescriptor] {
        let currentDates = modificationDates()
        if !refresh, let installedCache, currentDates == directoryDates { return installedCache }
        var urls = Set<URL>()
        metadataQuery.disableUpdates()
        for index in 0..<metadataQuery.resultCount {
            if let item = metadataQuery.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.insert(URL(fileURLWithPath: path).standardizedFileURL)
            }
        }
        metadataQuery.enableUpdates()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        var discoveredDates = currentDates
        for root in applicationDirectories {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true else { continue }
                if url.pathExtension.lowercased() == "app" {
                    urls.insert(url.standardizedFileURL)
                    enumerator.skipDescendants()
                } else if values?.isPackage == true {
                    enumerator.skipDescendants()
                } else if let date = values?.contentModificationDate {
                    discoveredDates[url] = date
                }
            }
        }
        let result = sorted(urls.compactMap(installedDescriptor))
        installedCache = result
        directoryDates = discoveredDates
        return result
    }

    /// Running instances and installed bundles remain separate inventories; `.all` prefers an existing instance.
    func resolve(_ query: String, scope: Scope = .all) throws -> ApplicationDescriptor {
        let key = normalized(query)
        guard !key.isEmpty else { throw ApplicationCatalogError.applicationNotFound(query: query) }
        func inventory(refresh: Bool) -> [ApplicationDescriptor] {
            switch scope {
            case .running: return runningApplications(includeWindows: false)
            case .installed: return installedApplications(refresh: refresh)
            case .all:
                let running = runningApplications(includeWindows: false)
                let runningURLs = Set(running.compactMap(\.bundleURL))
                return running + installedApplications(refresh: refresh).filter { !runningURLs.contains($0.bundleURL ?? URL(fileURLWithPath: "/")) }
            }
        }
        if let match = try resolve(query, key: key, in: inventory(refresh: false)) { return match }
        if scope != .running, let match = try resolve(query, key: key, in: inventory(refresh: true)) { return match }
        throw ApplicationCatalogError.applicationNotFound(query: query)
    }

    func activate(_ application: ApplicationDescriptor, timeout: TimeInterval = 5) async throws -> ApplicationDescriptor {
        try Task.checkCancellation()
        let app = try runningInstance(application)
        guard app.activate(options: []) else {
            throw ApplicationCatalogError.activationFailed(name: application.displayName, reason: "Workspace rejected activation.")
        }
        try await waitForState(operation: "activate \(application.displayName)", timeout: timeout) {
            guard !app.isTerminated else { throw ApplicationCatalogError.applicationNotFound(query: application.displayName) }
            return app.isFinishedLaunching && self.workspace.frontmostApplication?.processIdentifier == app.processIdentifier
        }
        return descriptor(app)
    }

    func launch(_ application: ApplicationDescriptor, timeout: TimeInterval = 10) async throws -> ApplicationDescriptor {
        try Task.checkCancellation()
        let candidates = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
            (($0.bundleURL != nil && $0.bundleURL == application.bundleURL) ||
             ($0.bundleIdentifier != nil && $0.bundleIdentifier == application.bundleIdentifier))
        }
        if candidates.count > 1 {
            throw ApplicationCatalogError.ambiguousApplication(query: application.displayName, candidates: candidates.map { descriptor($0) })
        }
        if let running = candidates.first { return try await activate(descriptor(running), timeout: timeout) }
        guard let url = application.bundleURL, installedDescriptor(url) != nil else {
            throw ApplicationCatalogError.launchFailed(name: application.displayName, reason: "No launchable application bundle exists at the catalog URL.")
        }
        let duration = boundedTimeout(timeout)
        let started = ContinuousClock.now
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let stream = AsyncThrowingStream<NSRunningApplication, Error> { continuation in
            let deadline = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(duration))
                    continuation.finish(throwing: ApplicationCatalogError.timeout(operation: "launch \(application.displayName)", duration: duration))
                } catch { }
            }
            continuation.onTermination = { _ in deadline.cancel() }
            workspace.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.finish(throwing: ApplicationCatalogError.launchFailed(name: application.displayName, reason: error.localizedDescription))
                } else if let app {
                    continuation.yield(app)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ApplicationCatalogError.launchFailed(name: application.displayName, reason: "Workspace returned no application."))
                }
            }
        }
        for try await app in stream {
            try Task.checkCancellation()
            guard app.activationPolicy == .regular else {
                throw ApplicationCatalogError.launchFailed(name: application.displayName, reason: "The launched process is not a regular GUI application.")
            }
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard seconds < duration else { throw ApplicationCatalogError.timeout(operation: "launch \(application.displayName)", duration: duration) }
            try await waitForState(operation: "launch \(application.displayName)", timeout: duration - seconds) {
                guard !app.isTerminated else { throw ApplicationCatalogError.launchFailed(name: application.displayName, reason: "The process terminated while launching.") }
                return app.isFinishedLaunching && self.workspace.frontmostApplication?.processIdentifier == app.processIdentifier
            }
            installedCache = nil
            return descriptor(app)
        }
        try Task.checkCancellation()
        throw ApplicationCatalogError.launchFailed(name: application.displayName, reason: "Workspace did not return a running application.")
    }

    func windows(for pid: pid_t) throws -> [WindowDescriptor] {
        let root = try applicationElement(pid)
        let elements = try attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let focused = try attribute(root, kAXFocusedWindowAttribute)
        let main = try attribute(root, kAXMainWindowAttribute)
        let old = windowRecords[pid] ?? []
        let records = elements.map { element in
            old.first { CFEqual($0.element, element) } ?? WindowRecord(id: UUID().uuidString, element: element)
        }
        var result: [WindowDescriptor] = []
        for record in records {
            let title = try attribute(record.element, kAXTitleAttribute) as? String
            let role = try attribute(record.element, kAXRoleAttribute) as? String ?? kAXWindowRole
            let subrole = try attribute(record.element, kAXSubroleAttribute) as? String
            let minimized = try attribute(record.element, kAXMinimizedAttribute) as? Bool ?? false
            let isMain = try attribute(record.element, kAXMainAttribute) as? Bool ?? false
            let isFocused = try attribute(record.element, kAXFocusedAttribute) as? Bool ?? false
            result.append(WindowDescriptor(id: record.id, title: title, role: role, subrole: subrole,
                                           isMinimized: minimized, isMain: isMain || main.map { CFEqual($0, record.element) } == true,
                                           isFocused: isFocused || focused.map { CFEqual($0, record.element) } == true))
        }
        windowRecords[pid] = records
        return result
    }

    /// Internal borrowing boundary for AXSession; descriptors never contain AX handles.
    func withWindow<T>(pid: pid_t, windowID: String, body: (AXUIElement) throws -> T) throws -> T {
        _ = try windows(for: pid)
        guard let record = windowRecords[pid]?.first(where: { $0.id == windowID }) else {
            throw ApplicationCatalogError.windowNotFound(windowId: windowID, appName: String(pid))
        }
        return try body(record.element)
    }

    func focusWindow(_ windowID: String, in application: ApplicationDescriptor, timeout: TimeInterval = 5) async throws -> WindowDescriptor {
        try Task.checkCancellation()
        let app = try runningInstance(application)
        // Validate before changing focus, including before activating the application.
        try withWindow(pid: app.processIdentifier, windowID: windowID) { _ in }
        let start = ContinuousClock.now
        let duration = boundedTimeout(timeout)
        _ = try await activate(application, timeout: duration)
        try Task.checkCancellation()
        try withWindow(pid: app.processIdentifier, windowID: windowID) { element in
            if try attribute(element, kAXMinimizedAttribute) as? Bool == true {
                try set(element, attribute: kAXMinimizedAttribute, value: kCFBooleanFalse, windowID: windowID, required: true)
            }
            var actions: CFArray?
            let status = AXUIElementCopyActionNames(element, &actions)
            try check(status, context: "read window actions")
            if (actions as? [String] ?? []).contains(kAXRaiseAction) {
                try check(AXUIElementPerformAction(element, kAXRaiseAction as CFString), context: "raise window")
            }
            try set(element, attribute: kAXMainAttribute, value: kCFBooleanTrue, windowID: windowID, required: false)
            try set(element, attribute: kAXFocusedAttribute, value: kCFBooleanTrue, windowID: windowID, required: false)
        }
        let elapsed = start.duration(to: .now)
        let remaining = duration - Double(elapsed.components.seconds) - Double(elapsed.components.attoseconds) / 1e18
        guard remaining > 0 else { throw ApplicationCatalogError.timeout(operation: "focus window", duration: duration) }
        var selected: WindowDescriptor?
        try await waitForState(operation: "focus window", timeout: remaining) {
            selected = try self.windows(for: app.processIdentifier).first { $0.id == windowID }
            guard let selected else { throw ApplicationCatalogError.windowNotFound(windowId: windowID, appName: application.displayName) }
            return self.workspace.frontmostApplication?.processIdentifier == app.processIdentifier && !selected.isMinimized && (selected.isMain || selected.isFocused)
        }
        guard let selected else { throw ApplicationCatalogError.windowNotFound(windowId: windowID, appName: application.displayName) }
        return selected
    }

    private func resolve(_ query: String, key: String, in inventory: [ApplicationDescriptor]) throws -> ApplicationDescriptor? {
        func unique(_ matches: [ApplicationDescriptor]) throws -> ApplicationDescriptor? {
            guard matches.count < 2 else { throw ApplicationCatalogError.ambiguousApplication(query: query, candidates: matches) }
            return matches.first
        }
        let exact = inventory.filter { $0.displayName.compare(query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if !exact.isEmpty { return try unique(exact) }
        let bundle = inventory.filter { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
        if !bundle.isEmpty { return try unique(bundle) }
        let aliasTargets = Set(aliases.filter { normalized($0.key) == key }.map { $0.value.lowercased() })
        if !aliasTargets.isEmpty {
            return try unique(inventory.filter { aliasTargets.contains($0.bundleIdentifier?.lowercased() ?? "") || aliasTargets.contains($0.displayName.lowercased()) })
        }
        return try unique(inventory.filter {
            let name = normalized($0.displayName)
            return name.hasPrefix(key) || name.split(separator: " ").contains { $0.hasPrefix(key) }
        })
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func sorted(_ applications: [ApplicationDescriptor]) -> [ApplicationDescriptor] {
        applications.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.applicationId < $1.applicationId : comparison == .orderedAscending
        }
    }

    private func descriptor(_ app: NSRunningApplication, windows: [WindowDescriptor] = [], accessible: Bool = false) -> ApplicationDescriptor {
        ApplicationDescriptor(applicationId: "pid:\(app.processIdentifier)", displayName: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? String(app.processIdentifier),
                              bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier, bundleURL: app.bundleURL,
                              executableURL: app.executableURL, isInstalled: app.bundleURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                              isRunning: !app.isTerminated, isFinishedLaunching: app.isFinishedLaunching, isActive: app.isActive, isHidden: app.isHidden,
                              isAccessibilityAvailable: accessible, windows: windows)
    }

    private func installedDescriptor(_ url: URL) -> ApplicationDescriptor? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path),
              (bundle.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber)?.boolValue != true,
              (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? NSNumber)?.boolValue != true else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        return ApplicationDescriptor(applicationId: "bundle:\(url.path)", displayName: name, bundleIdentifier: bundle.bundleIdentifier,
                                     bundleURL: url, executableURL: executable, isInstalled: true)
    }

    private func modificationDates() -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for url in Set(applicationDirectories).union(directoryDates.keys) {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { dates[url] = date }
        }
        return dates
    }

    private func runningInstance(_ application: ApplicationDescriptor) throws -> NSRunningApplication {
        guard let pid = application.processIdentifier, let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, app.activationPolicy == .regular,
              app.bundleIdentifier == application.bundleIdentifier, app.bundleURL == application.bundleURL else {
            throw ApplicationCatalogError.applicationNotFound(query: application.displayName)
        }
        return app
    }

    private func applicationElement(_ pid: pid_t) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw ApplicationCatalogError.accessibilityPermissionDenied }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, app.activationPolicy == .regular else {
            throw ApplicationCatalogError.applicationNotFound(query: String(pid))
        }
        let root = AXUIElementCreateApplication(pid)
        try check(AXUIElementSetMessagingTimeout(root, 0.5), context: "set AX timeout")
        return root
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status == .noValue || status == .attributeUnsupported { return nil }
        try check(status, context: "read \(name)")
        return value
    }

    private func check(_ status: AXError, context: String) throws {
        if status == .apiDisabled || !AXIsProcessTrusted() { throw ApplicationCatalogError.accessibilityPermissionDenied }
        guard status == .success else { throw ApplicationCatalogError.axError(code: status.rawValue, message: context) }
    }

    private func set(_ element: AXUIElement, attribute: String, value: CFTypeRef, windowID: String, required: Bool) throws {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if status == .attributeUnsupported || (status == .success && !settable.boolValue) {
            if required { throw ApplicationCatalogError.windowActionFailed(windowId: windowID, action: attribute, axErrorCode: AXError.attributeUnsupported.rawValue) }
            return
        }
        try check(status, context: "check \(attribute)")
        try check(AXUIElementSetAttributeValue(element, attribute as CFString, value), context: "set \(attribute)")
    }

    private func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        timeout.isFinite ? min(max(timeout, 0.01), 60) : 10
    }

    /// Notifications wake immediately; timer ticks only trigger independent readiness observations.
    private func waitForState(operation: String, timeout: TimeInterval, predicate: () throws -> Bool) async throws {
        let duration = boundedTimeout(timeout)
        let deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        let center = workspace.notificationCenter
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification]
        let observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield(()) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { continuation.yield(()) }
        timer.resume()
        defer {
            timer.cancel()
            observers.forEach(center.removeObserver)
            continuation.finish()
        }
        for await _ in stream {
            try Task.checkCancellation()
            if try predicate() { return }
            if ContinuousClock.now >= deadline { throw ApplicationCatalogError.timeout(operation: operation, duration: duration) }
        }
        try Task.checkCancellation()
    }
}
