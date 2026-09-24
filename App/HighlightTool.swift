import SwiftUI
import PDFKit

// MARK: - Colours

/// The five highlighter colours. A highlight keeps its colour at half strength and PDFKit multiplies it into the
/// page, so black text stays black on every colour; the sepia tint keeps the tone warm and the night tint (an
/// inversion) turns it into a dark shade under white text. HighlightToolTests checks the contrast under all three.
enum HighlightColor: String, CaseIterable, Identifiable {
    case sari, yesil, mavi, pembe, turuncu

    /// @AppStorage key of the last colour used by the Vurgu tool and the selection bar.
    static let storageKey = "highlightColor"
    /// Opacity of a highlight annotation.
    static let highlightAlpha: CGFloat = 0.5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sari: return "Sarı"
        case .yesil: return "Yeşil"
        case .mavi: return "Mavi"
        case .pembe: return "Pembe"
        case .turuncu: return "Turuncu"
        }
    }

    /// Full-strength colour: swatches and note icons.
    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .sari: return (1.00, 0.86, 0.00)
        case .yesil: return (0.36, 0.85, 0.36)
        case .mavi: return (0.33, 0.66, 1.00)
        case .pembe: return (1.00, 0.45, 0.75)
        case .turuncu: return (1.00, 0.55, 0.10)
        }
    }

    /// Darker shade for underline and strike-out, which are thin lines on white paper.
    var lineRGB: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .sari: return (0.85, 0.65, 0.00)
        case .yesil: return (0.13, 0.60, 0.20)
        case .mavi: return (0.05, 0.42, 0.90)
        case .pembe: return (0.87, 0.20, 0.55)
        case .turuncu: return (0.93, 0.40, 0.00)
        }
    }

    /// How a highlight of this colour looks on white paper.
    var tone: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let a = Self.highlightAlpha
        return (1 - a + a * rgb.r, 1 - a + a * rgb.g, 1 - a + a * rgb.b)
    }

    var uiColor: UIColor { UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
    var highlightColor: UIColor { uiColor.withAlphaComponent(Self.highlightAlpha) }
    var lineColor: UIColor { UIColor(red: lineRGB.r, green: lineRGB.g, blue: lineRGB.b, alpha: 1) }
    var swatch: Color { Color(uiColor: uiColor) }

    /// The colour an annotation of a type ("Highlight", "Underline"…) gets: highlights translucent, the rest solid.
    func annotationColor(forType type: String) -> UIColor {
        switch type {
        case "Highlight": return highlightColor
        case "Underline", "StrikeOut": return lineColor
        default: return uiColor
        }
    }

    static var last: HighlightColor {
        get { HighlightColor(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .sari }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// The palette colour an annotation colour is close enough to be called by (nil for other colours).
    static func match(_ color: UIColor?) -> HighlightColor? {
        guard let c = components(of: color), c.a > 0.05 else { return nil }
        var best: HighlightColor?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in allCases {
            for shade in [candidate.rgb, candidate.lineRGB] {
                let dr = c.r - shade.r
                let dg = c.g - shade.g
                let db = c.b - shade.b
                let distance = (dr * dr + dg * dg + db * db).squareRoot()
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return bestDistance < 0.25 ? best : nil
    }

    /// sRGB components of any colour (PDF colours may be grey or CMYK).
    static func components(of color: UIColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let values = converted.components, values.count >= 4 else { return nil }
        return (values[0], values[1], values[2], values[3])
    }
}

// MARK: - Marks

extension PDFAnnotation {
    /// PDFKit's type without the leading slash: "Highlight", "Underline", "StrikeOut", "Text"…
    var markType: String { (type ?? "").replacingOccurrences(of: "/", with: "") }
}

/// Stamps of new marks. The notes list groups the lines of one mark by their stamp and a PDF keeps whole seconds,
/// so two highlights made within one second would merge after saving. Stamps are whole seconds and always increase.
@MainActor
enum MarkStamp {
    private static var last = Date.distantPast

    static func next(now: Date = Date()) -> Date {
        var stamp = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded(.down))
        if stamp <= last { stamp = last.addingTimeInterval(1) }
        last = stamp
        return stamp
    }
}

enum MarkGeometry {
    /// One quadrilateral over a whole line, relative to the annotation's origin, in PDFKit's order (top left, top
    /// right, bottom left, bottom right). Acrobat and Preview need QuadPoints to draw text markup.
    static func quad(for bounds: CGRect) -> [NSValue] {
        [CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
         CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0)].map { NSValue(cgPoint: $0) }
    }

    static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}

/// What "Nota ekle" in the result sheet attaches the output to.
enum NoteTarget {
    /// A tapped mark: the output becomes or extends its note.
    case mark(NoteItem)
    /// Selected text: the highlight over exactly these lines gets the note, or a new highlight is made.
    case selection(PDFSelection)
    /// A page-level result: a note icon in the page corner, listed in Notlar.
    case page(Int)
}

extension NoteItem {
    /// The line that carries the note: the first with text, else the first line.
    var noteAnnotation: PDFAnnotation { pairs.first { !($0.1.contents ?? "").isEmpty }?.1 ?? first }
    /// The note as it is now; the item itself is a snapshot from when it was listed or tapped.
    var currentNote: String { noteAnnotation.contents ?? "" }
}

private struct MarkColorChange {
    let page: PDFPage
    let annotation: PDFAnnotation
    let color: UIColor
}

// MARK: - Controller: marks, colours and notes

extension PDFEditorController {
    /// Marks that open the action bar when tapped.
    static let tappableMarkTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Text"]

    /// The mark (every line of one highlight) at a point of a page, grouped exactly as the notes list groups it.
    static func markItem(at point: CGPoint, on page: PDFPage, in document: PDFDocument, tolerance: CGFloat = 2) -> NoteItem? {
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount else { return nil }
        let hit = page.annotations.reversed().first { annotation in
            tappableMarkTypes.contains(annotation.markType) && !DrawingStorage.isStorage(annotation)
                && annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
        guard let hit else { return nil }
        var items: [NoteItem] = []
        EditorModel.appendNotes(from: document, at: index, to: &items)
        return items.first { item in item.pairs.contains { $0.1 === hit } }
    }

    func markItem(atViewPoint location: CGPoint) -> NoteItem? {
        guard let page = pdfView.page(for: location, nearest: false) else { return nil }
        return Self.markItem(at: pdfView.convert(location, to: page), on: page, in: document)
    }

    /// Opens the action bar of the mark at a point of the reader; false when there is none.
    @discardableResult
    func openMark(atViewPoint location: CGPoint) -> Bool {
        guard let item = markItem(atViewPoint: location) else { return false }
        clearSelection()
        model?.activeMark = item
        return true
    }

    /// Colours every line of a mark; undo gives each line its previous colour back.
    func recolor(_ items: [(PDFPage, PDFAnnotation)], to color: HighlightColor) {
        let changes = items.map { MarkColorChange(page: $0.0, annotation: $0.1, color: color.annotationColor(forType: $0.1.markType)) }
        let previous = items.map { MarkColorChange(page: $0.0, annotation: $0.1, color: $0.1.color) }
        applyColors(changes, undoing: previous)
    }

    private func applyColors(_ changes: [MarkColorChange], undoing previous: [MarkColorChange]) {
        guard !changes.isEmpty else { return }
        var pages: [PDFPage] = []
        for change in changes {
            change.annotation.color = change.color
            // A colour change on an annotation that came with the PDF is kept in the side file from now on.
            if sidecar != nil, !AnnotationSidecar.isOurs(change.annotation) { change.annotation.userName = AnnotationSidecar.marker }
            if !pages.contains(where: { $0 === change.page }) { pages.append(change.page) }
        }
        for page in pages { pdfView.annotationsChanged(on: page) }
        editUndo?.registerUndo(withTarget: self) { controller in controller.applyColors(previous, undoing: changes) }
        editUndo?.setActionName("Renk")
        notesChanged(on: pages)
        model?.reloadNotes()
        if let mark = model?.activeMark, changes.contains(where: { $0.annotation === mark.first }) { model?.activeMark = mark }
    }

    /// A note icon in the top corner of a page, for results that belong to the page rather than to a passage.
    func addPageNote(_ text: String, on index: Int) {
        guard let page = document.page(at: index) else { return }
        let crop = page.bounds(for: .cropBox)
        let size: CGFloat = 24
        let stacked = page.annotations.filter { $0.markType == "Text" && AnnotationSidecar.isOurs($0) }.count % 10
        let bounds = CGRect(x: crop.maxX - size - 10, y: crop.maxY - size - 10 - CGFloat(stacked) * (size + 6),
                            width: size, height: size)
        let note = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        note.userName = AnnotationSidecar.marker
        note.contents = text
        note.iconType = .note
        note.color = HighlightColor.last.uiColor
        note.modificationDate = MarkStamp.next()
        add([(page, note)], actionName: "Not")
    }

    /// Where the output of an AI action belongs: the tapped mark, the selected passage or the current page.
    func noteTarget(for action: AIAction, quote: String?) -> NoteTarget {
        if quote != nil, let mark = model?.activeMark, mark.first.page != nil { return .mark(mark) }
        switch action {
        case .translate, .explain, .ask:
            if let selection = pdfView.currentSelection?.copy() as? PDFSelection,
               !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .selection(selection)
            }
        default:
            break
        }
        let index = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        return .page(index >= 0 && index < document.pageCount ? index : 0)
    }

    /// "Nota ekle": every path goes through setNote, markSelection or add, so it can be undone.
    func attachNote(_ text: String, to target: NoteTarget) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch target {
        case .mark(let item):
            guard item.first.page != nil else { return addPageNote(text, on: item.pageIndex) }
            appendNote(text, to: item.noteAnnotation)
        case .selection(let selection):
            if let existing = highlight(matching: selection) {
                appendNote(text, to: existing)
            } else {
                markSelection(.highlight, note: text, selection: selection)
            }
        case .page(let index):
            addPageNote(text, on: index)
        }
    }

    private func appendNote(_ text: String, to annotation: PDFAnnotation) {
        let old = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        setNote(old.isEmpty ? text : old + "\n\n" + text, on: annotation)
    }

    /// The highlight over exactly the lines of a selection, if the user already made it.
    private func highlight(matching selection: PDFSelection) -> PDFAnnotation? {
        var lines: [(page: PDFPage, bounds: CGRect)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                if bounds.width > 0.5, bounds.height > 0.5 { lines.append((page, bounds)) }
            }
        }
        guard let first = lines.first else { return nil }
        let index = document.index(for: first.page)
        guard index >= 0, index < document.pageCount else { return nil }
        let onPage = lines.filter { $0.page === first.page }
        var items: [NoteItem] = []
        EditorModel.appendNotes(from: document, at: index, to: &items)
        let match = items.first { item in
            item.first.markType == "Highlight" && item.pairs.count == onPage.count
                && zip(item.pairs, onPage).allSatisfy { pair, line in MarkGeometry.same(pair.1.bounds, line.bounds) }
        }
        return match?.first
    }

    /// The note sheet for a mark (action bar and notes list).
    func noteRequest(for item: NoteItem) -> NoteEditorRequest {
        let note = item.currentNote
        let target = item.noteAnnotation
        return NoteEditorRequest(title: note.isEmpty ? "Not ekle" : "Notu düzenle", quote: item.quote, text: note,
                                 accent: HighlightColor.match(item.first.color)?.swatch ?? .yellow,
                                 allowsEmpty: true) { [weak self] text in
            self?.setNote(text, on: target)
        }
    }

    /// "Not" in the selection bar: the selected passage becomes a highlight carrying the note.
    func requestNoteForSelection() {
        guard let selection = pdfView.currentSelection?.copy() as? PDFSelection else { return }
        let quote = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let color = HighlightColor.last
        model?.noteEditor = NoteEditorRequest(title: "Not ekle", quote: quote, text: "", accent: color.swatch,
                                              allowsEmpty: false) { [weak self] text in
            _ = self?.markSelection(.highlight, note: text, color: color.highlightColor, selection: selection)
        }
    }

    /// Gives the keyboard back to the reader after a sheet closes, unless another sheet is still up.
    func refocusReader() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil else { return }
            var ancestor: UIViewController? = self
            while let controller = ancestor {
                if controller.presentedViewController != nil { return }
                ancestor = controller.parent
            }
            self.becomeFirstResponder()
        }
    }
}

