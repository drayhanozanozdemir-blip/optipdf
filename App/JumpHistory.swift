import Foundation
import CoreGraphics

/// A place in the document precise enough to come back to: the page and, in the scrolling layouts, the exact scroll
/// offset. The offset only counts while zoom, layout and window size are unchanged (PDFEditorController.restore);
/// otherwise the page is used.
struct ReaderPosition: Codable, Equatable {
    var page: Int
    var offset: CGPoint?
    var contentSize: CGSize?
    var scale: CGFloat?
    var mode: String?

    init(page: Int, offset: CGPoint? = nil, contentSize: CGSize? = nil, scale: CGFloat? = nil, mode: String? = nil) {
        self.page = page
        self.offset = offset
        self.contentSize = contentSize
        self.scale = scale
        self.mode = mode
    }
}

/// Browsing search results or re-adjusting the scrubber keeps the place the reader started from.
enum JumpKind {
    case search, scrub, other
}

/// Back and forward through jumps, like a browser: outline, search result, bookmark, note, go to page, scrubber
/// release and links each remember the place they left.
struct JumpHistory {
    private(set) var back: [ReaderPosition] = []
    private(set) var forward: [ReaderPosition] = []
    /// Places the reader left, newest first, one per page ("Son konumlar").
    private(set) var recent: [ReaderPosition]
    private var lastJump: (kind: JumpKind, page: Int, time: Date)?
    let limit: Int
    let recentLimit: Int
    /// A search-result or scrubber jump that starts where the previous one of its kind landed, within this time,
    /// continues it instead of adding a place.
    static let coalesceWindow: TimeInterval = 60

    init(recent: [ReaderPosition] = [], limit: Int = 50, recentLimit: Int = 10) {
        self.recent = Array(recent.prefix(recentLimit))
        self.limit = limit
        self.recentLimit = recentLimit
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Records a jump from `from` to `page` and returns whether `from` became the back target. A jump within the
    /// page records nothing; a continued search or scrubber jump keeps the first place.
    @discardableResult
    mutating func record(from: ReaderPosition, to page: Int, kind: JumpKind = .other, at time: Date = Date()) -> Bool {
        guard from.page != page else { return false }
        var continues = false
        if kind != .other, !back.isEmpty, let last = lastJump {
            continues = last.kind == kind && last.page == from.page && time.timeIntervalSince(last.time) < Self.coalesceWindow
        }
        lastJump = (kind, page, time)
        forward.removeAll()
        guard !continues else { return false }
        back.append(from)
        if back.count > limit { back.removeFirst(back.count - limit) }
        remember(from)
        return true
    }

    /// Returns the place to restore; `current` becomes the forward target.
    mutating func goBack(from current: ReaderPosition) -> ReaderPosition? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        remember(current)
        lastJump = nil
        return target
    }

    /// Returns the place to restore; `current` becomes the back target.
    mutating func goForward(from current: ReaderPosition) -> ReaderPosition? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        remember(current)
        lastJump = nil
        return target
    }

    /// The newest places left, without the page the reader is on.
    func recentPositions(excluding page: Int, limit: Int = 5) -> [ReaderPosition] {
        Array(recent.lazy.filter { $0.page != page }.prefix(limit))
    }

    /// Page numbers changed (pages moved, inserted or deleted): the remembered places are no longer valid.
    mutating func reset() {
        back.removeAll()
        forward.removeAll()
        recent.removeAll()
        lastJump = nil
    }

    private mutating func remember(_ position: ReaderPosition) {
        recent.removeAll { $0.page == position.page }
        recent.insert(position, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
    }
}

/// What the reader typed into "Sayfaya git".
enum PageNumberInput {
    /// The 0-based page for `text`: its first number, thousands separators allowed ("1.514", "1 514"), clamped to
    /// the document. nil when there is no number or no page.
    static func pageIndex(from text: String, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let separators: [Character] = [".", ",", "'", "’", " ", "\u{00A0}", "\u{202F}"]
        var digits = ""
        var separated = false
        for character in text {
            if character.isASCII && character.isWholeNumber {
                digits.append(character)
                separated = false
            } else if digits.isEmpty {
                continue
            } else if !separated && separators.contains(character) {
                separated = true
            } else {
                break
            }
        }
        guard !digits.isEmpty else { return nil }
        let number = digits.count > 9 ? Int.max : (Int(digits) ?? Int.max)
        return min(max(number, 1), pageCount) - 1
    }
}

enum TurkishText {
    /// The number with its dative ending as it is read aloud: "123'e", "6'ya", "9'a", "2'ye".
    static func dative(_ number: Int) -> String {
        "\(number)'\(dativeEnding(number))"
    }

    static func dativeEnding(_ number: Int) -> String {
        let units = ["", "bir", "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz"]
        let tens = ["", "on", "yirmi", "otuz", "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan"]
        let n = abs(number)
        let word: String
        if n == 0 {
            word = "sıfır"
        } else if n % 10 != 0 {
            word = units[n % 10]
        } else if n % 100 != 0 {
            word = tens[n / 10 % 10]
        } else if n % 1000 != 0 {
            word = "yüz"
        } else if n % 1_000_000 != 0 {
            word = "bin"
        } else if n % 1_000_000_000 != 0 {
            word = "milyon"
        } else {
            word = "milyar"
        }
        let vowels: [Character] = ["a", "e", "ı", "i", "o", "ö", "u", "ü"]
        let lastVowel = word.last(where: { vowels.contains($0) }) ?? "e"
        let ending = ["a", "ı", "o", "u"].contains(lastVowel) ? "a" : "e"
        let endsWithVowel = word.last.map { vowels.contains($0) } ?? false
        return endsWithVowel ? "y" + ending : ending
    }
}
