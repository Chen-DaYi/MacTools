import Foundation

/// Pure state machine for one folder-title inline-rename session (design §2.3).
///
/// The hard problem it solves is the SINGLE-RESOLUTION latch: a Return both fires
/// `insertNewline` AND (via the refocus that follows) a native end-editing notification;
/// an Esc-cancel is followed by the same end-editing. Without the latch the second event
/// would commit again — after a cancel, committing the very text the user just discarded.
/// `hasResolved` guarantees a session resolves exactly once; the store's no-change guard
/// is the independent second line of defence.
///
/// Internal + value-typed so the resolution table is unit-testable without AppKit
/// (the established "extract the drag logic into internal methods" pattern).
struct LaunchpadRenameEditSession: Equatable {
    /// How a session ended. `commit` carries the raw text (the store trims and applies the
    /// empty-name fallback); `cancel` carries the original name the field should restore.
    enum Resolution: Equatable {
        case commit(String)
        case cancel(restore: String)
    }

    private(set) var originalName: String
    private(set) var currentText: String
    private(set) var hasResolved = false

    /// The field became first responder: snapshot the name Esc restores.
    static func begin(originalName: String) -> LaunchpadRenameEditSession {
        LaunchpadRenameEditSession(originalName: originalName, currentText: originalName)
    }

    /// Live text mirror while editing. Ignored after resolution — a stale field-editor
    /// notification must not mutate a finished session.
    mutating func textChanged(_ text: String) {
        guard !hasResolved else { return }
        currentText = text
    }

    /// Return key (or an explicit programmatic commit). At most one resolution per session.
    mutating func commit() -> Resolution? {
        guard !hasResolved else { return nil }
        hasResolved = true
        return .commit(currentText)
    }

    /// Esc: discard edits, restore the original name. At most one resolution per session.
    mutating func cancel() -> Resolution? {
        guard !hasResolved else { return nil }
        hasResolved = true
        return .cancel(restore: originalName)
    }

    /// Focus loss / panel unmount: commits — unless Return/Esc already resolved this
    /// session, in which case this is the trailing native end-editing and must be inert.
    mutating func endEditing() -> Resolution? {
        commit()
    }
}
