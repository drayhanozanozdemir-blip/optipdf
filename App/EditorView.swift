import SwiftUI
import PDFKit
import Translation

struct EditorView: View {
    @ObservedObject var file: PDFFile
    @StateObject private var model = EditorModel()
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("targetLanguage") private var target = "tr"
    @AppStorage("engine") private var engine = "fable"
    @State private var searchText = ""
    @State private var question = ""
    @State private var asking = false
    @State private var noteDraft = ""
    @State private var addingNote = false

    static let languages: [(code: String, name: String)] = [
        ("tr", "Türkçe"), ("de-ch", "Deutsch (CH)"), ("gsw-zh", "Züritüütsch"), ("en", "English"),
        ("fr", "Français"), ("it", "Italiano"), ("es", "Español")
    ]

    var body: some View {
        PDFEditorRepresentable(document: file.pdf, model: model, undoManager: undoManager)
            .ignoresSafeArea(edges: model.fullscreen ? .all : .bottom)
            .overlay(alignment: .bottom) {
                if model.selectionText != nil { selectionBar.padding(.bottom, 24) }
            }
            .overlay(alignment: .top) { topOverlays }
            .overlay(alignment: .topTrailing) {
                if !model.searchResults.isEmpty && !model.fullscreen { searchPanel.padding(12) }
            }
            .toolbar(model.fullscreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(model.fullscreen)
            .persistentSystemOverlays(model.fullscreen ? .hidden : .automatic)
            .toolbarRole(.editor)
            .toolbar { toolbarContent }
            .searchable(text: $searchText, placement: .toolbar, prompt: "PDF'te ara")
            .onSubmit(of: .search) { model.search(searchText) }
            .onChange(of: searchText) { _, text in if text.isEmpty { model.search("") } }
            .inspector(isPresented: $model.showNotes) {
                NotesPanel(model: model, engine: engine, target: target)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
            .sheet(item: $model.result) { _ in
                ResultSheet(model: model, target: target)
            }
            .background {
                Color.clear.sheet(item: $model.textPlacement) { placement in
                    TextEntrySheet(model: model, placement: placement)
                }
            }
            .alert("Soru sor", isPresented: $asking) {
                TextField("Soru", text: $question)
                Button("Sor") { model.run(.ask(question), engine: engine, target: target) }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text(model.selectionText == nil ? "Cevap bu sayfanın metnine dayanır." : "Cevap seçili metne dayanır.")
            }
            .alert("Not ekle", isPresented: $addingNote) {
                TextField("Not", text: $noteDraft)
                Button("Kaydet") {
                    model.controller?.markSelection(.highlight, note: noteDraft)
                    noteDraft = ""
                }
                Button("Vazgeç", role: .cancel) { noteDraft = "" }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.controller?.commitDrawings() }
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Araç", selection: $model.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Text(tool.title).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button { model.run(.translatePage, engine: engine, target: target) } label: {
                    Label("Sayfayı çevir", systemImage: "character.book.closed")
                }
                Button { model.run(.summarizePage, engine: engine, target: target) } label: {
                    Label("Sayfayı özetle", systemImage: "text.redaction")
                }
                Button { asking = true } label: {
                    Label("Soru sor", systemImage: "questionmark.bubble")
                }
            } label: {
                Label("Yapay zekâ", systemImage: "sparkles")
            }
            Button { model.showNotes.toggle() } label: {
                Label("Notlar", systemImage: "note.text")
            }
            Menu {
                Picker("Hedef dil", selection: $target) {
                    ForEach(Self.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Picker("Motor", selection: $engine) {
                    Text("Fable (en iyi kalite)").tag("fable")
                    Text("Astra (hızlı)").tag("astra")
                    Text("Cihazda (hassas belgeler)").tag("device")
                }
            } label: {
                Label("Ayarlar", systemImage: "gearshape")
            }
            Button {
                model.showNotes = false
                model.fullscreen = true
            } label: {
                Label("Tam ekran", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    private var topOverlays: some View {
        VStack(spacing: 8) {
            if model.fullscreen { fullscreenBar }
            if model.tool == .draw { drawBar }
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.top, model.fullscreen ? 14 : 8)
    }

    private var fullscreenBar: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button { model.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 46, height: 36)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Divider().frame(height: 24)
            Button { model.fullscreen = false } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 46, height: 36)
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
    }

    private var drawBar: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $model.shapeSnap) {
                Label("Şekil", systemImage: "circle.square")
            }
            .toggleStyle(.button)
            Menu {
                Button { model.controller?.refine(text: true, shapes: true) } label: {
                    Label("Hepsini düzelt", systemImage: "wand.and.stars")
                }
                Button { model.controller?.refine(text: true, shapes: false) } label: {
                    Label("El yazısını metne çevir", systemImage: "textformat")
                }
                Button { model.controller?.refine(text: false, shapes: true) } label: {
                    Label("Şekilleri düzelt", systemImage: "triangle")
                }
            } label: {
                Label("Düzelt", systemImage: "wand.and.stars")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
    }

    private var selectionBar: some View {
        HStack(spacing: 4) {
            barButton("Çevir", "character.bubble") { model.run(.translate, engine: engine, target: target) }
            barButton("Açıkla", "sparkles") { model.run(.explain, engine: engine, target: target) }
            Divider().frame(height: 28)
            barButton("Vurgula", "highlighter") { model.controller?.markSelection(.highlight) }
            barButton("Altını çiz", "underline") { model.controller?.markSelection(.underline) }
            barButton("Not", "note.text.badge.plus") { addingNote = true }
            barButton("Kopyala", "doc.on.doc") {
                UIPasteboard.general.string = model.selectionText
                model.controller?.clearSelection()
            }
            barButton("Kapat", "xmark") { model.controller?.clearSelection() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(minWidth: 58, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.searchResults.count) sonuç").font(.headline)
                Spacer()
                Button {
                    searchText = ""
                    model.search("")
                } label: { Image(systemName: "xmark.circle.fill") }
            }
            .padding(10)
            List(Array(model.searchResults.prefix(200).enumerated()), id: \.offset) { _, selection in
                Button {
                    model.controller?.show(selection)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("S. \(model.controller?.pageNumber(of: selection) ?? 0)").font(.caption).foregroundStyle(.secondary)
                        Text(selection.string ?? "").lineLimit(1)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 300, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8, y: 2)
    }
}

struct ResultSheet: View {
    @ObservedObject var model: EditorModel
    let target: String
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let result = model.result {
                    VStack(alignment: .leading, spacing: 16) {
                        if !result.source.isEmpty {
                            Text(result.source)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .textSelection(.enabled)
                            Divider()
                        }
                        if !result.output.isEmpty {
                            Text(result.output).font(.body).textSelection(.enabled)
                            if result.streaming { ProgressView().controlSize(.small) }
                        } else if let preview = result.preview {
                            Text(preview).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                            Label("Anında ön çeviri (cihazda) · \(result.engineName) yazıyor…", systemImage: "bolt.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = result.error {
                            Text(error).foregroundStyle(.red)
                        } else if result.output.isEmpty && result.preview == nil {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(result.onDevice ? "Cihazda çevriliyor…" : "\(result.engineName) yazıyor…").foregroundStyle(.secondary)
                            }
                        }
                        if result.onDevice && !result.output.isEmpty {
                            Label("Metin iPad'den çıkmadı.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(model.result?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kopyala") {
                        UIPasteboard.general.string = model.result?.output
                    }
                    .disabled((model.result?.output ?? "").isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .translationTask(configuration) { session in
            guard let result = model.result else { return }
            do {
                let text = try await session.translate(result.source).targetText
                guard model.result?.id == result.id else { return }
                if result.onDevice {
                    model.result?.output = text
                } else if model.result?.output.isEmpty == true {
                    model.result?.preview = text
                }
            } catch {
                if result.onDevice, model.result?.id == result.id {
                    model.result?.error = "Cihazda çeviri yapılamadı: \(error.localizedDescription)"
                }
            }
        }
        .task(id: model.result?.id) {
            guard let result = model.result, result.isTranslation, result.error == nil else { return }
            if result.onDevice {
                configuration = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: EditorModel.deviceLanguageCode(target)))
            } else if let pair = await EditorModel.installedPair(for: result.source, target: target) {
                configuration = pair
            }
        }
    }
}

struct TextEntrySheet: View {
    @ObservedObject var model: EditorModel
    let placement: TextPlacement
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var size: CGFloat = 16
    @State private var colorName = "Siyah"
    private let colors: [(name: String, color: UIColor)] = [("Siyah", .black), ("Mavi", .systemBlue), ("Kırmızı", .systemRed), ("Yeşil", .systemGreen)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Kalemle doğrudan yazabilirsin, yazın metne döner") {
                    TextEditor(text: $text)
                        .font(.system(size: size))
                        .frame(minHeight: 150)
                }
                Section {
                    Picker("Boyut", selection: $size) {
                        Text("Küçük").tag(CGFloat(12))
                        Text("Orta").tag(CGFloat(16))
                        Text("Büyük").tag(CGFloat(22))
                    }
                    .pickerStyle(.segmented)
                    Picker("Renk", selection: $colorName) {
                        ForEach(colors, id: \.name) { item in
                            Text(item.name).tag(item.name)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Yazı ekle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ekle") {
                        let color = colors.first { $0.name == colorName }?.color ?? .black
                        model.controller?.addText(text, at: placement.point, on: placement.page, size: size, color: color)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct NotesPanel: View {
    @ObservedObject var model: EditorModel
    let engine: String
    let target: String
    @State private var editing: NoteItem?
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                HStack {
                    Button {
                        model.run(.summarizeNotes, engine: engine, target: target)
                    } label: {
                        Label("Notları özetle", systemImage: "sparkles")
                    }
                    .disabled(model.notes.isEmpty)
                    Spacer()
                    ShareLink(item: model.markdownExport()) {
                        Label("Dışa aktar", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.notes.isEmpty)
                }
                .buttonStyle(.borderless)
            }
            if model.notes.isEmpty {
                Text("Henüz not yok. Seç ile metni işaretle, Vurgula veya Not ekle; Çiz ile yaz.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.notes) { item in
                Button {
                    model.controller?.show(item.first)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
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
                    Button {
                        draft = item.note
                        editing = item
                    } label: {
                        Label("Not", systemImage: "square.and.pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Notlar")
        .alert("Not", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Not", text: $draft)
            Button("Kaydet") {
                if let item = editing { model.controller?.setNote(draft, on: item.first) }
                editing = nil
            }
            Button("Vazgeç", role: .cancel) { editing = nil }
        }
    }
}