// MARK: - Vurgu tool

/// The Vurgu tool. iPad: an Apple Pencil drag over text highlights it while fingers keep scrolling. iPhone: one
/// finger highlights, two fingers scroll. The live preview snaps to text lines (words at both ends); on release the
/// highlight is made through markSelection, so undo, the side file and the notes list work as for the selection bar.
/// A tap on a highlight, underline, strike-out or note opens its action bar in Gez, Seç and Vurgu.
@MainActor
final class HighlightInteraction: NSObject, UIGestureRecognizerDelegate {
    private weak var controller: PDFEditorController?
    private var tool: EditorTool = .draw
    private let preview = MarkShapeView()
    private let outline = MarkShapeView()
    private var start: (page: PDFPage, point: CGPoint, word: PDFSelection?)?
    private var selection: PDFSelection?
    private var moved = false
    private var dragColor = HighlightColor.sari
    private var tappedMark: NoteItem?
    private weak var twoFingerScroll: UIScrollView?
    private weak var observedScroll: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    private lazy var pencilDrag: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pencilDragged(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()
    private lazy var fingerDrag: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(fingerDragged(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()
    private lazy var markTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(markTapped(_:)))
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()

    init(controller: PDFEditorController) {
        self.controller = controller
        super.init()
    }

    /// The mark tap waits for the pencil double tap (word selection in Gez); the fullscreen tap waits for the mark tap.
    func install(after pencilDoubleTap: UIGestureRecognizer, before hudTap: UIGestureRecognizer) {
        guard let controller else { return }
        let pdfView = controller.pdfView
        pencilDrag.allowedTouchTypes = controller.readerPencilTouchTypes
        // Above the PDF view in the controller's own view, so PDFKit's layout never touches them.
        for view in [preview, outline] {
            view.frame = controller.view.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            controller.view.addSubview(view)
        }
        outline.shape.fillColor = UIColor.clear.cgColor
        outline.shape.strokeColor = UIColor.systemBlue.cgColor
        outline.shape.lineWidth = 2
        outline.shape.lineDashPattern = [6, 4]
        pdfView.addGestureRecognizer(pencilDrag)
        pdfView.addGestureRecognizer(fingerDrag)
        pdfView.addGestureRecognizer(markTap)
        markTap.require(toFail: pencilDoubleTap)
        hudTap.require(toFail: markTap)
    }

    func apply(tool newTool: EditorTool, scroll: UIScrollView?) {
        let previous = tool
        tool = newTool
        cancelDrag()
        let highlighting = newTool == .highlight
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        pencilDrag.isEnabled = highlighting
        fingerDrag.isEnabled = highlighting && phone
        markTap.isEnabled = highlighting || newTool == .navigate || newTool == .select
        // iPhone: one finger highlights, two fingers scroll.
        if let old = twoFingerScroll, old !== scroll || !(highlighting && phone) {
            old.panGestureRecognizer.minimumNumberOfTouches = 1
            twoFingerScroll = nil
        }
        if highlighting && phone, let scroll {
            scroll.panGestureRecognizer.minimumNumberOfTouches = 2
            twoFingerScroll = scroll
        }
        watchScroll(scroll)
        if !markTap.isEnabled, controller?.model?.activeMark != nil { controller?.model?.activeMark = nil }
        refreshOutline()
        if highlighting && previous != .highlight { showHint(phone: phone) }
    }

    /// Dashed frame around the mark whose action bar is open; it follows scrolling and zooming.
    func refreshOutline() {
        guard let controller else { return }
        guard markTap.isEnabled, let mark = controller.model?.activeMark, mark.first.page != nil else {
            if outline.shape.path != nil { outline.show([]) }
            return
        }
        let pdfView = controller.pdfView
        var frame = CGRect.null
        for (page, annotation) in mark.pairs where annotation.page != nil {
            frame = frame.union(outline.convert(pdfView.convert(annotation.bounds, from: page), from: pdfView))
        }
        outline.superview?.bringSubviewToFront(outline)
        outline.show(frame.isNull ? [] : [frame.insetBy(dx: -4, dy: -3)])
    }

    private func watchScroll(_ scroll: UIScrollView?) {
        guard observedScroll !== scroll || observations.isEmpty else { return }
        observedScroll = scroll
        observations = []
        guard let scroll else { return }
        observations = [
            scroll.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.refreshOutline()
                    return
                }
            },
            scroll.observe(\.zoomScale) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.refreshOutline()
                    return
                }
            }
        ]
    }

    private func showHint(phone: Bool) {
        let key = "highlightHints"
        let shown = UserDefaults.standard.integer(forKey: key)
        guard shown < 3 else { return }
        UserDefaults.standard.set(shown + 1, forKey: key)
        controller?.model?.show(toast: phone ? "Tek parmakla metnin üzerinden geç; iki parmakla kaydır."
                                              : "Kalemle metnin üzerinden geç; parmakla kaydır.")
    }

    // MARK: Gestures

    @objc private func pencilDragged(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView = controller?.pdfView else { return }
        let location = gesture.location(in: pdfView)
        switch gesture.state {
        case .began:
            begin(at: location)
        case .changed:
            extend(to: location)
        case .ended:
            extend(to: location)
            if moved { commit() } else { tap(at: location) }
        default:
            cancelDrag()
        }
    }

    @objc private func fingerDragged(_ gesture: UIPanGestureRecognizer) {
        guard let pdfView = controller?.pdfView else { return }
        let location = gesture.location(in: pdfView)
        switch gesture.state {
        case .began:
            // A pan starts after some movement; the highlight starts where the finger went down.
            let travel = gesture.translation(in: pdfView)
            begin(at: CGPoint(x: location.x - travel.x, y: location.y - travel.y))
            extend(to: location)
        case .changed:
            extend(to: location)
        case .ended:
            extend(to: location)
            if moved { commit() } else { cancelDrag() }
        default:
            cancelDrag()
        }
    }

    @objc private func markTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let item = tappedMark
        tappedMark = nil
        if let item {
            controller?.clearSelection()
            controller?.model?.activeMark = item
        } else if controller?.model?.activeMark != nil {
            controller?.model?.activeMark = nil
        }
    }

    private func begin(at location: CGPoint) {
        cancelDrag()
        guard let controller, let page = controller.pdfView.page(for: location, nearest: true) else { return }
        let point = controller.pdfView.convert(location, to: page)
        start = (page, point, page.selectionForWord(at: point))
        dragColor = HighlightColor.last
        controller.model?.isSelecting = true
    }

    private func extend(to location: CGPoint) {
        guard let controller, let start, let page = controller.pdfView.page(for: location, nearest: true) else { return }
        let pdfView = controller.pdfView
        let point = pdfView.convert(location, to: page)
        if !moved {
            // About four screen points at the current zoom.
            let threshold = 4 / max(pdfView.scaleFactor, 0.05)
            guard start.page !== page || hypot(point.x - start.point.x, point.y - start.point.y) > threshold else { return }
            moved = true
            controller.clearSelection()
            if controller.model?.activeMark != nil { controller.model?.activeMark = nil }
            controller.model?.isSelecting = true
        } else if pdfView.currentSelection != nil {
            // PDFKit's own long-press selection may start during a slow drag; only the preview should show.
            pdfView.clearSelection()
        }
        let next = controller.document.selection(from: start.page, at: start.point, to: page, at: point)
        if let word = start.word { next?.add(word) }
        if let word = page.selectionForWord(at: point) { next?.add(word) }
        selection = next
        showPreview(next)
    }

    private func commit() {
        let chosen = selection
        let page = start?.page
        cancelDrag()
        guard let controller else { return }
        if let chosen, !(chosen.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.markSelection(.highlight, color: dragColor.highlightColor, selection: chosen)
        } else if let page, (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.model?.show(toast: "Bu sayfada seçilebilir metin yok.")
        }
    }

    private func tap(at location: CGPoint) {
        cancelDrag()
        guard let controller else { return }
        if !controller.openMark(atViewPoint: location), controller.model?.activeMark != nil {
            controller.model?.activeMark = nil
        }
    }

    func cancelDrag() {
        preview.show([])
        if start != nil { controller?.model?.isSelecting = false }
        start = nil
        selection = nil
        moved = false
    }

    /// The preview blends like the finished highlight: multiplied into the page, or, on the inverted night page,
    /// screened in with the inverted tone, so it looks like the result under every tint.
    private func showPreview(_ selection: PDFSelection?) {
        guard let controller, let selection else {
            preview.show([])
            return
        }
        let pdfView = controller.pdfView
        var rects: [CGRect] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                rects.append(preview.convert(pdfView.convert(bounds, from: page), from: pdfView))
            }
        }
        let tone = dragColor.tone
        let night = controller.model?.readingTint == .night
        preview.layer.compositingFilter = night ? "screenBlendMode" : "multiplyBlendMode"
        let fill = night ? UIColor(red: 1 - tone.r, green: 1 - tone.g, blue: 1 - tone.b, alpha: 1)
            : UIColor(red: tone.r, green: tone.g, blue: tone.b, alpha: 1)
        preview.superview?.bringSubviewToFront(preview)
        preview.show(rects, fill: fill)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === markTap else { return true }
        // Pencil taps belong to the Seç and Vurgu pencil gestures; in Gez the pencil taps marks like a finger.
        return touch.type != .pencil || tool == .navigate
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === markTap, let controller else { return true }
        tappedMark = controller.markItem(atViewPoint: gestureRecognizer.location(in: controller.pdfView))
        // A tap beside the open mark closes its bar.
        return tappedMark != nil || controller.model?.activeMark != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let own: [UIGestureRecognizer] = [pencilDrag, fingerDrag, markTap]
        if own.contains(where: { $0 === otherGestureRecognizer }) { return false }
        // Like the Seç pencil gesture, the pencil drag leaves finger scrolling and zooming alone.
        return gestureRecognizer === pencilDrag
    }
}

/// A shape above the PDF: the live highlight preview or the dashed frame of the open mark.
final class MarkShapeView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }

    var shape: CAShapeLayer { layer as! CAShapeLayer }

    func show(_ rects: [CGRect], fill: UIColor? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rects.isEmpty {
            shape.path = nil
        } else {
            let path = UIBezierPath()
            for rect in rects { path.append(UIBezierPath(roundedRect: rect, cornerRadius: 3)) }
            shape.path = path.cgPath
        }
        if let fill { shape.fillColor = fill.cgColor }
        CATransaction.commit()
    }
}
