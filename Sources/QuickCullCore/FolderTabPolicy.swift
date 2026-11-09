import Foundation

/// Where a folder open lands.
///
/// Plain navigation (sidebar click, Open Folder, search) auto-opens a tab
/// so the folder you were just in stays put. A folder already open is
/// focused instead of duplicated. An empty tab is filled rather than left
/// blank beside a new one. Past the cap, the oldest background tab is
/// reused. Keyboard moves and ⌥-click pass `replacingActive` and stay in
/// the current tab.
public enum FolderTabPolicy {

    public static let maxTabs = 12

    public struct Tab: Equatable {
        /// Standardized folder path. Nil is an empty "New Tab".
        public var path: String?

        public init(path: String?) {
            self.path = path
        }
    }

    public enum Action: Equatable {
        /// The folder is already open. Switch to this tab (no-op if current).
        case focusExisting(Int)
        /// Load into the active tab. Empty placeholder, or an explicit
        /// replace (keyboard / ⌥-click).
        case fillActive
        /// Append a tab and load there.
        case spawn
        /// At the cap. Load into this background tab and focus it.
        case reuseOldestBackground(Int)
    }

    public static func decide(
        opening path: String,
        tabs: [Tab],
        activeIndex: Int,
        replacingActive: Bool,
        maxTabs: Int = FolderTabPolicy.maxTabs
    ) -> Action {
        if let existing = tabs.firstIndex(where: { $0.path == path }) {
            return .focusExisting(existing)
        }
        let activeIsEmpty = tabs.indices.contains(activeIndex) && tabs[activeIndex].path == nil
        if replacingActive || activeIsEmpty || tabs.isEmpty {
            return .fillActive
        }
        let cap = max(1, maxTabs)
        if tabs.count >= cap {
            let oldest = activeIndex == 0 ? min(1, tabs.count - 1) : 0
            return .reuseOldestBackground(oldest)
        }
        return .spawn
    }
}
