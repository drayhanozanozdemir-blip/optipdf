import PDFKit

/// Page → chapter from the PDF outline, for the scrubber bubble ("S. 245 · Kapitel") and the page indicator. Built
/// once per document off the main thread (ReaderNavigation.prepareChapters); lookups are binary searches.
struct ChapterIndex: Sendable {
    struct Heading: Equatable, Sendable {
        let page: Int
        let title: String
        /// 0 = chapter (top level of the outline), deeper levels are sections.
        let depth: Int
    }

    struct Location: Equatable, Sendable {
        let chapter: String
        /// The deepest heading of the chapter that starts on or before the page, if it is not the chapter itself.
        let section: String?
    }

    /// Headings by page; headings on the same page keep their outline order.
    private let headings: [Heading]
    /// For each heading, the index in `headings` of its chapter (-1: none).
    private let owners: [Int]
    /// Indices in `headings` of the chapters, by page.
    private let chapters: [Int]
    /// Printed page labels ("xii", "245") when the PDF has its own, else nil.
    let labels: [String]?
    private let pagesByLabel: [String: Int]

    var isEmpty: Bool { headings.isEmpty }

    /// `outline` in outline order (pre-order), depth 0 = chapter.
    init(outline: [Heading], labels: [String]? = nil) {
        var owner: [Int] = []
        var chapter = -1
        for (index, heading) in outline.enumerated() {
            if heading.depth == 0 { chapter = index }
            owner.append(chapter)
        }
        let order = outline.indices.sorted {
            outline[$0].page != outline[$1].page ? outline[$0].page < outline[$1].page : $0 < $1
        }
        var sortedPosition = [Int](repeating: -1, count: outline.count)
        for (sorted, original) in order.enumerated() { sortedPosition[original] = sorted }
        headings = order.map { outline[$0] }
        owners = order.map { owner[$0] >= 0 ? sortedPosition[owner[$0]] : -1 }
        chapters = order.indices.filter { outline[order[$0]].depth == 0 }
        self.labels = labels
        var byLabel: [String: Int] = [:]
        for (index, label) in (labels ?? []).enumerated() {
            let key = label.lowercased()
            if !key.isEmpty && byLabel[key] == nil { byLabel[key] = index }
        }
        pagesByLabel = byLabel
    }

    /// Reads the outline and the page labels. Runs off the main thread; nothing here touches the view.
    init(document: PDFDocument) {
        self.init(outline: Self.headings(of: document), labels: Self.pageLabels(of: document))
    }

    func location(for page: Int) -> Location? {
        guard let chapterSlot = lastChapter(atOrBefore: page) else { return nil }
        let chapter = headings[chapterSlot]
        var section: String?
        if var slot = lastHeading(atOrBefore: page) {
            // Normally the heading right before the page; a heading filed under another chapter is skipped.
            var steps = 0
            while slot > chapterSlot && steps < 64 {
                if owners[slot] == chapterSlot {
                    section = headings[slot].title
                    break
                }
                slot -= 1
                steps += 1
            }
        }
        if section == chapter.title || section?.isEmpty == true { section = nil }
        return Location(chapter: chapter.title, section: section)
    }

    /// The page whose printed label is `label` ("612", "xii"), when the PDF has its own labels.
    func pageIndex(forLabel label: String) -> Int? {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : pagesByLabel[key]
    }

    private func lastHeading(atOrBefore page: Int) -> Int? {
        var low = 0
        var high = headings.count
        while low < high {
            let mid = (low + high) / 2
            if headings[mid].page <= page { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    private func lastChapter(atOrBefore page: Int) -> Int? {
        var low = 0
        var high = chapters.count
        while low < high {
            let mid = (low + high) / 2
            if headings[chapters[mid]].page <= page { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? chapters[low - 1] : nil
    }

    /// The outline's headings in outline order. A lone entry holding everything (usually the book's title) is not a
    /// chapter; a heading without its own link starts at its first linked sub-heading.
    static func headings(of document: PDFDocument) -> [Heading] {
        guard var top = document.outlineRoot else { return [] }
        while top.numberOfChildren == 1, let only = top.child(at: 0), only.numberOfChildren > 0 { top = only }
        var result: [Heading] = []
        var pageIndices: [ObjectIdentifier: Int] = [:]
        let pageCount = document.pageCount
        func index(of page: PDFPage?) -> Int? {
            guard let page else { return nil }
            if let known = pageIndices[ObjectIdentifier(page)] { return known }
            let found = document.index(for: page)
            guard found != NSNotFound, found >= 0, found < pageCount else { return nil }
            pageIndices[ObjectIdentifier(page)] = found
            return found
        }
        func visit(_ item: PDFOutline, depth: Int) {
            guard depth < 12 else { return }
            for childIndex in 0..<item.numberOfChildren {
                guard result.count < 20_000, let child = item.child(at: childIndex) else { continue }
                let slot = result.count
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let own = index(of: destination?.page)
                result.append(Heading(page: own ?? -1, title: clean(child.label), depth: depth))
                visit(child, depth: depth + 1)
                guard own == nil else { continue }
                if let first = result[(slot + 1)...].first(where: { $0.page >= 0 }) {
                    result[slot] = Heading(page: first.page, title: result[slot].title, depth: depth)
                } else {
                    result.removeSubrange(slot...)
                }
            }
        }
        visit(top, depth: 0)
        return result
    }

    /// Printed page labels, or nil when every label is just the page number.
    static func pageLabels(of document: PDFDocument) -> [String]? {
        var labels: [String] = []
        labels.reserveCapacity(document.pageCount)
        var own = false
        for index in 0..<document.pageCount {
            let label = (document.page(at: index)?.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty && label != String(index + 1) { own = true }
            labels.append(label)
        }
        return own ? labels : nil
    }

    static func clean(_ label: String?) -> String {
        (label ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
