import Foundation

/// One grid's folder-load token.
///
/// A sidebar click used to leave the previous folder's cells up until the
/// new directory listing returned, so a fast click showed the wrong photos
/// and a second click could apply the slower listing last. `begin` bumps
/// the generation and says whether the visible set must be cleared now.
/// Only `accepts` the generation that `begin` just issued.
public struct FolderLoadGate: Equatable {
    public private(set) var generation: Int = 0
    public private(set) var path: String?

    public struct Ticket: Equatable {
        public var generation: Int
        /// True when this load is a different folder than the one on screen.
        /// Same-folder reloads (a watcher, undo) keep the current cells.
        public var blank: Bool

        public init(generation: Int, blank: Bool) {
            self.generation = generation
            self.blank = blank
        }
    }

    public init() {}

    public mutating func begin(to path: String) -> Ticket {
        let blank = self.path != path
        generation += 1
        self.path = path
        return Ticket(generation: generation, blank: blank)
    }

    public func accepts(_ generation: Int) -> Bool {
        generation == self.generation
    }
}
