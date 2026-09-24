import UIKit
import PDFKit
import UIKit.UIGestureRecognizerSubclass

/// The slim page scrubber on the right edge. It fades in while the page moves (finger, Pencil glide, keyboard) or
/// when a finger touches the page, and fades out 1.5 s later; in fullscreen it shows only with the controls.
/// Dragging its thumb jumps through the book with a bubble "S. 245 · Kapitel"; letting go is one jump in the history.
///
/// Its gesture sits on the PDF view and only takes finger and pointer touches that start on the visible thumb (44 pt
/// wide), so Pencil drawing, Pencil scrolling and gliding, text selection and keyboard focus stay as they were. It
/// also follows link taps for the jump history.
@MainActor
final class PageScrubber: NSObject, UIGestureRecognizerDelegate {
    static let hideDelay: CFTimeInterval = 1.5
    /// Live jumps while dragging, at most this often; the last position always follows on release.
    static let liveJumpInterval: CFTimeInterval = 0.06
#if READER_PROBE
    static let bubbleLinger: TimeInterval = 3
#else
    static let bubbleLinger: TimeInterval = 0.4
#endif

    private weak var controller: PDFEditorController?
    private weak var navigation: ReaderNavigation?
    let overlay = ScrubberOverlay()
    private lazy var drag: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.allowedTouchTypes = PageScrubber.fingerTouches
        gesture.delegate = self
        return gesture
    }()
    private lazy var touchWatch: TouchWatchGesture = {
        let gesture = TouchWatchGesture(target: nil, action: nil)
        gesture.allowedTouchTypes = PageScrubber.fingerTouches
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        gesture.onTouch = { [weak self] in self?.touched() }
        return gesture
    }()
    private static let fingerTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

    private weak var observedScroll: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var lastBounds = CGSize.zero
    private(set) var isShown = false
    private var dragging = false
    private var dragStart: ReaderPosition?
    private var dragAnchor: CGFloat = 0
    private var fraction: CGFloat = 0
    private var targetPage = 0
    private var bubblePage = -1
    private var liveJumpPage = -1
    private var lastLiveJump: CFTimeInterval = 0
    private var liveJumpPending = false
    private var lastActivity: CFTimeInterval = 0
    private var hidePending = false
    private var suppressedUntil: CFTimeInterval = 0
    private var lastScroll: CFTimeInterval = 0
    private var settlePending = false
    /// Where the reader was once scrolling last came to rest: the origin of a link jump that PDFKit already followed.
    private var settled: ReaderPosition?
    private var cachedPage: PDFPage?
    private var cachedIndex = 0
#if READER_PROBE
    private var probeJumps = 0
    private var probeJumpMillis: [Double] = []
