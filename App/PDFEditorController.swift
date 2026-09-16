import SwiftUI
import PDFKit
import PencilKit

struct PDFEditorRepresentable: UIViewControllerRepresentable {
    let document: PDFDocument
    let model: EditorModel
    let undoManager: UndoManager?

    func makeUIViewController(context: Context) -> PDFEditorController {
        let controller = PDFEditorController(document: document)
        controller.model = model
        controller.undo = undoManager
        model.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: PDFEditorController, context: Context) {
        controller.undo = undoManager
    }
}

/// PDFView plus the pencil tools. Gez: pencil and fingers scroll. Seç: the pencil selects text at once while
/// fingers scroll. Çiz: PencilKit on every page; strokes become standard ink annotations when leaving the tool,
/// so Acrobat and Preview show them too. Yazı: a tap places a text box.
final class PDFEditorController: UIViewController, UIPencilInteractionDelegate {
    let pdfView = PDFView()
    let document: PDFDocument
    weak var model: EditorModel?
    var undo: UndoManager?

    private let overlays = DrawingOverlays()
    private let toolPicker = PKToolPicker()
    private lazy var pencilSelect: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pencilSelecting(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        gesture.isEnabled = false
        return gesture
    }()
    private lazy var textTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(placeText(_:)))
        gesture.isEnabled = false
        return gesture
    }()
    private var selectionStart: (page: PDFPage, point: CGPoint)?
    private var tool: EditorTool = .navigate

    init(document: PDFDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .secondarySystemBackground
        // The overlay provider must be in place before the document is set.
        overlays.toolPicker = toolPicker
        overlays.onWillHide = { [weak self] page, canvas in self?.commit(page: page, canvas: canvas) }
        pdfView.pageOverlayViewProvider = overlays
        pdfView.document = document

        pdfView.addGestureRecognizer(pencilSelect)
        pdfView.addGestureRecognizer(textTap)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        apply(tool: tool)
        DispatchQueue.main.async { [weak self] in self?.model?.reloadNotes() }
    }

    // MARK: Tools

    func apply(tool newTool: EditorTool) {
        if tool == .draw && newTool != .draw { commitDrawings() }
        tool = newTool
        let drawing = newTool == .draw
        pdfView.isInMarkupMode = drawing
        overlays.setDrawing(drawing)
        toolPicker.setVisible(drawing, forFirstResponder: self)
        if drawing { becomeFirstResponder() }
        pencilSelect.isEnabled = newTool == .select
        textTap.isEnabled = newTool == .text
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let pencilScrolls = newTool == .navigate || newTool == .text
        scrollView?.panGestureRecognizer.allowedTouchTypes = pencilScrolls ? [direct, pencil, pointer] : [direct, pointer]
        if newTool == .draw { pdfView.clearSelection() }
    }

    func setShapeSnap(_ enabled: Bool) {
        overlays.snapShapes = enabled
    }

    private var scrollView: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(pdfView)
    }

    @objc private func pencilSelecting(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        let point = pdfView.convert(location, to: page)
        switch gesture.state {
        case .began:
            selectionStart = (page, point)
            pdfView.clearSelection()
        case .changed, .ended:
            guard let start = selectionStart else { return }
            let selection = document.selection(from: start.page, at: start.point, to: page, at: point)
            pdfView.setCurrentSelection(selection, animate: false)
            if gesture.state == .ended { selectionStart = nil }
        default:
            selectionStart = nil
        }
    }

    @objc private func placeText(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        model?.textPlacement = TextPlacement(page: page, point: pdfView.convert(location, to: page))
    }

    @objc private func selectionChanged() {
        let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        model?.selectionText = (text?.isEmpty == false) ? text : nil
    }

    func clearSelection() {
        pdfView.clearSelection()
        model?.selectionText = nil
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        model?.cycleSqueeze()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        // While drawing, PencilKit uses the double tap for the eraser.
        guard tool != .draw else { return }
        model?.tool = tool == .select ? .navigate : .select
    }

    // MARK: Text and pages

    func currentPageText() -> String { pdfView.currentPage?.string ?? "" }

    func search(_ query: String) -> [PDFSelection] {
        let results = document.findString(query, withOptions: .caseInsensitive)
        pdfView.highlightedSelections = results
        if let first = results.first { pdfView.go(to: first) }
        return results
    }

    func clearSearch() { pdfView.highlightedSelections = nil }

    func show(_ selection: PDFSelection) {
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: true)
    }

    func show(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        pdfView.go(to: annotation.bounds, on: page)
    }

    func pageNumber(of selection: PDFSelection) -> Int {
        guard let page = selection.pages.first else { return 0 }
        return document.index(for: page) + 1
    }

    // MARK: Annotations

    func markSelection(_ subtype: PDFAnnotationSubtype, note: String? = nil) {
        guard let selection = pdfView.currentSelection else { return }
        let stamp = Date()
        let color: UIColor
        switch subtype {
        case .underline: color = .systemBlue
        case .strikeOut: color = .systemRed
        default: color = UIColor.systemYellow.withAlphaComponent(0.5)
        }
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = color
                annotation.modificationDate = stamp
                if added.isEmpty, let note, !note.isEmpty { annotation.contents = note }
                added.append((page, annotation))
            }
        }
        add(added, actionName: "İşaretleme")
        clearSelection()
    }

    /// A text box whose top-left corner is where the user tapped.
    func addText(_ text: String, at point: CGPoint, on page: PDFPage, size: CGFloat, color: UIColor) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let font = UIFont.systemFont(ofSize: size)
        let lines = trimmed.components(separatedBy: "\n")
        let width = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let height = CGFloat(lines.count) * font.lineHeight + 6
        let bounds = CGRect(x: point.x, y: point.y - height, width: width + 12, height: height)
        add([(page, textAnnotation(trimmed, bounds: bounds, font: font, color: color))], actionName: "Yazı")
    }

    private func textAnnotation(_ text: String, bounds: CGRect, font: UIFont, color: UIColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = color
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        annotation.modificationDate = Date()
        return annotation
    }

    func add(_ items: [(PDFPage, PDFAnnotation)], actionName: String) {
        guard !items.isEmpty else { return }
        for (page, annotation) in items { page.addAnnotation(annotation) }
        undo?.registerUndo(withTarget: self) { controller in controller.remove(items, actionName: actionName) }
        undo?.setActionName(actionName)
        model?.reloadNotes()
    }

    func remove(_ items: [(PDFPage, PDFAnnotation)], actionName: String) {
        guard !items.isEmpty else { return }
        for (page, annotation) in items { page.removeAnnotation(annotation) }
        undo?.registerUndo(withTarget: self) { controller in controller.add(items, actionName: actionName) }
        undo?.setActionName(actionName)
        model?.reloadNotes()
    }

    func setNote(_ text: String, on annotation: PDFAnnotation) {
        let old = annotation.contents ?? ""
        guard old != text else { return }
        annotation.contents = text
        undo?.registerUndo(withTarget: self) { controller in controller.setNote(old, on: annotation) }
        undo?.setActionName("Not")
        model?.reloadNotes()
    }

    // MARK: Drawing

    func commitDrawings() {
        for (page, canvas) in overlays.canvases where canvas.window != nil {
            commit(page: page, canvas: canvas)
        }
    }

    /// Handwriting on the visible pages becomes typed text at the same place; rough shapes become clean ones.
    func refine(text: Bool, shapes: Bool) {
        let targets = overlays.canvases.filter { $0.value.window != nil && !$0.value.drawing.strokes.isEmpty }
        guard !targets.isEmpty else {
            model?.show(toast: "Düzeltilecek çizim yok. Önce Çiz ile yaz veya çiz.")
            return
        }
        model?.show(toast: "Düzeltiliyor…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            var textLines = 0
            var shapeCount = 0
            for (page, canvas) in targets {
                var strokes = canvas.drawing.strokes
                var added: [(PDFPage, PDFAnnotation)] = []
                if text {
                    let lines = await HandwritingReader.read(PKDrawing(strokes: strokes), in: canvas.bounds)
                    for line in lines {
                        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.count >= 2 else { continue }
                        let area = line.rect.insetBy(dx: -3, dy: -3)
                        let covered = strokes.indices.filter { strokes[$0].renderBounds.intersects(area) }
                        guard let first = covered.first else { continue }
                        let color = strokes[first].ink.color
                        added.append((page, self.typedLine(trimmed, canvasRect: line.rect, canvas: canvas, page: page, color: color)))
                        for index in covered.reversed() { strokes.remove(at: index) }
                        textLines += 1
                    }
                }
                if shapes {
                    strokes = strokes.map { stroke in
                        guard let perfect = ShapeRecognizer.perfected(stroke) else { return stroke }
                        shapeCount += 1
                        return perfect
                    }
                }
                canvas.drawing = PKDrawing(strokes: strokes)
                self.add(added, actionName: "Düzelt")
            }
            self.model?.show(toast: "\(textLines) satır metne çevrildi, \(shapeCount) şekil düzeltildi.")
        }
    }

    private func typedLine(_ text: String, canvasRect: CGRect, canvas: PKCanvasView, page: PDFPage, color: UIColor) -> PDFAnnotation {
        let a = pdfView.convert(canvas.convert(CGPoint(x: canvasRect.minX, y: canvasRect.minY), to: pdfView), to: page)
        let b = pdfView.convert(canvas.convert(CGPoint(x: canvasRect.maxX, y: canvasRect.maxY), to: pdfView), to: page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let font = UIFont.systemFont(ofSize: max(8, rect.height * 0.72))
        let width = max(rect.width, (text as NSString).size(withAttributes: [.font: font]).width + 8)
        let height = max(rect.height, font.lineHeight + 4)
        let bounds = CGRect(x: rect.minX, y: rect.maxY - height, width: width, height: height)
        return textAnnotation(text, bounds: bounds, font: font, color: color)
    }

    /// Turns the page's PencilKit strokes into ink annotations in page space and clears the canvas.
    private func commit(page: PDFPage, canvas: PKCanvasView) {
        let strokes = canvas.drawing.strokes
        guard !strokes.isEmpty, canvas.window != nil else { return }
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = pageScale(canvas: canvas, page: page)
        let stamp = Date()
        var added: [(PDFPage, PDFAnnotation)] = []
        for stroke in strokes {
            let path = UIBezierPath()
            var widthSum: CGFloat = 0
            var count = 0
            for point in stroke.path.interpolatedPoints(by: .distance(2)) {
                let local = point.location.applying(stroke.transform)
                let inPage = pdfView.convert(canvas.convert(local, to: pdfView), to: page)
                let relative = CGPoint(x: inPage.x - pageBounds.minX, y: inPage.y - pageBounds.minY)
                if count == 0 { path.move(to: relative) } else { path.addLine(to: relative) }
                widthSum += point.size.width
                count += 1
            }
            guard count > 0 else { continue }
            if count == 1 { path.addLine(to: path.currentPoint) }
            let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = max(0.5, widthSum / CGFloat(count) * scale)
            annotation.border = border
            annotation.color = stroke.ink.inkType == .marker ? stroke.ink.color.withAlphaComponent(0.35) : stroke.ink.color
            annotation.modificationDate = stamp
            annotation.add(path)
            added.append((page, annotation))
        }
        canvas.drawing = PKDrawing()
        add(added, actionName: "Çizim")
    }

    private func pageScale(canvas: PKCanvasView, page: PDFPage) -> CGFloat {
        let a = pdfView.convert(canvas.convert(CGPoint.zero, to: pdfView), to: page)
        let b = pdfView.convert(canvas.convert(CGPoint(x: 100, y: 0), to: pdfView), to: page)
        let distance = hypot(b.x - a.x, b.y - a.y)
        return distance > 0 ? distance / 100 : 1
    }
}

