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
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                if model.selectionText != nil { selectionBar.padding(.bottom, 24) }
            }
            .overlay(alignment: .topTrailing) {
                if !model.searchResults.isEmpty { searchPanel.padding(12) }
            }
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
            .frame(width: 240)
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
        }
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
    @State private var deviceText: String?
    @State private var deviceError: String?

    private var deviceLanguage: String {
        ["tr": "tr", "de-ch": "de", "gsw-zh": "de", "en": "en", "fr": "fr", "it": "it", "es": "es"][target] ?? "en"
    }

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
                        if let text = result.onDevice ? deviceText : result.output {
                            Text(text).font(.body).textSelection(.enabled)
                        } else if let error = result.onDevice ? deviceError : result.error {
                            Text(error).foregroundStyle(.red)
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(result.onDevice ? "Cihazda çevriliyor…" : "Yapay zekâ çalışıyor…").foregroundStyle(.secondary)
                            }
                        }
                        if result.onDevice {
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
                        let text = (model.result?.onDevice == true ? deviceText : model.result?.output) ?? ""
                        UIPasteboard.general.string = text
                    }
                    .disabled(((model.result?.onDevice == true ? deviceText : model.result?.output) ?? "").isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .translationTask(configuration) { session in
            guard let source = model.result?.source else { return }
            do {
                deviceText = try await session.translate(source).targetText
            } catch {
                deviceError = "Cihazda çeviri yapılamadı: \(error.localizedDescription)"
            }
        }
        .onAppear {
            if model.result?.onDevice == true {
                configuration = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: deviceLanguage))
            }
        }
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