#endif

    init(controller: PDFEditorController, navigation: ReaderNavigation) {
        self.controller = controller
        self.navigation = navigation
        super.init()
        let host: UIView = controller.view
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.insertSubview(overlay, aboveSubview: controller.pdfView)
        overlay.onLayout = { [weak self] in self?.layoutIfShown() }
        overlay.onAppear = { [weak self] in self?.suppress(for: 1.2) }
        overlay.track.onAdjust = { [weak self] step in self?.adjust(by: step) }
        controller.pdfView.addGestureRecognizer(drag)
        controller.pdfView.addGestureRecognizer(touchWatch)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: controller.pdfView)
        center.addObserver(self, selector: #selector(linkHit(_:)), name: .PDFViewAnnotationHit, object: controller.pdfView)
        watchScrollView()
    }

    func detach() {
        offsetObservation = nil
        drag.view?.removeGestureRecognizer(drag)
        touchWatch.view?.removeGestureRecognizer(touchWatch)
        overlay.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
    }

    /// Hook from the controller's gesture delegate: a finger on the visible thumb belongs to the scrubber only.
    func claims(_ touch: UITouch) -> Bool {
        guard isShown, touch.type == .direct || touch.type == .indirectPointer, !phoneDrawing else { return false }
        return thumbHitFrame().contains(touch.location(in: overlay))
    }

    // MARK: Showing and hiding

    func reveal() {
        let now = CACurrentMediaTime()
        guard !isShown else {
            lastActivity = now
            return
        }
        guard canShow else { return }
        isShown = true
        lastActivity = now
        updateFraction()
        layout()
        overlay.setVisible(true)
        scheduleHide(after: Self.hideDelay)
    }

    private func hide() {
        guard isShown, !dragging else { return }
        isShown = false
        overlay.setVisible(false)
    }

    /// Fullscreen, controls, selection changed (ReaderNavigation subscribes to the model).
    func chromeChanged() {
        guard let model = controller?.model else { return }
        if !canShow {
            hide()
        } else if model.fullscreen && model.hudVisible {
            reveal()
        } else if isShown {
            layout()
        }
    }

    func pagesChanged() {
        cachedPage = nil
        settled = nil
    }

    private var canShow: Bool {
        guard let controller, let model = controller.model, controller.document.pageCount > 1 else { return false }
        if model.fullscreen && !model.hudVisible { return false }
        if model.selectionText != nil || model.isSelecting { return false }
        return trackFrame().height >= 120
    }

    /// On iPhone the finger draws in Çiz; the scrubber then only shows the position.
    private var phoneDrawing: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && controller?.model?.tool == .draw
    }

    private func suppress(for duration: CFTimeInterval) {
        suppressedUntil = max(suppressedUntil, CACurrentMediaTime() + duration)
    }

    private func scheduleHide(after delay: CFTimeInterval) {
        guard !hidePending else { return }
        hidePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideIfIdle() }
    }

    private func hideIfIdle() {
        hidePending = false
        guard isShown else { return }
        let idle = CACurrentMediaTime() - lastActivity
        // In fullscreen the scrubber stays as long as the controls do.
        let pinned = controller?.model.map { $0.fullscreen && $0.hudVisible } ?? false
        if dragging || pinned {
            scheduleHide(after: Self.hideDelay)
        } else if idle < Self.hideDelay {
            scheduleHide(after: Self.hideDelay - idle)
        } else {
            hide()
        }
    }

    // MARK: Following the page

    private func watchScrollView() {
        guard let scroll = controller?.scrollView, scroll !== observedScroll else { return }
        observedScroll = scroll
        lastBounds = scroll.bounds.size
        offsetObservation = scroll.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrolled()
            }
        }
    }

    private func scrolled() {
        guard let scroll = observedScroll else { return }
        let now = CACurrentMediaTime()
        if scroll.bounds.size != lastBounds {
            // Rotation or a new window size moves the offset without anyone scrolling.
            lastBounds = scroll.bounds.size
            suppress(for: 0.5)
        }
        noteScroll(at: now)
        guard !dragging else { return }
        if isShown {
            lastActivity = now
            updateFraction()
            layout()
        } else if now >= suppressedUntil {
            reveal()
        }
    }

    @objc private func pageChanged() {
        // Page-turn mode swaps its scroll view.
        watchScrollView()
        noteScroll(at: CACurrentMediaTime())
        guard !dragging else { return }
        if isShown {
            updateFraction()
            layout()
        } else if controller?.model?.displayMode == "page", CACurrentMediaTime() >= suppressedUntil {
            reveal()
        }
    }

    private func touched() {
        if isShown { lastActivity = CACurrentMediaTime() } else { reveal() }
    }

    /// Position in the book, 0...1: the current page plus how far it is scrolled past the middle of the view.
    private func updateFraction() {
        guard let controller, let page = controller.pdfView.currentPage else { return }
        let document = controller.document
        let count = document.pageCount
        guard count > 0 else { return }
        if page !== cachedPage {
            let index = document.index(for: page)
            cachedPage = page
            cachedIndex = index == NSNotFound ? 0 : max(0, index)
        }
        var within: CGFloat = 0.5
        if controller.model?.displayMode != "page" {
            let pdfView = controller.pdfView
            let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            if rect.height > 1 { within = min(max((pdfView.bounds.midY - rect.minY) / rect.height, 0), 0.999) }
        }
        fraction = min(max((CGFloat(cachedIndex) + within) / CGFloat(count), 0), 1)
    }

    // MARK: Geometry

    private func trackFrame() -> CGRect {
        let bounds = overlay.bounds
        let safe = overlay.safeAreaInsets
        var top = safe.top + 12
        // Clear of the bottom row (page indicator, menu and Tam ekran, 44 pt with 16 pt padding).
        var bottom = bounds.maxY - safe.bottom - 72
        if let model = controller?.model, !model.fullscreen, model.searching || !model.searchResults.isEmpty {
            top += 372   // the search results panel, top right
        }
        if let covered = controller?.toolPickerCoverage, !covered.isNull, covered.maxX > bounds.maxX - 60 {
            if covered.midY > bounds.midY { bottom = min(bottom, covered.minY - 12) } else { top = max(top, covered.maxY + 12) }
        }
        let width: CGFloat = 44
        return CGRect(x: bounds.maxX - safe.right - width, y: top, width: width, height: max(0, bottom - top))
    }

    private func thumbHitFrame() -> CGRect {
        let track = trackFrame()
        let center = ScrubberOverlay.thumbCenterY(track: track, fraction: fraction)
        return CGRect(x: track.minX, y: center - 30, width: overlay.bounds.maxX - track.minX, height: 60)
    }

    private func layout() {
        guard let controller else { return }
        overlay.layout(track: trackFrame(), fraction: fraction, active: dragging)
        let page = dragging ? targetPage : cachedIndex
        overlay.track.accessibilityValue = "S. \(page + 1) / \(controller.document.pageCount)"
    }

    private func layoutIfShown() {
        if isShown { layout() }
    }

    // MARK: Dragging

    @objc private func dragged(_ gesture: UILongPressGestureRecognizer) {
        guard let controller else { return }
        let y = gesture.location(in: overlay).y
        switch gesture.state {
        case .began:
            dragging = true
            dragStart = controller.readerPosition()
            liveJumpPage = dragStart?.page ?? -1
            bubblePage = -1
            dragAnchor = y - ScrubberOverlay.thumbCenterY(track: trackFrame(), fraction: fraction)
            if let scroll = observedScroll {
                if scroll.isDecelerating { scroll.setContentOffset(scroll.contentOffset, animated: false) }
                // No scrolling under the finger while it holds the thumb.
                scroll.panGestureRecognizer.isEnabled = false
            }
            navigation?.prepareChapters()
            if controller.model?.fullscreen == true { controller.model?.showHUD() }
            follow(y)
        case .changed:
            follow(y)
        case .ended:
            follow(y)
            endDrag()
        case .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    private func follow(_ y: CGFloat) {
        guard let controller else { return }
        let count = controller.document.pageCount
        guard count > 0 else { return }
        let track = trackFrame()
        let thumb = ScrubberOverlay.activeThumb.height
        let travel = max(1, track.height - thumb)
        fraction = min(max((y - dragAnchor - track.minY - thumb / 2) / travel, 0), 1)
        targetPage = min(count - 1, Int(fraction * CGFloat(count)))
        if targetPage != bubblePage {
            bubblePage = targetPage
            let location = navigation?.chapters?.location(for: targetPage)
            var title = "S. \(targetPage + 1)"
            if let chapter = location?.chapter, !chapter.isEmpty { title += " · " + chapter }
            overlay.setBubble(title: title, subtitle: location?.section)
        }
        layout()
        requestLiveJump()
    }

    private func requestLiveJump() {
        guard dragging, targetPage != liveJumpPage, !liveJumpPending else { return }
        let wait = max(0, lastLiveJump + Self.liveJumpInterval - CACurrentMediaTime())
        liveJumpPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.liveJumpPending = false
            guard self.dragging, self.targetPage != self.liveJumpPage else { return }
            self.jump(to: self.targetPage)
        }
    }

    private func jump(to index: Int) {
        guard let controller, let page = controller.document.page(at: index) else { return }
        let start = CACurrentMediaTime()
        controller.pdfView.go(to: page)
        lastLiveJump = CACurrentMediaTime()
        liveJumpPage = index
#if READER_PROBE
        probeJumps += 1
        probeJumpMillis.append((lastLiveJump - start) * 1000)
#else
        _ = start
#endif
    }

    private func endDrag() {
        guard dragging else { return }
        dragging = false
        observedScroll?.panGestureRecognizer.isEnabled = true
        if targetPage != liveJumpPage { jump(to: targetPage) }
        if let start = dragStart { navigation?.record(from: start, to: targetPage, kind: .scrub) }
        dragStart = nil
        liveJumpPage = -1
        overlay.hideBubble(after: Self.bubbleLinger)
        lastActivity = CACurrentMediaTime()
        updateFraction()
        layout()
        scheduleHide(after: Self.hideDelay)
        if controller?.model?.fullscreen == true { controller?.model?.showHUD() }
        controller?.restoreReaderFocus()
    }

    /// VoiceOver: swipe up or down on the scrubber moves one percent of the book.
    private func adjust(by step: Int) {
        guard let controller, let current = controller.readerPosition() else { return }
        let count = controller.document.pageCount
        let target = min(max(current.page + step * max(1, count / 100), 0), count - 1)
        guard target != current.page, let page = controller.document.page(at: target) else { return }
        navigation?.record(from: current, to: target, kind: .scrub)
        controller.pdfView.go(to: page)
    }

    // MARK: Links

    @objc private func linkHit(_ notification: Notification) {
        guard let controller, let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else { return }
        let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
        guard let page = destination?.page else { return }
        let target = controller.document.index(for: page)
        guard target != NSNotFound, target >= 0 else { return }
        let current = controller.readerPosition()
        // Whether PDFKit follows the link before or after this notice, the place before it is the settled one.
        guard let from = current?.page == target ? settled : (current ?? settled), from.page != target else { return }
        navigation?.record(from: from, to: target, kind: .other)
    }

    private func noteScroll(at time: CFTimeInterval) {
        lastScroll = time
        guard !settlePending else { return }
        settlePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.settleIfIdle() }
    }

    private func settleIfIdle() {
        settlePending = false
        let idle = CACurrentMediaTime() - lastScroll
        if idle >= 0.35 {
            settled = controller?.readerPosition()
        } else {
            settlePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.4 - idle)) { [weak self] in self?.settleIfIdle() }
        }
    }

