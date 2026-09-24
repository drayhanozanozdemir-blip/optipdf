import SwiftUI
import PDFKit

/// One dot per highlight colour; the chosen one has a ring.
struct SwatchRow: View {
    let selected: HighlightColor?
    var diameter: CGFloat = 22
    var hitWidth: CGFloat = 32
    var hitHeight: CGFloat = 44
    /// Spoken before the colour name, e.g. "Renk: Mavi".
    let label: String
    let action: (HighlightColor) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HighlightColor.allCases) { color in
                Button { action(color) } label: {
                    Circle()
                        .fill(color.swatch)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
                        .padding(selected == color ? 3 : 0)
                        .overlay {
                            if selected == color { Circle().strokeBorder(Color.primary, lineWidth: 2) }
                        }
                        .frame(width: diameter, height: diameter)
                        .frame(width: hitWidth, height: hitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label): \(color.title)")
                .accessibilityAddTraits(selected == color ? .isSelected : [])
            }
        }
    }
}

/// "Vurgula" in the selection bar. Regular width: one dot per colour. Compact: a tap highlights in the last colour,
/// a long press picks another.
struct HighlightDots: View {
    let compact: Bool
    let action: (HighlightColor) -> Void
    @AppStorage(HighlightColor.storageKey) private var colorName = HighlightColor.sari.rawValue

    private var current: HighlightColor { HighlightColor(rawValue: colorName) ?? .sari }

    var body: some View {
        if compact {
            Menu {
                ForEach(HighlightColor.allCases) { color in
                    Button(color.title) { choose(color) }
                }
            } label: {
                Image(systemName: "highlighter")
                    .font(.system(size: 17, weight: .medium))
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(current.swatch).frame(width: 8, height: 8).offset(x: 3, y: 2)
                    }
                    .foregroundStyle(Color.primary)
                    .frame(minWidth: 38, minHeight: 44)
            } primaryAction: {
                choose(current)
            }
            .accessibilityLabel("Vurgula")
        } else {
            VStack(spacing: 0) {
                SwatchRow(selected: current, diameter: 18, hitWidth: 27, hitHeight: 28, label: "Vurgula") { choose($0) }
                Text("Vurgula").font(.caption2)
            }
            .frame(minHeight: 44)
        }
    }

    private func choose(_ color: HighlightColor) {
        colorName = color.rawValue
        action(color)
    }
}

/// Shown while the Vurgu tool is active, like the draw bar: undo, redo and the highlight colour.
struct HighlightColorStrip: View {
    @ObservedObject var model: EditorModel
    @AppStorage(HighlightColor.storageKey) private var colorName = HighlightColor.sari.rawValue

    var body: some View {
        HStack(spacing: 12) {
            Button { model.controller?.undoEdit() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Geri al")
            Button { model.controller?.redoEdit() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Yinele")
            Divider().frame(height: 24)
            SwatchRow(selected: HighlightColor(rawValue: colorName) ?? .sari, diameter: 24, hitWidth: 34, hitHeight: 36,
                      label: "Vurgu rengi") { colorName = $0.rawValue }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
    }
}

/// The action bar of a tapped highlight, underline, strike-out or note (colours, Not, Kopyala, Çevir, Sil), the
/// note sheet, and a short "Geri al" offer after Sil. Every change goes through the undoable controller paths.
struct MarkLayer: View {
    @ObservedObject var model: EditorModel
    let compact: Bool
    @AppStorage("targetLanguage") private var target = "tr"
    @AppStorage("engine") private var engine = "opus"
    @State private var undoOffer: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .allowsHitTesting(false)
                .sheet(item: $model.noteEditor) { request in
                    NoteEditorSheet(request: request) { model.controller?.refocusReader() }
                }
            if model.selectionText == nil, !model.isSelecting, let mark = model.activeMark {
                bar(mark)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 76)
            } else if undoOffer != nil, model.selectionText == nil {
                undoButton
                    .padding(.bottom, 76)
            }
        }
        .onChange(of: model.selectionText) { _, text in
            if text != nil, model.activeMark != nil { model.activeMark = nil }
        }
    }

    private func bar(_ mark: NoteItem) -> some View {
        let row = HStack(spacing: compact ? 0 : 4) {
            SwatchRow(selected: HighlightColor.match(mark.first.color), diameter: compact ? 18 : 22,
                      hitWidth: compact ? 26 : 32, label: "Renk") { color in
                model.controller?.recolor(mark.pairs, to: color)
            }
            Divider().frame(height: 28)
            action("Not", "square.and.pencil") {
                model.noteEditor = model.controller?.noteRequest(for: mark)
            }
            action("Kopyala", "doc.on.doc") {
                UIPasteboard.general.string = mark.quote.isEmpty ? mark.currentNote : mark.quote
                model.show(toast: "Kopyalandı.")
            }
            action("Çevir", "character.bubble") {
                model.run(.translate, engine: engine, target: target, quote: mark.quote.isEmpty ? mark.currentNote : mark.quote)
            }
            action("Sil", "trash", tint: .red) { delete(mark) }
            action("Kapat", "xmark") { model.activeMark = nil }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 3 : 6)

        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(maxWidth: 600)
        .frame(height: compact ? 58 : 66)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2)
    }

    private func action(_ title: String, _ symbol: String, tint: Color = .primary,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                if !compact { Text(title).font(.caption2) }
            }
            .foregroundStyle(tint)
            .frame(minWidth: compact ? 38 : 56, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func delete(_ mark: NoteItem) {
        model.controller?.remove(mark.pairs, actionName: "Sil")
        model.activeMark = nil
        let offer = UUID()
        undoOffer = offer
        Task {
            try? await Task.sleep(for: .seconds(4))
            if undoOffer == offer { undoOffer = nil }
        }
    }

    private var undoButton: some View {
        Button {
            model.controller?.undoEdit()
            undoOffer = nil
        } label: {
            Label("Silindi · Geri al", systemImage: "arrow.uturn.backward")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .shadow(radius: 8, y: 2)
    }
}