/// One PencilKit canvas per page, shown by PDFKit above the page. In shape mode each finished stroke that
/// looks like a line, arrow, triangle, rectangle or ellipse is replaced by the clean shape.
final class DrawingOverlays: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    private(set) var canvases: [PDFPage: PKCanvasView] = [:]
    weak var toolPicker: PKToolPicker?
    var onWillHide: ((PDFPage, PKCanvasView) -> Void)?
    var snapShapes = false
    private var drawing = false
    private var strokeCounts: [ObjectIdentifier: Int] = [:]
    private var replacing = false

    func setDrawing(_ enabled: Bool) {
        drawing = enabled
        for canvas in canvases.values { canvas.isUserInteractionEnabled = enabled }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let canvas = canvases[page] ?? makeCanvas()
        canvases[page] = canvas
        canvas.isUserInteractionEnabled = drawing
        toolPicker?.addObserver(canvas)
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        if let canvas = overlayView as? PKCanvasView { onWillHide?(page, canvas) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let key = ObjectIdentifier(canvasView)
        let strokes = canvasView.drawing.strokes
        let previous = strokeCounts[key] ?? 0
        strokeCounts[key] = strokes.count
        guard snapShapes, !replacing, strokes.count == previous + 1, let last = strokes.last,
              let perfect = ShapeRecognizer.perfected(last) else { return }
        replacing = true
        var updated = strokes
        updated[updated.count - 1] = perfect
        canvasView.drawing = PKDrawing(strokes: updated)
        replacing = false
    }

    private func makeCanvas() -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.delegate = self
        return canvas
    }
}
