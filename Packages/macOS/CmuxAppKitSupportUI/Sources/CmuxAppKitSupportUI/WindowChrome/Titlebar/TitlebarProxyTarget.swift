import Foundation

/// What the window titlebar's leading drag icon (the proxy icon) represents.
///
/// The icon follows the focused surface instead of always showing a folder: a
/// file-backed surface (Markdown viewer, file preview) stands for the document
/// it shows, every other surface stands for the workspace directory. Keeping
/// the choice in one value means the glyph, the drag payload, and the
/// right-click path menu can never disagree.
public enum TitlebarProxyTarget: Equatable, Sendable {
    /// Terminal, browser, and other surfaces that keep the folder icon.
    case directory(String)
    /// The file a Markdown viewer or file preview shows.
    case file(String)

    /// Path handed to the drag pasteboard when the icon is dragged out.
    public var path: String {
        switch self {
        case let .directory(path), let .file(path):
            return path
        }
    }

    /// Folder whose ancestors the right-click path menu lists.
    ///
    /// Document windows list the folders that contain the document, so a file
    /// resolves to its parent folder.
    public var menuDirectory: String {
        switch self {
        case let .directory(path):
            return path
        case let .file(path):
            return (path as NSString).deletingLastPathComponent
        }
    }

    /// Whether the dragged item is a folder.
    public var isDirectory: Bool {
        guard case .directory = self else { return false }
        return true
    }
}

extension TitlebarProxyTarget {
    /// Picks the proxy target for the current focus.
    ///
    /// - Parameters:
    ///   - focusedDirectory: The focused surface's directory, when it reports one.
    ///   - focusedFile: The file the focused surface shows, when it is file-backed.
    /// - Returns: The focused file when there is one, otherwise the directory,
    ///   otherwise `nil` so the titlebar draws no proxy icon.
    public static func resolve(
        focusedDirectory: String?,
        focusedFile: String?
    ) -> TitlebarProxyTarget? {
        if let file = normalized(focusedFile) {
            return .file(file)
        }
        if let directory = normalized(focusedDirectory) {
            return .directory(directory)
        }
        return nil
    }

    private static func normalized(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
