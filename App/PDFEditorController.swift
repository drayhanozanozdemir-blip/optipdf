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

/// PDFView plus the three pencil tools. Gez: pencil and fingers scroll. Seç: the pencil selects text at once
/// while fingers scroll. Çiz: PencilKit on every page; strokes become standard ink annotations when leaving
/// the tool, so Acrobat and Preview show them too.
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
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        scrollView?.panGestureRecognizer.allowedTouchTypes = newTool == .navigate ? [direct, pencil, pointer] : [direct, pointer]
        if newTool == .draw { pdfView.clearSelection() }
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

/// One PencilKit canvas per page, shown by PDFKit above the page.
final class DrawingOverlays: NSObject, PDFPageOverlayViewProvider {
    private(set) var canvases: [PDFPage: PKCanvasView] = [:]
    weak var toolPicker: PKToolPicker?
    var onWillHide: ((PDFPage, PKCanvasView) -> Void)?
    private var drawing = false

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

    private func makeCanvas() -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        return canvas
    }
}
