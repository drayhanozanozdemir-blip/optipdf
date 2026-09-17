import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct OptiPDFApp: App {
    var body: some Scene {
#if READER_PROBE
        WindowGroup { ReaderPreview() }
#else
        documents
#endif
    }

    private var documents: some Scene {
        DocumentGroup(newDocument: { PDFFile() }) { configuration in
            EditorView(file: configuration.document,
                       title: configuration.fileURL?.deletingPathExtension().lastPathComponent ?? "OptiPDF")
        }
    }
}

#if DEBUG
private struct ReaderPreview: View {
    @StateObject private var file = PDFFile(preview: true)

    var body: some View {
        NavigationStack {
            EditorView(file: file, title: "Reader Preview")
        }
    }
}
#endif

/// A PDF opened in place from Files. Edits live in the PDFDocument; the undo manager marks the file dirty
/// and the system autosaves the PDF with its annotations.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let pdf: PDFDocument

#if DEBUG
    init(preview: Bool) {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for number in 1...1000 {
                context.beginPage()
                let text = "Reader page \(number)\n\nSelectable dermatology preview text.\n\n" + String(repeating: "Psoriasis and dermatitis can be compared using morphology and distribution.\n\n", count: 12)
                (text as NSString).draw(in: bounds.insetBy(dx: 48, dy: 60),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
        }
        pdf = PDFDocument(data: data)!
    }
#endif

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

    /// SwiftUI takes the snapshot on the main thread and writes it on a background thread. Encoding a
    /// 1000-page PDF takes seconds, so the main thread only hands over the document and autosave never
    /// freezes reading or drawing.
    func snapshot(contentType: UTType) throws -> PDFDocument { pdf }

    func fileWrapper(snapshot: PDFDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = snapshot.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return FileWrapper(regularFileWithContents: data)
    }
}
