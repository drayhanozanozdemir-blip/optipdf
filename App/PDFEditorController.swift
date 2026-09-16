import SwiftUI
import PDFKit
import PencilKit

#if READER_PROBE
@MainActor
private enum ReaderKeyTrace {
    static var codes: [Int] = []
    static weak var responder: UIResponder?
    static let install: Void = {
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.readerSendEvent(_:))) else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

extension UIApplication {
    @objc fileprivate func readerSendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent {
            for press in presses.allPresses where press.phase == .began {
                ReaderKeyTrace.codes.append(press.key?.keyCode.rawValue ?? -1)
            }
        }
        readerSendEvent(event)
    }
}

extension UIResponder {
    @objc fileprivate func readerCaptureResponder() {
        ReaderKeyTrace.responder = self
    }
}

final class DiagnosticPDFView: PDFView {
    var diagnostics: (() -> String)?

    override var accessibilityValue: String? {
        get { diagnostics?() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
}
#endif

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
#if READER_PROBE
    let pdfView = DiagnosticPDFView()
    private var keyboardCommandQueries = 0
    private var keyboardActionCount = 0
    private var keyboardPressCount = 0
    private var keyboardFocusAccepted = false
#else
    let pdfView = PDFView()
#endif
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
        gesture.allowedTouchTypes = readerPencilTouchTypes
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()
    private lazy var pencilScroll: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(scrollWithPencil(_:)))
        gesture.allowedTouchTypes = readerPencilTouchTypes
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()
    private lazy var textTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(placeText(_:)))
        gesture.isEnabled = false
        return gesture
    }()
    private lazy var pencilWordTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(selectPencilWord(_:)))
        gesture.numberOfTapsRequired = 2
        gesture.delegate = self
        gesture.allowedTouchTypes = readerPencilTouchTypes
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
    private var selectionStart: (page: PDFPage, point: CGPoint, word: PDFSelection?)?
    private var tool: EditorTool = .draw
    private weak var fullscreenNavigationController: UINavigationController?
    private var chromeBeforeFullscreen: (navigationHidden: Bool, toolbarHidden: Bool)?
    private var pickerVisible = false
    private var pencilScrollOrigin: CGPoint?
    private weak var keyboardFocusScrollView: UIScrollView?
    private var readerPencilTouchTypes: [NSNumber] {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "readerProbePencil") {
            return [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
#endif
        return [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    init(document: PDFDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    private var keyboardNavigationAvailable: Bool {
        guard let window = viewIfLoaded?.window, model?.showNotes != true else { return false }
        func editingText(in view: UIView) -> Bool {
            if view.isFirstResponder {
                if let textView = view as? UITextView { return textView.isEditable }
                if view is UITextField { return true }
                if view is UITextInput && !view.isDescendant(of: pdfView) { return true }
            }
            return view.subviews.contains(where: editingText)
        }
        guard !editingText(in: window) else { return false }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if let presented = controller.presentedViewController,
               presented.viewIfLoaded?.window != nil, !presented.isBeingDismissed { return false }
            ancestor = controller.parent
        }
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
#if READER_PROBE
        keyboardCommandQueries += 1
#endif
        guard keyboardNavigationAvailable else { return [] }
        let shortcuts: [(String, UIKeyModifierFlags, String)] = [
            (UIKeyCommand.inputDownArrow, [], "Aşağı kaydır"),
            (UIKeyCommand.inputUpArrow, [], "Yukarı kaydır"),
            (UIKeyCommand.inputPageDown, [], "Bir ekran aşağı"),
            (UIKeyCommand.inputPageUp, [], "Bir ekran yukarı"),
            (" ", [], "Bir ekran aşağı"),
            (" ", .shift, "Bir ekran yukarı")
        ]
        return shortcuts.map { input, modifiers, title in
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(scrollWithKeyboard(_:)))
            command.discoverabilityTitle = title
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(scrollWithKeyboard(_:)) { return keyboardNavigationAvailable }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func scrollWithKeyboard(_ command: UIKeyCommand) {
#if READER_PROBE
        keyboardActionCount += 1
#endif
        guard keyboardNavigationAvailable else { return }
        let backward = command.input == UIKeyCommand.inputUpArrow || command.input == UIKeyCommand.inputPageUp
            || (command.input == " " && command.modifierFlags.contains(.shift))
        if model?.displayMode == "page" {
            if backward { pdfView.goToPreviousPage(nil) } else { pdfView.goToNextPage(nil) }
            return
        }
        guard let scroll = scrollView else { return }
        let fullStep = command.input == UIKeyCommand.inputPageDown || command.input == UIKeyCommand.inputPageUp || command.input == " "
        let distance = fullStep ? scroll.bounds.height * 0.85 : CGFloat(model?.keyboardScrollStep ?? 80)
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let offset = min(maximum, max(minimum, scroll.contentOffset.y + (backward ? -distance : distance)))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
    }

    @objc private func restoreKeyboardFocusAfterScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended || gesture.state == .cancelled,
              keyboardNavigationAvailable else { return }
#if READER_PROBE
        keyboardFocusAccepted = becomeFirstResponder()
#else
        becomeFirstResponder()
#endif
    }

#if READER_PROBE
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyboardPressCount += presses.count
        super.pressesBegan(presses, with: event)
    }

    private func readerDiagnostics() -> String {
        ReaderKeyTrace.responder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.readerCaptureResponder), to: nil, from: nil, for: nil)
        let chain = ReaderKeyTrace.responder.map {
            Array(sequence(first: $0, next: { $0.next }).prefix(12)).map { String(describing: type(of: $0)) }
        } ?? []
        let state: [String: Any] = [
            "offset": scrollView?.contentOffset.y ?? -1,
            "height": scrollView?.bounds.height ?? 0,
            "decelerating": scrollView?.isDecelerating ?? false,
            "available": keyboardNavigationAvailable,
            "notes": model?.showNotes ?? false,
            "controllerFocused": isFirstResponder,
            "chain": chain,
            "focusAccepted": keyboardFocusAccepted,
            "codes": ReaderKeyTrace.codes,
            "queries": keyboardCommandQueries,
            "actions": keyboardActionCount,
            "presses": keyboardPressCount
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        updateControls()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        restoreNavigationChrome()
    }

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
        pdfView.accessibilityIdentifier = "reader.pdf"
#if READER_PROBE
        _ = ReaderKeyTrace.install
        pdfView.diagnostics = { [weak self] in self?.readerDiagnostics() ?? "{}" }
#endif
        toolPicker.showsDrawingPolicyControls = false
        // The overlay provider must be in place before the document is set.
        overlays.toolPicker = toolPicker
        overlays.onChange = { [weak self] page, previous, updated in self?.drawingChanged(page, from: previous, to: updated) }
        pdfView.pageOverlayViewProvider = overlays
        pdfView.document = document

        pdfView.addGestureRecognizer(pencilSelect)
        pdfView.addGestureRecognizer(pencilScroll)
        pdfView.addGestureRecognizer(pencilWordTap)
        pdfView.addGestureRecognizer(textTap)
        pdfView.addGestureRecognizer(hudTap)
        hudTap.require(toFail: pencilWordTap)
        pencilScroll.require(toFail: pencilSelect)
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
        pencilWordTap.isEnabled = newTool == .navigate
        pencilScroll.isEnabled = newTool == .navigate
        textTap.isEnabled = newTool == .text
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        scrollView?.panGestureRecognizer.allowedTouchTypes = [direct, pointer]
        if keyboardFocusScrollView !== scrollView {
            keyboardFocusScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(restoreKeyboardFocusAfterScroll(_:)))
            keyboardFocusScrollView = scrollView
            keyboardFocusScrollView?.panGestureRecognizer.addTarget(self, action: #selector(restoreKeyboardFocusAfterScroll(_:)))
        }
#if DEBUG
        if UserDefaults.standard.bool(forKey: "readerProbePencil") {
            scrollView?.panGestureRecognizer.allowedTouchTypes = [pointer]
        }
#endif
        if drawing { clearSelection() }
    }

    func updateControls() {
        guard isViewLoaded else { return }
        if model?.fullscreen == true, let navigationController {
            if chromeBeforeFullscreen == nil {
                fullscreenNavigationController = navigationController
                chromeBeforeFullscreen = (navigationController.isNavigationBarHidden, navigationController.isToolbarHidden)
            }
            if !navigationController.isNavigationBarHidden { navigationController.setNavigationBarHidden(true, animated: false) }
            if !navigationController.isToolbarHidden { navigationController.setToolbarHidden(true, animated: false) }
        } else if model?.fullscreen != true {
            restoreNavigationChrome()
        }
        let visible = tool == .draw && (model?.fullscreen != true || model?.hudVisible == true)
        if pickerVisible != visible {
            pickerVisible = visible
            toolPicker.setVisible(visible, forFirstResponder: self)
        }
    }

    private func restoreNavigationChrome() {
        guard let previous = chromeBeforeFullscreen else { return }
        fullscreenNavigationController?.setNavigationBarHidden(previous.navigationHidden, animated: false)
        fullscreenNavigationController?.setToolbarHidden(previous.toolbarHidden, animated: false)
        chromeBeforeFullscreen = nil
        fullscreenNavigationController = nil
    }

    func zoom(by multiplier: CGFloat) {
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pdfView.scaleFactor * multiplier))
    }

    func fitPage() {
        pdfView.autoScales = true
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
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
        if gestureRecognizer === hudTap || otherGestureRecognizer === hudTap { return true }
        let pencilGestures = [pencilSelect, pencilScroll, pencilWordTap] as [UIGestureRecognizer]
        return pencilGestures.contains(where: { $0 === gestureRecognizer })
            && !pencilGestures.contains(where: { $0 === otherGestureRecognizer })
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
        apply(tool: tool, force: true)
    }

    func setShapeSnap(_ enabled: Bool) {
        overlays.snapShapes = enabled
    }

    private var scrollView: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if view is PKCanvasView { return nil }
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(pdfView)
    }

    @objc private func scrollWithPencil(_ gesture: UIPanGestureRecognizer) {
        guard let scroll = scrollView else { return }
        switch gesture.state {
        case .began:
            pencilScrollOrigin = scroll.contentOffset
            clearSelection()
            fallthrough
        case .changed:
            guard let origin = pencilScrollOrigin else { return }
            let translation = gesture.translation(in: pdfView)
            let minimum = CGPoint(x: -scroll.adjustedContentInset.left, y: -scroll.adjustedContentInset.top)
            let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right),
                                  y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
            if model?.displayMode != "page" {
                scroll.setContentOffset(CGPoint(x: min(maximum.x, max(minimum.x, origin.x - translation.x)),
                                                y: min(maximum.y, max(minimum.y, origin.y - translation.y))), animated: false)
            }
        case .ended:
            if model?.displayMode == "page" {
                let translation = gesture.translation(in: pdfView)
                if translation.x < -40 { pdfView.goToNextPage(nil) }
                else if translation.x > 40 { pdfView.goToPreviousPage(nil) }
            }
            pencilScrollOrigin = nil
        case .cancelled, .failed:
            pencilScrollOrigin = nil
        default: break
        }
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
            let word = page.selectionForWord(at: point)
            selectionStart = (page, point, word)
            setReaderSelection(word)
        case .changed, .ended:
            guard let start = selectionStart else { return }
            let moved = start.page !== page || hypot(point.x - start.point.x, point.y - start.point.y) > 3
            let selection = moved
                ? document.selection(from: start.page, at: start.point, to: page, at: point)
                : start.word
            if moved, let word = start.word { selection?.add(word) }
            setReaderSelection(selection)
            if gesture.state == .ended {
                selectionStart = nil
                model?.isSelecting = false
            }
        default:
            selectionStart = nil
            model?.isSelecting = false
        }
    }

    @objc private func selectPencilWord(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: false) else { return }
        let word = page.selectionForWord(at: pdfView.convert(location, to: page))
        setReaderSelection(word)
    }

    private func setReaderSelection(_ selection: PDFSelection?) {
        selection?.color = UIColor.systemBlue.withAlphaComponent(0.3)
        pdfView.setCurrentSelection(selection, animate: false)
        selectionChanged()
    }

    @objc private func placeText(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        model?.textPlacement = TextPlacement(page: page, point: pdfView.convert(location, to: page))
    }

    @objc private func selectionChanged() {
        let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextText = (text?.isEmpty == false) ? text : nil
        if model?.selectionText != nextText { model?.selectionText = nextText }
    }

    @objc private func pageChanged() {
        if model?.pageCount != document.pageCount { model?.pageCount = document.pageCount }
        guard let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        if model?.currentPage != index { model?.currentPage = index }
    }

    func clearSelection() {
        pdfView.clearSelection()
        model?.isSelecting = false
        model?.selectionText = nil
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
        if previous.strokes.isEmpty && updated.strokes.isEmpty { return }
        guard previous.dataRepresentation() != updated.dataRepresentation() else { return }
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
