import SwiftUI
import UniformTypeIdentifiers

/// Wraps the G-code text so the system's Save dialog can write it wherever
/// the user picks (Files, iCloud Drive, a USB stick or SD card).
nonisolated struct GCodeDocument: FileDocument {
    /// The system has no built-in "G-code" type; plain text is the fallback
    /// and the ".gcode" ending comes from the suggested file name.
    static let gcodeType = UTType(filenameExtension: "gcode") ?? .plainText
    static let readableContentTypes = [gcodeType, .plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
