import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct OptiPDFApp: App {
    init() {
        DocumentLibrary.shared.prepare()
        DiagnosticsCollector.shared.start()
    }

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
    /// Large PDFs keep OptiPDF's notes and drawings in a side file instead of being rewritten (AnnotationSidecar).
    private(set) var sidecar: AnnotationSidecar?
    /// Last page and bookmarks; nil for a document that was just created.
    private(set) var reading: ReadingState?

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
        let key = AnnotationSidecar.key(for: data)
        reading = ReadingState(key: key, directory: DocumentLibrary.shared.directory)
        if document.pageCount > AnnotationSidecar.pageThreshold {
            let store = AnnotationSidecar(key: key, sourceData: data)
            store.apply(to: document)
            sidecar = store
        }
    }

    func snapshot(contentType: UTType) throws -> PDFDocument { pdf }

    /// Saving asks for the snapshot and the file wrapper on the main thread (UIDocument contents(forType:)),
    /// so the wrapper must not encode yet; see PDFFileWrapper.
    func fileWrapper(snapshot: PDFDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        PDFFileWrapper(document: snapshot)
    }
}

/// Encodes the PDF only when UIDocument writes the file on its file-access queue. Encoding the 1514-page
/// Bolognia PDF inside contents(forType:) blocked the main thread past the 10-second scene watchdog while the
/// app went to the background, and iOS killed OptiPDF (0x8BADF00D, build 20, 17.09.2026).
final class PDFFileWrapper: FileWrapper {
    private let document: PDFDocument
    private let lock = NSLock()
    private var encoded: Data?
#if DEBUG
    static var lastEncodeOnMainThread: Bool?
#endif

    init(document: PDFDocument) {
        self.document = document
        super.init(regularFileWithContents: Data())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var regularFileContents: Data? { encode() }

    override func write(to url: URL, options: FileWrapper.WritingOptions, originalContentsURL: URL?) throws {
        guard let data = encode() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    private func encode() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if encoded == nil {
#if DEBUG
            Self.lastEncodeOnMainThread = Thread.isMainThread
#endif
            encoded = document.dataRepresentation()
        }
        return encoded
    }
}
