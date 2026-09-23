import Foundation
import UniformTypeIdentifiers

/// Which surface draws a file in the preview. See docs/features/file-search.md#palette-and-actions.
enum FileSearchPreviewKind: Equatable, Sendable {
    case quickLook
    /// QuickLook draws a PDF out of process, and that remote view never scrolls in the palette.
    case pdf
    /// QuickLook draws a movie's first frame but never plays one inside a non-activating panel.
    case media
    /// Text QuickLook would draw as an icon: it renders only a declared `public.text` as text.
    case text

    /// Nil when only the bytes can tell: an undeclared type, or `.ts`, TypeScript or MPEG-TS video.
    init?(pathExtension: String) {
        guard let type = UTType(filenameExtension: pathExtension), !type.isDynamic,
            !type.conforms(to: .mpeg2TransportStream)
        else { return nil }
        self = Self.declared(type)
    }

    /// For an extension that left it open: text if the bytes are, otherwise what it declares.
    init(pathExtension: String, head: Data, isWholeFile: Bool) {
        guard !Self.isText(head, isWholeFile: isWholeFile) else {
            self = .text
            return
        }
        self = UTType(filenameExtension: pathExtension).map(Self.declared) ?? .quickLook
    }

    private static func declared(_ type: UTType) -> Self {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return .media }
        return .quickLook
    }

    /// No NUL and valid UTF-8, forgiving the one character a partial read may have cut in half.
    static func isText(_ bytes: Data, isWholeFile: Bool) -> Bool {
        guard !bytes.contains(0) else { return false }
        let cut = isWholeFile ? 0 : min(3, bytes.count)
        return (0...cut).contains { String(validating: bytes.dropLast($0), as: UTF8.self) != nil }
    }
}
