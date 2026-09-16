import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct OptiPDFApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PDFFile() }) { configuration in
            EditorView(file: configuration.document,
                       title: configuration.fileURL?.deletingPathExtension().lastPathComponent ?? "OptiPDF")
        }
    }
}

/// A PDF opened in place from Files. Edits live in the PDFDocument; the undo manager marks the file dirty
/// and the system autosaves the PDF with its annotations.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let pdf: PDFDocument

    /// "Create document" gives a blank A4 page to write and draw on.
    init() {
        let size = CGSize(width: 595, height: 842)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        pdf = PDFDocument()
        if let page = PDFPage(image: image) { pdf.insert(page, at: 0) }
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let document = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pdf = document
    }

    func snapshot(contentType: UTType) throws -> Data {
        guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
