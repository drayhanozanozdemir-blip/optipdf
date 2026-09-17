import CryptoKit
import PDFKit
import UIKit

/// Notes, highlights, text boxes and drawings of a large PDF live in a small side file, never in the PDF itself.
/// Writing the 1514-page Bolognia PDF re-draws every page (far longer than iOS allows, and it competes with
/// reading for PDFKit's locks), so large documents are not rewritten while studying. The side file is a tiny PDF
/// with one blank page per annotated page carrying copies of OptiPDF's annotations; its subject holds the page
/// numbers. It lives in Application Support, keyed by the file's content.
final class AnnotationSidecar {
    /// Documents with more pages use the side file; smaller ones keep saving into the PDF.
    static let pageThreshold = 150
    /// userName of annotations OptiPDF created or took over (drawings use "OptiPDF.Drawing").
    static let marker = "OptiPDF"

    private struct Index: Codable {
        let pageCount: Int
        let pages: [Int]
    }

    struct PageMarks {
        let index: Int
        let mediaBox: CGRect
        let cropBox: CGRect
        let rotation: Int
        let annotations: [PDFAnnotation]
    }

    /// The original file, for exporting a copy without re-encoding the open document.
    let sourceData: Data?
    private let fileURL: URL
    private let queue = DispatchQueue(label: "ch.ozan.optipdf.sidecar", qos: .utility)
    private var markedPages: Set<Int> = []
    private var pendingSave: DispatchWorkItem?
    private var dirty = false

    init(key: String, directory: URL? = nil, sourceData: Data? = nil) {
        fileURL = (directory ?? DocumentLibrary.shared.directory).appendingPathComponent(key + ".pdf")
        self.sourceData = sourceData
    }

    /// Size plus first and last megabyte: stable for the same file, cheap for a 300 MB book.
    static func key(for data: Data) -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data.prefix(1 << 20))
        hasher.update(data: data.suffix(1 << 20))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isOurs(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName?.hasPrefix(marker) == true
    }

    var markedPageIndices: [Int] { markedPages.sorted() }

    /// Puts the stored annotations back on their pages. False when there is no side file or it belongs to a
    /// document with a different number of pages.
    @discardableResult
    func apply(to document: PDFDocument) -> Bool {
        guard let stored = PDFDocument(url: fileURL),
              let subject = stored.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
              let index = try? JSONDecoder().decode(Index.self, from: Data(subject.utf8)),
              index.pageCount == document.pageCount, index.pages.count == stored.pageCount else { return false }
        for (position, pageIndex) in index.pages.enumerated() {
            guard let source = stored.page(at: position), let target = document.page(at: pageIndex) else { continue }
            let incoming = source.annotations.compactMap { $0.copy() as? PDFAnnotation }
            // Annotations taken over from the PDF are stored as copies; drop the originals so nothing appears twice.
            for annotation in target.annotations where Self.isOurs(annotation) || incoming.contains(where: { Self.same($0, annotation) }) {
                target.removeAnnotation(annotation)
            }
            incoming.forEach(target.addAnnotation)
            markedPages.insert(pageIndex)
        }
        return true
    }

    func pagesChanged(_ indices: [Int]) {
        markedPages.formUnion(indices.filter { $0 >= 0 })
        dirty = true
    }

    /// Writes one second after the last edit.
    func scheduleSave(from document: PDFDocument) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            self.saveNow(from: document)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Copies the annotations on the main thread and writes them on a background queue.
    func saveNow(from document: PDFDocument, completion: (() -> Void)? = nil) {
        pendingSave?.cancel()
        pendingSave = nil
        dirty = false
        let snapshot = collect(from: document)
        queue.async {
            self.write(pageCount: snapshot.pageCount, pages: snapshot.pages)
            completion?()
        }
    }

    /// Saves pending edits before the app is suspended or the document closes.
    func flush(from document: PDFDocument) {
        guard dirty else { return }
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "OptiPDF notes", expirationHandler: nil)
        saveNow(from: document) {
            DispatchQueue.main.async { application.endBackgroundTask(task) }
        }
    }

    func collect(from document: PDFDocument) -> (pageCount: Int, pages: [PageMarks]) {
        var pages: [PageMarks] = []
        for index in markedPages.sorted() {
            guard let page = document.page(at: index) else { continue }
            let copies = page.annotations.filter(Self.isOurs).compactMap { $0.copy() as? PDFAnnotation }
            guard !copies.isEmpty else { continue }
            pages.append(PageMarks(index: index, mediaBox: page.bounds(for: .mediaBox), cropBox: page.bounds(for: .cropBox),
                                   rotation: page.rotation, annotations: copies))
        }
        markedPages = Set(pages.map(\.index))
        return (document.pageCount, pages)
    }

    func write(pageCount: Int, pages: [PageMarks]) {
        let manager = FileManager.default
        guard !pages.isEmpty else {
            try? manager.removeItem(at: fileURL)
            return
        }
        let output = PDFDocument()
        for marks in pages {
            let page = PDFPage()
            page.setBounds(marks.mediaBox, for: .mediaBox)
            page.setBounds(marks.cropBox, for: .cropBox)
            page.rotation = marks.rotation
            marks.annotations.forEach(page.addAnnotation)
            output.insert(page, at: output.pageCount)
        }
        guard let index = try? JSONEncoder().encode(Index(pageCount: pageCount, pages: pages.map(\.index))) else { return }
        output.documentAttributes = [PDFDocumentAttribute.subjectAttribute: String(decoding: index, as: UTF8.self)]
        guard let data = output.dataRepresentation() else { return }
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func same(_ a: PDFAnnotation, _ b: PDFAnnotation) -> Bool {
        let kind = { (annotation: PDFAnnotation) in (annotation.type ?? "").replacingOccurrences(of: "/", with: "") }
        return kind(a) == kind(b) && abs(a.bounds.minX - b.bounds.minX) < 1 && abs(a.bounds.minY - b.bounds.minY) < 1
            && abs(a.bounds.width - b.bounds.width) < 1 && abs(a.bounds.height - b.bounds.height) < 1
    }
}
