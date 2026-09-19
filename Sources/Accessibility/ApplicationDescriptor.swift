// @acid: APP-1, APP-2, APP-3, APP-4, APP-10, INV-1, INV-6
import Foundation
import AppKit

/// Immutable semantic descriptor of an application in the system catalog.
/// Represents either a running process, an installed application bundle, or both.
public struct ApplicationDescriptor: Identifiable, Sendable, Codable, Hashable, Equatable {
    /// Unique identifier for the application descriptor (bundle ID or synthetic stable ID).
    public let applicationId: String

    /// Localized display name of the application (e.g. "Safari", "Visual Studio Code").
    public let displayName: String

    /// CFBundleIdentifier if available (e.g. "com.apple.Safari").
    public let bundleIdentifier: String?

    /// Unix process identifier if the application is currently running.
    public let processIdentifier: pid_t?

    /// URL to the .app bundle on disk if installed.
    public let bundleURL: URL?

    /// URL to the main executable binary within the bundle if available.
    public let executableURL: URL?

    /// True if the application bundle is installed on disk.
    public let isInstalled: Bool

    /// True if the application is currently running as an OS process.
    public let isRunning: Bool

    /// True once a running application has finished launching through Workspace.
    public let isFinishedLaunching: Bool

    /// True if the application is currently frontmost / active.
    public let isActive: Bool

    /// True if the application process is hidden.
    public let isHidden: Bool

    /// True if the application process is accessible via macOS Accessibility APIs.
    public let isAccessibilityAvailable: Bool

    /// Enumerated top-level windows for running applications. Empty for non-running apps.
    public let windows: [WindowDescriptor]

    public var id: String { applicationId }

    /// Convenience alias for `displayName`.
    public var name: String { displayName }

    /// Convenience alias for `processIdentifier`.
    public var pid: pid_t? { processIdentifier }

    public init(
        applicationId: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        processIdentifier: pid_t? = nil,
        bundleURL: URL? = nil,
        executableURL: URL? = nil,
        isInstalled: Bool = true,
        isRunning: Bool = false,
        isFinishedLaunching: Bool = false,
        isActive: Bool = false,
        isHidden: Bool = false,
        isAccessibilityAvailable: Bool = false,
        windows: [WindowDescriptor] = []
    ) {
        self.applicationId = applicationId
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.isFinishedLaunching = isFinishedLaunching
        self.isActive = isActive
        self.isHidden = isHidden
        self.isAccessibilityAvailable = isAccessibilityAvailable
        self.windows = windows
    }
}

/// Immutable semantic descriptor of an accessible application window.
///
/// Invariant (INV-6): Window position, pixel dimensions, display scale, overlap, and
/// occlusion never participate in target identity or window representation.
public struct WindowDescriptor: Identifiable, Sendable, Codable, Hashable, Equatable {
    /// Stable opaque identifier for this window within the application session.
    public let id: String

    /// Window title as reported by the accessibility tree (e.g. "Inbox (3) - Mail").
    public let title: String?

    /// Accessibility role (e.g. "AXWindow").
    public let role: String

    /// Accessibility subrole (e.g. "AXStandardWindow", "AXDialog", "AXFloatingWindow").
    public let subrole: String?

    /// True if the window is currently minimized to the Dock.
    public let isMinimized: Bool

    /// True if the window is the application's main window.
    public let isMain: Bool

    /// True if the window currently has keyboard focus.
    public let isFocused: Bool

    public init(
        id: String,
        title: String? = nil,
        role: String = "AXWindow",
        subrole: String? = nil,
        isMinimized: Bool = false,
        isMain: Bool = false,
        isFocused: Bool = false
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.isMain = isMain
        self.isFocused = isFocused
    }
}

/// Typed errors produced during application catalog discovery, resolution, and lifecycle control.
public enum ApplicationCatalogError: LocalizedError, Sendable, Equatable {
    /// macOS Accessibility permissions are missing or not trusted for this process.
    case accessibilityPermissionDenied

    /// No running or installed application matched the requested query.
    case applicationNotFound(query: String)

    /// Multiple viable applications matched the query without a clear resolution.
    case ambiguousApplication(query: String, candidates: [ApplicationDescriptor])

    /// Application launch failed through NSWorkspace.
    case launchFailed(name: String, reason: String)

    /// Application activation failed or did not become frontmost within the allowed budget.
    case activationFailed(name: String, reason: String)

    /// Window matching the given ID was not found in the target application.
    case windowNotFound(windowId: String, appName: String)

    /// Accessibility action or attribute modification on a window failed.
    case windowActionFailed(windowId: String, action: String, axErrorCode: Int32)

    /// An asynchronous operation timed out before meeting its readiness condition.
    case timeout(operation: String, duration: TimeInterval)

    /// Underlying macOS Accessibility API error.
    case axError(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "macOS Accessibility permission is not granted. Please enable Accessibility for JevOrb in System Settings -> Privacy & Security -> Accessibility."
        case .applicationNotFound(let query):
            return "Application not found matching '\(query)'."
        case .ambiguousApplication(let query, let candidates):
            let names = candidates.map { "\($0.displayName) (\($0.bundleIdentifier ?? "no bundle ID"))" }.joined(separator: ", ")
            return "Ambiguous application query '\(query)'. Matches: [\(names)]."
        case .launchFailed(let name, let reason):
            return "Failed to launch application '\(name)': \(reason)"
        case .activationFailed(let name, let reason):
            return "Failed to activate application '\(name)': \(reason)"
        case .windowNotFound(let windowId, let appName):
            return "Window '\(windowId)' was not found in application '\(appName)'."
        case .windowActionFailed(let windowId, let action, let code):
            return "Failed to perform '\(action)' on window '\(windowId)' (AXError code: \(code))."
        case .timeout(let operation, let duration):
            return "Operation '\(operation)' timed out after \(String(format: "%.2f", duration)) seconds."
        case .axError(let code, let message):
            return "Accessibility API error (\(code)): \(message)"
        }
    }
}
