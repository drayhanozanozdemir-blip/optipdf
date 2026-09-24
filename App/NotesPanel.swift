import SwiftUI
import PDFKit

/// Colours and Markdown of the notes list.
enum NotesExport {
    /// The colour a mark shows (text boxes carry it in the font colour), fully opaque; nil when it has none.
    static func displayColor(of item: NoteItem) -> UIColor? {
        let annotation = item.first
        let color: UIColor? = annotation.markType == "FreeText" ? annotation.fontColor : annotation.color
        guard let c = HighlightColor.components(of: color), c.a > 0.05 else { return nil }
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func color(of item: NoteItem) -> HighlightColor? {
        HighlightColor.match(displayColor(of: item))
    }

    /// Grouped by page; each mark with its kind and palette colour, the quote, then the note.
    static func markdown(_ notes: [NoteItem]) -> String {
        var lines = ["# Notlar"]
        var page: Int?
        for item in notes {
            if item.pageIndex != page {
                page = item.pageIndex
                lines.append("")
                lines.append("## Sayfa \(item.pageIndex + 1)")
            }
            var heading = "**\(item.kind)**"
            if let color = color(of: item) { heading += " · \(color.title)" }
            lines.append("")
            lines.append(heading)
            if !item.quote.isEmpty { lines.append("> " + item.quote.replacingOccurrences(of: "\n", with: " ")) }
            if !item.note.isEmpty {
                lines.append("")
                lines.append(item.note)
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Notes and marks of the document: search over quote and note, colour filter, a swatch per mark, edit in a sheet.
struct NotesPanel: View {
    @ObservedObject var model: EditorModel
    let engine: String
    let target: String
    @State private var editing: NoteEditorRequest?
    @State private var query = ""
    @State private var colorFilter: HighlightColor?

    var body: some View {
        let visible = filtered()
        List {
            Section {
                HStack {
                    Button {
                        model.run(.summarizeNotes, engine: engine, target: target)
                    } label: {
                        Label("Notları özetle", systemImage: "sparkles")
                    }
                    .disabled(model.notes.isEmpty || model.notesLoading)
                    Spacer()
                    ShareLink(item: model.markdownExport()) {
                        Label("Dışa aktar", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.notes.isEmpty || model.notesLoading)
                }
                .buttonStyle(.borderless)
                searchField
                colorChips
            }
            if model.notesLoading {
                ProgressView("Notlar yükleniyor…")
            } else if model.notes.isEmpty {
                Text("Henüz not yok. Vurgu aracıyla metnin üzerinden geç ya da metni seçip Vurgula'ya dokun.")
                    .foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text("Eşleşen not yok.")
                    .foregroundStyle(.secondary)
            }
            ForEach(visible) { item in
                row(item)
            }
        }
        .navigationTitle("Notlar")
        .sheet(item: $editing) { request in
            NoteEditorSheet(request: request)
        }
    }

    private func filtered() -> [NoteItem] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return model.notes.filter { item in
            if let colorFilter, NotesExport.color(of: item) != colorFilter { return false }
            guard !words.isEmpty else { return true }
            return item.quote.range(of: words, options: options) != nil || item.note.range(of: words, options: options) != nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Notlarda ara", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Aramayı temizle")
            }
        }
    }

    private var colorChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil)
                ForEach(HighlightColor.allCases) { color in
                    chip(color)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ color: HighlightColor?) -> some View {
        let selected = colorFilter == color
        return Button { colorFilter = color } label: {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color.swatch).frame(width: 12, height: 12)
                }
                Text(color?.title ?? "Tümü").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemFill), in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ item: NoteItem) -> some View {
        let recolorable = PDFEditorController.tappableMarkTypes.contains(item.first.markType)
        // A text box's contents are its text, not a note.
        let notable = item.first.markType != "FreeText"
        return Button {
            model.controller?.show(item.first)
            if recolorable && item.first.page != nil { model.activeMark = item }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    swatch(item)
                    Text(item.kind).font(.caption.bold())
                    Spacer()
                    Text("S. \(item.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                }
                if !item.quote.isEmpty {
                    Text("“\(item.quote)”").font(.callout).italic().lineLimit(5)
                }
                if !item.note.isEmpty {
                    Text(item.note).font(.callout)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                model.controller?.remove(item.pairs, actionName: "Sil")
            } label: {
                Label("Sil", systemImage: "trash")
            }
            if notable {
                Button {
                    editing = model.controller?.noteRequest(for: item)
                } label: {
                    Label("Not", systemImage: "square.and.pencil")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if notable {
                Button {
                    editing = model.controller?.noteRequest(for: item)
                } label: {
                    Label("Not", systemImage: "square.and.pencil")
                }
            }
            if recolorable {
                Menu {
                    ForEach(HighlightColor.allCases) { color in
                        Button(color.title) { model.controller?.recolor(item.pairs, to: color) }
                    }
                } label: {
                    Label("Renk", systemImage: "paintpalette")
                }
            }
            Button(role: .destructive) {
                model.controller?.remove(item.pairs, actionName: "Sil")
            } label: {
                Label("Sil", systemImage: "trash")
            }
        }
    }

    private func swatch(_ item: NoteItem) -> some View {
        Circle()
            .fill(NotesExport.displayColor(of: item).map { Color(uiColor: $0) } ?? Color.clear)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1) }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}