#if READER_PROBE
    var probeState: [String: Any] {
        let thumb = overlay.thumb.frame
        return ["shown": isShown, "dragging": dragging, "jumps": probeJumps,
                "jumpMs": probeJumpMillis.suffix(80).map { ($0 * 10).rounded() / 10 },
                "fraction": Double(fraction), "thumb": [Double(thumb.midX), Double(thumb.midY)]]
    }
#endif
}

/// Notices a finger touching the page and steps aside at once, so it never competes with scrolling or selection.
final class TouchWatchGesture: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouch?()
        state = .failed
    }
}

/// The scrubber's views. They never take touches (PageScrubber's gesture on the PDF view does).
final class ScrubberOverlay: UIView {
    static let thumbSize = CGSize(width: 6, height: 44)
    static let activeThumb = CGSize(width: 10, height: 52)

    let track = ScrubberTrack()
    let thumb = UIView()
    private let bubble = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var bubbleSize = CGSize.zero
    private var bubbleShown = false
    private var bubbleGeneration = 0
    private var lastTrack = CGRect.zero
    private var lastFraction: CGFloat = 0
    var onLayout: (() -> Void)?
    var onAppear: (() -> Void)?

    static func thumbCenterY(track: CGRect, fraction: CGFloat) -> CGFloat {
        track.minY + activeThumb.height / 2 + fraction * max(0, track.height - activeThumb.height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        alpha = 0
        accessibilityElementsHidden = true
        track.backgroundColor = UIColor.systemGray.withAlphaComponent(0.35)
        track.layer.cornerRadius = 1
        addSubview(track)
        thumb.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        thumb.layer.borderWidth = 1
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.3
        thumb.layer.shadowRadius = 2
        thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
        thumb.isAccessibilityElement = true
        thumb.accessibilityLabel = "Kaydırıcı tutamağı"
        thumb.accessibilityIdentifier = "reader.scrubber.thumb"
        addSubview(thumb)
        bubble.layer.cornerRadius = 12
        bubble.clipsToBounds = true
        bubble.alpha = 0
        titleLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail
        bubble.contentView.addSubview(titleLabel)
        bubble.contentView.addSubview(subtitleLabel)
        addSubview(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAppear?() }
    }

    func setVisible(_ visible: Bool) {
        accessibilityElementsHidden = !visible
        UIView.animate(withDuration: visible ? 0.15 : 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: { self.alpha = visible ? 1 : 0 })
    }

    func layout(track frame: CGRect, fraction: CGFloat, active: Bool) {
        lastTrack = frame
        lastFraction = fraction
        let x = frame.maxX - 9
        track.frame = CGRect(x: x - 1, y: frame.minY, width: 2, height: frame.height)
        let size = active ? Self.activeThumb : Self.thumbSize
        let centerY = Self.thumbCenterY(track: frame, fraction: fraction)
        thumb.frame = CGRect(x: x - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height)
        thumb.layer.cornerRadius = size.width / 2
        thumb.backgroundColor = active ? tintColor : UIColor.systemGray.withAlphaComponent(0.9)
        if bubble.alpha > 0 || bubbleShown { placeBubble() }
    }

    func setBubble(title: String, subtitle: String?) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        let hasSubtitle = !(subtitle ?? "").isEmpty
        subtitleLabel.isHidden = !hasSubtitle
        let maxText = max(96, min(400, bounds.width - 44 - 64))
        let fit = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let titleSize = titleLabel.sizeThatFits(fit)
        let subtitleSize = hasSubtitle ? subtitleLabel.sizeThatFits(fit) : .zero
        let textWidth = min(maxText, ceil(max(titleSize.width, subtitleSize.width)))
        titleLabel.frame = CGRect(x: 14, y: 9, width: textWidth, height: ceil(titleSize.height))
        subtitleLabel.frame = CGRect(x: 14, y: titleLabel.frame.maxY + 2, width: textWidth, height: ceil(subtitleSize.height))
        bubbleSize = CGSize(width: textWidth + 28, height: (hasSubtitle ? subtitleLabel.frame.maxY : titleLabel.frame.maxY) + 9)
        bubbleGeneration += 1
        if !bubbleShown {
            bubbleShown = true
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState], animations: { self.bubble.alpha = 1 })
        }
        placeBubble()
    }

    func hideBubble(after delay: TimeInterval) {
        bubbleShown = false
        bubbleGeneration += 1
        let generation = bubbleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.bubbleGeneration == generation, !self.bubbleShown else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState], animations: { self.bubble.alpha = 0 })
        }
    }

    /// Left of the thumb, level with it, inside the track's height.
    private func placeBubble() {
        let centerY = Self.thumbCenterY(track: lastTrack, fraction: lastFraction)
        let y = min(max(centerY - bubbleSize.height / 2, lastTrack.minY), max(lastTrack.minY, lastTrack.maxY - bubbleSize.height))
        bubble.frame = CGRect(x: max(8, lastTrack.minX - 8 - bubbleSize.width), y: y,
                              width: bubbleSize.width, height: bubbleSize.height)
    }
}

/// The scrubber for VoiceOver: an adjustable element ("S. 245 / 1514").
final class ScrubberTrack: UIView {
    var onAdjust: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "Sayfa kaydırıcı"
        accessibilityIdentifier = "reader.scrubber"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func accessibilityIncrement() { onAdjust?(1) }

    override func accessibilityDecrement() { onAdjust?(-1) }
}
