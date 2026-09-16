import SwiftUI
import PDFKit
import PencilKit

struct PDFEditorRepresentable: UIViewControllerRepresentable {
    let document: PDFDocument
    let model: EditorModel
    let undoManager: UndoManager?
    let title: String

    func makeUIViewController(context: Context) -> PDFEditorController {
        let controller = PDFEditorController(document: document)
        controller.model = model
        controller.undo = undoManager
        controller.exportName = title
        model.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: PDFEditorController, context: Context) {
        controller.undo = undoManager
    }
}

/// PDFView plus the pencil tools. Çiz (default): the pencil draws with PencilKit, fingers scroll. Seç: the pencil
/// selects text at once. Gez: pencil and fingers scroll. Yazı: a tap places a text box.
final class PDFEditorController: UIViewController, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let pdfView = PDFView()
    let document: PDFDocument
    weak var model: EditorModel?
    var undo: UndoManager?
    var exportName = "OptiPDF"

    private let overlays = DrawingOverlays()
    private let toolPicker = PKToolPicker(toolItems: [
        PKToolPickerInkingItem(type: .pen),
        PKToolPickerInkingItem(type: .fountainPen),
        PKToolPickerInkingItem(type: .pencil),
        PKToolPickerInkingItem(type: .monoline),
        PKToolPickerInkingItem(type: .marker),
        PKToolPickerInkingItem(type: .watercolor),
        PKToolPickerInkingItem(type: .crayon),
        PKToolPickerEraserItem(type: .vector),
        PKToolPickerEraserItem(type: .bitmap),
        PKToolPickerLassoItem(),
        PKToolPickerRulerItem()
    ])
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
    /// A finger tap on the page shows or hides the fullscreen controls.
    private lazy var hudTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(toggleHUD(_:)))
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                     NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()
    private var scrollSettle: DispatchWorkItem?
    private var selectionStart: (page: PDFPage, point: CGPoint)?
    private var tool: EditorTool = .draw
    private var observations: [NSKeyValueObservation] = []
    private var frameUpdatePending = false

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
        pdfView.backgroundColor = .secondarySystemBackground
        toolPicker.showsDrawingPolicyControls = false
        // The overlay provider must be in place before the document is set.
        overlays.toolPicker = toolPicker
        overlays.load(document)
        overlays.onChange = { [weak self] page, previous, updated in self?.drawingChanged(page, from: previous, to: updated) }
        pdfView.pageOverlayViewProvider = overlays
        pdfView.document = document

        pdfView.addGestureRecognizer(pencilSelect)
        pdfView.addGestureRecognizer(textTap)
        pdfView.addGestureRecognizer(hudTap)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        applyDisplay(model?.displayMode ?? "continuous")
        apply(tool: model?.tool ?? tool, force: true)
        DispatchQueue.main.async { [weak self] in
            self?.model?.reloadNotes()
            self?.pageChanged()
        }
    }

    // MARK: Tools and display

    func apply(tool newTool: EditorTool, force: Bool = false) {
        guard force || newTool != tool else { return }
        tool = newTool
        guard isViewLoaded else { return }
        let drawing = newTool == .draw
        pdfView.isInMarkupMode = drawing
        overlays.setDrawing(drawing)
        if drawing { becomeFirstResponder() }
        updateControls()
        // Seç: the pencil selects at once. Gez: the pencil scrolls; holding it still for a moment, then
        // dragging, selects text, so nothing needs a finger.
        pencilSelect.isEnabled = newTool == .select || newTool == .navigate
        pencilSelect.minimumPressDuration = newTool == .select ? 0 : 0.3
        pencilSelect.allowableMovement = newTool == .select ? .greatestFiniteMagnitude : 12
        textTap.isEnabled = newTool == .text
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let pencilScrolls = newTool == .navigate || newTool == .text
        scrollView?.panGestureRecognizer.allowedTouchTypes = pencilScrolls ? [direct, pencil, pointer] : [direct, pointer]
        if drawing { clearSelection() }
    }

    func updateControls() {
        guard isViewLoaded else { return }
        let visible = tool == .draw && (model?.fullscreen != true || model?.hudVisible == true)
        toolPicker.setVisible(visible, forFirstResponder: self)
        for canvas in overlays.canvases.values {
            toolPicker.setVisible(visible, forFirstResponder: canvas)
        }
    }

    @objc private func toggleHUD(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        model?.toggleHUD()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === hudTap else { return true }
        return model?.fullscreen == true && model?.selectionText == nil && tool != .text
            && (touch.type != .pencil || tool == .navigate)
            && !(tool == .draw && UIDevice.current.userInterfaceIdiom == .phone)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === hudTap || otherGestureRecognizer === hudTap
    }

    func applyDisplay(_ mode: String) {
        switch mode {
        case "page":
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.usePageViewController(true, withViewOptions: nil)
        case "twoUp":
            pdfView.usePageViewController(false, withViewOptions: nil)
            pdfView.displayMode = .twoUpContinuous
            pdfView.displayDirection = .vertical
        default:
            pdfView.usePageViewController(false, withViewOptions: nil)
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        }
        pdfView.autoScales = true
        observeScrolling()
        apply(tool: tool, force: true)
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

    private func observeScrolling() {
        observations.removeAll()
        guard let scroll = scrollView else { return }
        observations.append(scroll.observe(\.contentOffset) { [weak self] _, _ in self?.scheduleSelectionFrame() })
        observations.append(scroll.observe(\.zoomScale) { [weak self] _, _ in self?.scheduleSelectionFrame() })
    }

    private func scheduleSelectionFrame() {
        guard !frameUpdatePending else { return }
        frameUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameUpdatePending = false
            self.model?.isScrolling = true
            self.scrollSettle?.cancel()
            let settle = DispatchWorkItem { [weak self] in
                self?.updateSelectionFrame()
                self?.model?.isScrolling = false
            }
            self.scrollSettle = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: settle)
        }
    }

    /// Where the selection is on screen, so the action bar can float next to it while the page scrolls.
    private func updateSelectionFrame() {
        guard model?.selectionText != nil, let selection = pdfView.currentSelection else {
            if model?.selectionFrame != nil { model?.selectionFrame = nil }
            return
        }
        var frame = CGRect.null
        for page in selection.pages {
            let visible = pdfView.convert(selection.bounds(for: page), from: page).intersection(pdfView.bounds)
            if !visible.isNull && !visible.isEmpty { frame = frame.union(visible) }
        }
        model?.selectionFrame = frame.isNull ? nil : frame
    }

    @objc private func pencilSelecting(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .cancelled || gesture.state == .failed {
            selectionStart = nil
            model?.isSelecting = false
            return
        }
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else {
            selectionStart = nil
            model?.isSelecting = false
            return
        }
        let point = pdfView.convert(location, to: page)
        switch gesture.state {
        case .began:
            model?.isSelecting = true
            selectionStart = (page, point)
            pdfView.clearSelection()
        case .changed, .ended:
            guard let start = selectionStart else { return }
            let selection = document.selection(from: start.page, at: start.point, to: page, at: point)
            pdfView.setCurrentSelection(selection, animate: false)
            if gesture.state == .ended {
                selectionStart = nil
                model?.isSelecting = false
            }
        default:
            selectionStart = nil
            model?.isSelecting = false
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
        updateSelectionFrame()
    }

    @objc private func pageChanged() {
        model?.pageCount = document.pageCount
        guard let page = pdfView.currentPage else { return }
        model?.currentPage = document.index(for: page)
    }

    func clearSelection() {
        pdfView.clearSelection()
        model?.isSelecting = false
        model?.selectionText = nil
        model?.selectionFrame = nil
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        model?.cycleSqueeze()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        // While drawing, PencilKit uses the double tap for the eraser; otherwise it turns the pen on.
        guard tool != .draw else { return }
        model?.tool = .draw
    }

    // MARK: Text and navigation

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

    func go(to destination: PDFDestination) { pdfView.go(to: destination) }

    func goToPage(_ index: Int) {
        guard let page = document.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func pageNumber(of selection: PDFSelection) -> Int {
        guard let page = selection.pages.first else { return 0 }
        return document.index(for: page) + 1
    }

    // MARK: Pages

    private func allPages() -> [PDFPage] { (0..<document.pageCount).compactMap { document.page(at: $0) } }

    func movePages(from source: IndexSet, to destination: Int) {
        let previous = allPages()
        var pages = previous
        pages.move(fromOffsets: source, toOffset: destination)
        setPages(pages, previous: previous, actionName: "Sayfa taşı")
    }

    func deletePages(_ offsets: IndexSet) {
        let previous = allPages()
        var pages = previous
        pages.remove(atOffsets: offsets)
        guard !pages.isEmpty else {
            model?.show(toast: "Son sayfa silinemez.")
            return
        }
        setPages(pages, previous: previous, actionName: "Sayfa sil")
    }

    func duplicatePage(_ index: Int) {
        guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else { return }
        overlays.load(copy)
        let previous = allPages()
        var pages = previous
        pages.insert(copy, at: index + 1)
        setPages(pages, previous: previous, actionName: "Sayfa çoğalt")
    }

    func insertBlankPage(after index: Int) {
        let size = document.page(at: index).map { DrawingStorage.displaySize(of: $0) } ?? CGSize(width: 595, height: 842)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let blank = PDFPage(image: image) else { return }
        let previous = allPages()
        var pages = previous
        pages.insert(blank, at: min(index + 1, pages.count))
        setPages(pages, previous: previous, actionName: "Boş sayfa")
    }

    func rotatePage(_ index: Int, by degrees: Int) {
        guard let page = document.page(at: index) else { return }
        setRotation(of: page, to: (page.rotation + degrees + 360) % 360)
    }

    private func setRotation(of page: PDFPage, to rotation: Int) {
        let old = page.rotation
        page.rotation = rotation
        undo?.registerUndo(withTarget: self) { controller in controller.setRotation(of: page, to: old) }
        undo?.setActionName("Sayfa döndür")
        pagesChanged()
    }

    private func setPages(_ pages: [PDFPage], previous: [PDFPage], actionName: String) {
        var first = 0
        while first < min(pages.count, previous.count), pages[first] === previous[first] { first += 1 }
        for _ in first..<previous.count { document.removePage(at: first) }
        for index in first..<pages.count { document.insert(pages[index], at: index) }
        undo?.registerUndo(withTarget: self) { controller in controller.setPages(previous, previous: pages, actionName: actionName) }
        undo?.setActionName(actionName)
        pagesChanged()
    }

    private func pagesChanged() {
        pdfView.layoutDocumentView()
        model?.pageRevision += 1
        model?.reloadNotes()
        pageChanged()
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

    private func drawingChanged(_ page: PDFPage, from previous: PKDrawing, to updated: PKDrawing) {
        DrawingStorage.save(updated, on: page)
        undo?.registerUndo(withTarget: self) { controller in controller.restoreDrawing(previous, replacing: updated, on: page) }
        undo?.setActionName("Çizim")
    }

    private func restoreDrawing(_ drawing: PKDrawing, replacing current: PKDrawing, on page: PDFPage) {
        overlays.replace(drawing, for: page)
        DrawingStorage.save(drawing, on: page)
        undo?.registerUndo(withTarget: self) { controller in controller.restoreDrawing(current, replacing: drawing, on: page) }
        undo?.setActionName("Çizim")
    }

    /// Handwriting on the visible pages becomes typed text at the same place; rough shapes become clean ones.
    func refine(text: Bool, shapes: Bool) {
        let targets = overlays.canvases.filter { $0.value.window != nil && !$0.value.drawing.strokes.isEmpty }
        guard !targets.isEmpty else {
            model?.show(toast: "Düzeltilecek çizim yok. Önce kalemle yaz veya çiz.")
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

    // MARK: Export

    /// A copy with every drawing burned into its page, for Files, Mail, Acrobat and other apps.
    func exportFlattened() {
        guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else {
            model?.show(toast: "Dışa aktarılamadı.")
            return
        }
        for index in 0..<copy.pageCount {
            guard let page = copy.page(at: index), let original = document.page(at: index) else { continue }
            for annotation in page.annotations where DrawingStorage.isStorage(annotation) {
                page.removeAnnotation(annotation)
            }
            guard let drawing = overlays.drawing(for: original), !drawing.strokes.isEmpty else { continue }
            let size = DrawingStorage.displaySize(of: page)
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: CGRect(origin: .zero, size: size), scale: 3)
            }
            let annotation = DrawingImageAnnotation(bounds: page.bounds(for: .cropBox), forType: .stamp, withProperties: nil)
            annotation.image = image
            page.addAnnotation(annotation)
        }
        guard let flattened = copy.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true]) else {
            model?.show(toast: "Dışa aktarılamadı.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(exportName + " (OptiPDF).pdf")
        do {
            try flattened.write(to: url, options: .atomic)
        } catch {
            model?.show(toast: "Dışa aktarılamadı.")
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.maxX - 80, y: 0, width: 1, height: 1)
        present(sheet, animated: true)
    }
}
