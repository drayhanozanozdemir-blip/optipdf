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
    @objc fileprivate dynamic func readerSendEvent(_ event: UIEvent) {
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
    let sidecar: AnnotationSidecar?
    let reading: ReadingState?
    let model: EditorModel
    let undoManager: UndoManager?
    let title: String

    func makeUIViewController(context: Context) -> PDFEditorController {
        let controller = PDFEditorController(document: document)
        controller.sidecar = sidecar
        controller.reading = reading
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
    /// Large documents: notes and drawings go to the side file with their own undo stack, so SwiftUI never
    /// rewrites the whole PDF (see AnnotationSidecar).
    var sidecar: AnnotationSidecar?
    var reading: ReadingState?
    private let notesUndo = UndoManager()
    var editUndo: UndoManager? { sidecar == nil ? undo : notesUndo }
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
    private let findRelay = FindRelay()
    private var findMatches: [PDFSelection] = []
    /// Vurgu tool, tapped-mark bar and note targets (HighlightTool.swift).
    lazy var highlighter = HighlightInteraction(controller: self)
    private var findUpdate: (([PDFSelection], Bool) -> Void)?
    private var findJumped = false
    private var findDeliveryScheduled = false
    private static let findLimit = 400
    private var restoredPosition = false
    private var selectionStart: (page: PDFPage, point: CGPoint, word: PDFSelection?)?
    private var tool: EditorTool = .draw
    private weak var fullscreenNavigationController: UINavigationController?
    private var chromeBeforeFullscreen: (navigationHidden: Bool, toolbarHidden: Bool)?
    private var pickerVisible = false
    private var pencilScrollOrigin: CGPoint?
    private var pencilGlide: CADisplayLink?
    private var pencilGlideVelocity = CGPoint.zero
    private var pencilGlideTime: CFTimeInterval = 0
    private weak var keyboardFocusScrollView: UIScrollView?
    var readerPencilTouchTypes: [NSNumber] {
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

    override var undoManager: UndoManager? { sidecar == nil ? super.undoManager : notesUndo }

    var keyboardNavigationAvailable: Bool {
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
        } + navigationKeyCommands // ux-navigation hook: ⌘[ ⌘] ⌘L
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
        stopPencilGlide()
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
        if gesture.state == .began { stopPencilGlide() }
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
            "presses": keyboardPressCount,
            // ux-navigation probe state
            "page": model?.currentPage ?? -1,
            "scrubber": model?.navigation.scrubber?.probeState ?? [:],
            "back": model?.navigation.history.back.map(\.page) ?? [],
            "forward": model?.navigation.history.forward.map(\.page) ?? [],
            "capsule": model?.navigation.capsuleVisible ?? false,
            "chapter": model.flatMap { $0.navigation.chapterTitle(for: $0.currentPage) } ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        updateControls()
        guard !restoredPosition else { return }
        restoredPosition = true
        // Back to the page the user left; the layout exists by now.
        if let last = reading?.lastPage, last > 0, last < document.pageCount, let page = document.page(at: last) {
            DispatchQueue.main.async { [weak self] in self?.pdfView.go(to: page) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPencilGlide()
        restoreNavigationChrome()
        sidecar?.flush(from: document)
        reading?.saveNow()
    }

    @objc private func saveNotesBeforeSuspension() {
        sidecar?.flush(from: document)
        reading?.saveNow()
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
        findRelay.onMatch = { [weak self] match in self?.collect(match: match) }
        findRelay.onEnd = { [weak self] in self?.deliverMatches(final: true) }
        document.delegate = findRelay
        applyTint(model?.readingTint ?? .normal)
        model?.bookmarks = reading?.bookmarks ?? []

        pdfView.addGestureRecognizer(pencilSelect)
        pdfView.addGestureRecognizer(pencilScroll)
        pdfView.addGestureRecognizer(pencilWordTap)
        pdfView.addGestureRecognizer(textTap)
        pdfView.addGestureRecognizer(hudTap)
        hudTap.require(toFail: pencilWordTap)
        pencilScroll.require(toFail: pencilSelect)
        highlighter.install(after: pencilWordTap, before: hudTap)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(saveNotesBeforeSuspension),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        applyDisplay(model?.displayMode ?? "continuous")
        apply(tool: model?.tool ?? tool, force: true)
        installNavigation() // ux-navigation hook: page scrubber, jump history, link jumps
        DispatchQueue.main.async { [weak self] in
            self?.pageChanged()
        }
    }

    // MARK: Tools and display

    func apply(tool newTool: EditorTool, force: Bool = false) {
        guard force || newTool != tool else { return }
        tool = newTool
        guard isViewLoaded else { return }
        stopPencilGlide()
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
        highlighter.apply(tool: newTool, scroll: scrollView)
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
        // ux-navigation hook: a finger on the visible page scrubber belongs to the scrubber only.
        let scrubberTouch = model?.navigation.scrubber?.claims(touch) == true
        guard gestureRecognizer === hudTap else { return !scrubberTouch }
        // Any new touch on the page stops a pencil glide, as it stops a finger flick.
        stopPencilGlide()
        return !scrubberTouch && model?.fullscreen == true && model?.selectionText == nil && tool != .text
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

    func applyTint(_ tint: ReadingTint) {
        overlays.tint = tint
        pdfView.backgroundColor = tint.pageBackground
        view.backgroundColor = tint.pageBackground
    }

    /// Undo and redo of notes and drawings (the document's undo, or the notes undo of a large document).
    func undoEdit() { editUndo?.undo() }

    func redoEdit() { editUndo?.redo() }

    // MARK: Bookmarks

    func toggleBookmark() {
        guard let reading, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        let firstLine = (page.string ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let title = firstLine.isEmpty ? "Sayfa \(index + 1)" : String(firstLine.prefix(60))
        let added = reading.toggleBookmark(page: index, title: title)
        model?.bookmarks = reading.bookmarks
        model?.show(toast: added ? "Yer imi eklendi." : "Yer imi kaldırıldı.")
    }

    func removeBookmark(page: Int) {
        reading?.removeBookmark(page: page)
        model?.bookmarks = reading?.bookmarks ?? []
    }

    var scrollView: UIScrollView? {
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
            stopPencilGlide()
            pencilScrollOrigin = scroll.contentOffset
            clearSelection()
            fallthrough
        case .changed:
            guard let origin = pencilScrollOrigin else { return }
            let translation = gesture.translation(in: pdfView)
            if model?.displayMode != "page" {
                scroll.setContentOffset(clampedOffset(CGPoint(x: origin.x - translation.x, y: origin.y - translation.y),
                                                      in: scroll), animated: false)
            }
        case .ended:
            if model?.displayMode == "page" {
                let translation = gesture.translation(in: pdfView)
                if translation.x < -40 { pdfView.goToNextPage(nil) }
                else if translation.x > 40 { pdfView.goToPreviousPage(nil) }
            } else {
                let velocity = gesture.velocity(in: pdfView)
                startPencilGlide(CGPoint(x: -velocity.x, y: -velocity.y))
            }
            pencilScrollOrigin = nil
        case .cancelled, .failed:
            pencilScrollOrigin = nil
        default: break
        }
    }

    private func clampedOffset(_ offset: CGPoint, in scroll: UIScrollView) -> CGPoint {
        let inset = scroll.adjustedContentInset
        let minimum = CGPoint(x: -inset.left, y: -inset.top)
        let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + inset.right),
                              y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
        return CGPoint(x: min(maximum.x, max(minimum.x, offset.x)), y: min(maximum.y, max(minimum.y, offset.y)))
    }

    /// A pencil flick keeps gliding and slows down like a finger flick (UIScrollView's normal deceleration).
    private func startPencilGlide(_ velocity: CGPoint) {
        stopPencilGlide()
        guard hypot(velocity.x, velocity.y) > 150 else { return }
        pencilGlideVelocity = velocity
        pencilGlideTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(glide(_:)))
        link.add(to: .main, forMode: .common)
        pencilGlide = link
    }

    private func stopPencilGlide() {
        pencilGlide?.invalidate()
        pencilGlide = nil
    }

    @objc private func glide(_ link: CADisplayLink) {
        guard let scroll = scrollView, model?.displayMode != "page" else { return stopPencilGlide() }
        let elapsed = CGFloat(min(0.05, max(0, link.timestamp - pencilGlideTime)))
        pencilGlideTime = link.timestamp
        let decay = pow(UIScrollView.DecelerationRate.normal.rawValue, elapsed * 1000)
        pencilGlideVelocity = CGPoint(x: pencilGlideVelocity.x * decay, y: pencilGlideVelocity.y * decay)
        let wanted = CGPoint(x: scroll.contentOffset.x + pencilGlideVelocity.x * elapsed,
                             y: scroll.contentOffset.y + pencilGlideVelocity.y * elapsed)
        let next = clampedOffset(wanted, in: scroll)
        if next.x != wanted.x { pencilGlideVelocity.x = 0 }
        if next.y != wanted.y { pencilGlideVelocity.y = 0 }
        scroll.setContentOffset(next, animated: false)
        if hypot(pencilGlideVelocity.x, pencilGlideVelocity.y) < 15 { stopPencilGlide() }
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
            stopPencilGlide()
            model?.isSelecting = true
            let word = page.selectionForWord(at: point)
            selectionStart = (page, point, word)
            setReaderSelection(word)
        case .changed, .ended:
            guard let start = selectionStart else { return }
            let moved = start.page !== page || hypot(point.x - start.point.x, point.y - start.point.y) > 3
            if gesture.state == .ended, !moved, tool == .select, openMark(atViewPoint: location) {
                selectionStart = nil
                return
            }
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
        reading?.setLastPage(index)
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

    /// PDFKit's incremental find: matches arrive while the pages are still being scanned, so the first results
    /// of a 1514-page book show at once. The update closure gets the matches so far and whether the search ended.
    func search(_ query: String, update: @escaping ([PDFSelection], Bool) -> Void) {
        cancelFind()
        findUpdate = update
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    func clearSearch() {
        cancelFind()
        pdfView.highlightedSelections = nil
    }

    private func cancelFind() {
        if document.isFinding { document.cancelFindString() }
        findMatches = []
        findJumped = false
        findUpdate = nil
    }

    private func collect(match: PDFSelection) {
        guard findUpdate != nil else { return }
        findMatches.append(match)
        if findMatches.count >= Self.findLimit {
            document.cancelFindString()
            deliverMatches(final: true)
        } else if !findDeliveryScheduled {
            findDeliveryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.findDeliveryScheduled = false
                self?.deliverMatches(final: false)
            }
        }
    }

    private func deliverMatches(final: Bool) {
        guard let update = findUpdate else { return }
        // The end notice of a cancelled search can arrive after the next one began; that one is not finished.
        let finished = final && !document.isFinding
        pdfView.highlightedSelections = findMatches
        if !findJumped, let first = findMatches.first {
            findJumped = true
            noteJump(to: first.pages.first, kind: .search) // ux-navigation hook
            pdfView.go(to: first)
        }
        update(findMatches, finished)
        if finished { findUpdate = nil }
    }

    func show(_ selection: PDFSelection) {
        noteJump(to: selection.pages.first, kind: .search) // ux-navigation hook
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: true)
    }

    func show(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        noteJump(to: page) // ux-navigation hook
        pdfView.go(to: annotation.bounds, on: page)
    }

    func go(to destination: PDFDestination) {
        noteJump(to: destination.page) // ux-navigation hook
        pdfView.go(to: destination)
    }

    func goToPage(_ index: Int) {
        guard let page = document.page(at: index) else { return }
        noteJump(to: page) // ux-navigation hook
        pdfView.go(to: page)
    }

    /// ux-navigation hook: the part of `view` the tool picker covers, which the page scrubber keeps clear of.
    var toolPickerCoverage: CGRect { toolPicker.isVisible ? toolPicker.frameObscured(in: view) : .null }

    func pageNumber(of selection: PDFSelection) -> Int {
        guard let page = selection.pages.first else { return 0 }
        return document.index(for: page) + 1
    }

    // MARK: Pages

    private func allPages() -> [PDFPage] { (0..<document.pageCount).compactMap { document.page(at: $0) } }

    /// Moving or deleting pages would require rewriting the whole PDF, which large documents avoid.
    private func blocksPageEditing() -> Bool {
        guard sidecar != nil else { return false }
        model?.show(toast: "Bu büyük belgede sayfa düzenleme kapalı; notlar ve çizimler çalışır.")
        return true
    }

    func movePages(from source: IndexSet, to destination: Int) {
        guard !blocksPageEditing() else { return }
        let previous = allPages()
        var pages = previous
        pages.move(fromOffsets: source, toOffset: destination)
        setPages(pages, previous: previous, actionName: "Sayfa taşı")
    }

    func deletePages(_ offsets: IndexSet) {
        guard !blocksPageEditing() else { return }
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
        guard !blocksPageEditing() else { return }
        guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else { return }
        overlays.load(copy)
        let previous = allPages()
        var pages = previous
        pages.insert(copy, at: index + 1)
        setPages(pages, previous: previous, actionName: "Sayfa çoğalt")
    }

    func insertBlankPage(after index: Int) {
        guard !blocksPageEditing() else { return }
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
        guard !blocksPageEditing() else { return }
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

    /// One annotation per text line, all with one stamp. Highlight hooks: an explicit colour and selection (the Vurgu
    /// tool, "Nota ekle"), whole-second increasing stamps (MarkStamp) and one quad per line for other PDF readers.
    @discardableResult
    func markSelection(_ subtype: PDFAnnotationSubtype, note: String? = nil, color custom: UIColor? = nil,
                       selection explicit: PDFSelection? = nil) -> [(PDFPage, PDFAnnotation)] {
        guard let selection = explicit ?? pdfView.currentSelection else { return [] }
        let stamp = MarkStamp.next()
        let color: UIColor
        switch subtype {
        case .underline: color = custom ?? .systemBlue
        case .strikeOut: color = custom ?? .systemRed
        default: color = custom ?? HighlightColor.last.highlightColor
        }
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.userName = AnnotationSidecar.marker
                annotation.color = color
                annotation.modificationDate = stamp
                annotation.quadrilateralPoints = MarkGeometry.quad(for: bounds)
                if added.isEmpty, let note, !note.isEmpty { annotation.contents = note }
                added.append((page, annotation))
            }
        }
        add(added, actionName: "İşaretleme")
        clearSelection()
        return added
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
        annotation.userName = AnnotationSidecar.marker
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
        editUndo?.registerUndo(withTarget: self) { controller in controller.remove(items, actionName: actionName) }
        editUndo?.setActionName(actionName)
        notesChanged(on: items.map(\.0))
        model?.reloadNotes()
    }

    func remove(_ items: [(PDFPage, PDFAnnotation)], actionName: String) {
        guard !items.isEmpty else { return }
        for (page, annotation) in items { page.removeAnnotation(annotation) }
        if let mark = model?.activeMark, items.contains(where: { $0.1 === mark.first }) { model?.activeMark = nil }
        editUndo?.registerUndo(withTarget: self) { controller in controller.add(items, actionName: actionName) }
        editUndo?.setActionName(actionName)
        notesChanged(on: items.map(\.0))
        model?.reloadNotes()
    }

    func setNote(_ text: String, on annotation: PDFAnnotation) {
        let old = annotation.contents ?? ""
        guard old != text else { return }
        annotation.contents = text
        // A note on an annotation that came with the PDF is kept in the side file from now on.
        if sidecar != nil, !AnnotationSidecar.isOurs(annotation) { annotation.userName = AnnotationSidecar.marker }
        editUndo?.registerUndo(withTarget: self) { controller in controller.setNote(old, on: annotation) }
        editUndo?.setActionName("Not")
        if let page = annotation.page { notesChanged(on: [page]) }
        model?.reloadNotes()
    }

    // MARK: Drawing

    private func drawingChanged(_ page: PDFPage, from previous: PKDrawing, to updated: PKDrawing) {
        if previous.strokes.isEmpty && updated.strokes.isEmpty { return }
        guard previous.dataRepresentation() != updated.dataRepresentation() else { return }
        DrawingStorage.save(updated, on: page)
        editUndo?.registerUndo(withTarget: self) { controller in controller.restoreDrawing(previous, replacing: updated, on: page) }
        editUndo?.setActionName("Çizim")
        notesChanged(on: [page])
    }

    private func restoreDrawing(_ drawing: PKDrawing, replacing current: PKDrawing, on page: PDFPage) {
        overlays.replace(drawing, for: page)
        DrawingStorage.save(drawing, on: page)
        editUndo?.registerUndo(withTarget: self) { controller in controller.restoreDrawing(current, replacing: drawing, on: page) }
        editUndo?.setActionName("Çizim")
        notesChanged(on: [page])
    }

    func notesChanged(on pages: [PDFPage]) {
        guard let sidecar else { return }
        let count = document.pageCount
        sidecar.pagesChanged(pages.map { document.index(for: $0) }.filter { $0 >= 0 && $0 < count })
        sidecar.scheduleSave(from: document)
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
                canvas.userEditing = true
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

    // MARK: Export and sharing

    enum ExportMode {
        /// Notes stay real annotations and drawings become ink annotations, editable in Acrobat or Preview.
        case annotated
        /// Everything burned into the pages.
        case flattened
    }

    /// A copy for Files, Mail, Acrobat and other apps. Encoding runs in the background because a large PDF
    /// takes minutes and would trip the watchdog; large documents are copied from the original file plus
    /// OptiPDF's annotations, so the open document is not re-encoded while the user keeps reading.
    func export(_ mode: ExportMode) {
        let large = sidecar != nil
        model?.show(toast: large ? "Dışa aktarım hazırlanıyor; büyük belgede birkaç dakika sürebilir." : "Dışa aktarım hazırlanıyor…")
        var drawings: [Int: PKDrawing] = [:]
        for index in sidecar?.markedPageIndices ?? Array(0..<document.pageCount) {
            guard let page = document.page(at: index), let drawing = overlays.drawing(for: page), !drawing.strokes.isEmpty else { continue }
            drawings[index] = drawing
        }
        var stamps: [Int: UIImage] = [:]
        if mode == .flattened {
            for (index, drawing) in drawings {
                guard let page = document.page(at: index) else { continue }
                let size = DrawingStorage.displaySize(of: page)
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    stamps[index] = drawing.image(from: CGRect(origin: .zero, size: size), scale: 3)
                }
            }
        }
        let marks = sidecar?.collect(from: document).pages ?? []
        let base: () -> Data? = large ? { [sourceData = sidecar?.sourceData] in sourceData } : { [document] in document.dataRepresentation() }
        let suffix = mode == .flattened ? " (OptiPDF düz).pdf" : " (OptiPDF notlu).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(exportName + suffix)
        let inks = mode == .annotated ? drawings : [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let written = Self.writeCopy(base: base, marks: marks, drawings: inks, stamps: stamps, burnIn: mode == .flattened, to: url)
            DispatchQueue.main.async {
                guard let self else { return }
                guard written else {
                    self.model?.show(toast: "Dışa aktarılamadı.")
                    return
                }
                self.present(activity: [url])
            }
        }
    }

    nonisolated private static func writeCopy(base: () -> Data?, marks: [AnnotationSidecar.PageMarks], drawings: [Int: PKDrawing],
                                             stamps: [Int: UIImage], burnIn: Bool, to url: URL) -> Bool {
        guard let data = base(), let copy = PDFDocument(data: data) else { return false }
        for marks in marks {
            guard let page = copy.page(at: marks.index) else { continue }
            for annotation in marks.annotations where !DrawingStorage.isStorage(annotation) { page.addAnnotation(annotation) }
        }
        for index in 0..<copy.pageCount {
            guard let page = copy.page(at: index) else { continue }
            for annotation in page.annotations where DrawingStorage.isStorage(annotation) {
                page.removeAnnotation(annotation)
            }
            if let drawing = drawings[index] {
                for annotation in inkAnnotations(for: drawing, on: page) { page.addAnnotation(annotation) }
            }
            if let image = stamps[index] {
                let annotation = DrawingImageAnnotation(bounds: page.bounds(for: .cropBox), forType: .stamp, withProperties: nil)
                annotation.image = image
                page.addAnnotation(annotation)
            }
        }
        let options: [PDFDocumentWriteOption: Any] = burnIn ? [.burnInAnnotationsOption: true] : [:]
        guard let output = copy.dataRepresentation(options: options) else { return false }
        return (try? output.write(to: url, options: .atomic)) != nil
    }

    /// PencilKit strokes as PDF ink annotations, for copies other apps can edit. Drawings are stored in display
    /// units (top-left origin, page as shown); annotation paths are relative to the crop box, y up.
    nonisolated static func inkAnnotations(for drawing: PKDrawing, on page: PDFPage) -> [PDFAnnotation] {
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        func pagePoint(_ point: CGPoint) -> CGPoint {
            switch rotation {
            case 90: return CGPoint(x: point.y, y: point.x)
            case 180: return CGPoint(x: crop.width - point.x, y: point.y)
            case 270: return CGPoint(x: crop.width - point.y, y: crop.height - point.x)
            default: return CGPoint(x: point.x, y: crop.height - point.y)
            }
        }
        return drawing.strokes.compactMap { stroke in
            let points = stroke.path.interpolatedPoints(by: .distance(2)).map { pagePoint($0.location) }
            guard let first = points.first else { return nil }
            let path = UIBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            let annotation = PDFAnnotation(bounds: crop, forType: .ink, withProperties: nil)
            annotation.color = stroke.ink.color
            let border = PDFBorder()
            border.lineWidth = max(1, stroke.path.first?.size.width ?? 2)
            annotation.border = border
            annotation.add(path)
            return annotation
        }
    }

    /// The newest MetricKit crash and hang reports (see DiagnosticsCollector).
    func shareDiagnostics() {
        let reports = Array(DiagnosticsCollector.reports().prefix(5))
        guard !reports.isEmpty else {
            model?.show(toast: "Henüz tanılama kaydı yok; bir çökme veya donmadan sonraki açılışta oluşur.")
            return
        }
        present(activity: reports)
    }

    private func present(activity items: [Any]) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.maxX - 80, y: 0, width: 1, height: 1)
        present(sheet, animated: true)
    }
}

/// Relays PDFKit's find callbacks, which may come on any thread, to the main thread.
final class FindRelay: NSObject, PDFDocumentDelegate {
    var onMatch: ((PDFSelection) -> Void)?
    var onEnd: (() -> Void)?

    func didMatchString(_ instance: PDFSelection) {
        forward { self.onMatch?(instance) }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        forward { self.onEnd?() }
    }

    private func forward(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
