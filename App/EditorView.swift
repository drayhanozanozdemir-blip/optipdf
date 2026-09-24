import SwiftUI
import PDFKit
import Translation

struct EditorView: View {
    @ObservedObject var file: PDFFile
    let title: String
    @StateObject private var model = EditorModel()
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("targetLanguage") private var target = "tr"
    @AppStorage("engine") private var engine = "opus"
    @State private var searchText = ""
    @State private var question = ""
    @State private var asking = false
    @State private var noteDraft = ""
    @State private var addingNote = false
    @State private var showPages = false
    @State private var showOutline = false
    @State private var showBookmarks = false

    /// iPhone and narrow iPad windows: one menu instead of a toolbar row, icon-only selection bar.
    private var compact: Bool { sizeClass == .compact }

    static let languages: [(code: String, name: String)] = [
        ("tr", "Türkçe"), ("de-ch", "Deutsch (CH)"), ("gsw-zh", "Züritüütsch"), ("en", "English"),
        ("fr", "Français"), ("it", "Italiano"), ("es", "Español")
    ]

    var body: some View {
        PDFEditorRepresentable(document: file.pdf, sidecar: file.sidecar, reading: file.reading, model: model,
                               undoManager: undoManager, title: title)
            .ignoresSafeArea(edges: model.fullscreen ? .all : .bottom)
            .overlay(alignment: .bottom) {
                if model.selectionText != nil && !model.isSelecting {
                    selectionToolbar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 76)
                }
            }
            .overlay(alignment: .top) { topOverlays }
            .overlay(alignment: .bottomLeading) { pageIndicator }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Menu {
                        if model.fullscreen {
                            Button("Araçları göster") { model.showHUD() }
                        }
                        Button("Yakınlaştır", systemImage: "plus.magnifyingglass") { model.controller?.zoom(by: 1.35) }
                        Button("Uzaklaştır", systemImage: "minus.magnifyingglass") { model.controller?.zoom(by: 1 / 1.35) }
                        Button("Sayfayı sığdır", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                            model.controller?.fitPage()
                        }
                        JumpMenuItems(navigation: model.navigation) // ux-navigation hook
                        navigationButtons
                        Section("Araçlar ve ayarlar") {
                            Picker("Araç", selection: $model.tool) {
                                ForEach(EditorTool.allCases) { tool in
                                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                                }
                            }
                            settingsPickers
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Sayfa ve yakınlaştırma araçları")
                    Button {
                        if model.fullscreen { model.exitFullscreen() } else { model.enterFullscreen() }
                    } label: {
                        Label(model.fullscreen ? "Çık" : "Tam ekran",
                              systemImage: model.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .accessibilityLabel(model.fullscreen ? "Tam ekrandan çık" : "Tam ekran")
                    .accessibilityIdentifier("reader.fullscreen")
                }
                .buttonStyle(.plain)
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                if (model.searching || !model.searchResults.isEmpty) && !model.fullscreen { searchPanel.padding(12) }
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
                ZStack {
                    Color.clear.sheet(item: $model.textPlacement) { placement in
                        TextEntrySheet(model: model, placement: placement)
                    }
                    Color.clear.sheet(isPresented: $showPages) {
                        PageOrganizerSheet(model: model)
                    }
                    Color.clear.sheet(isPresented: $showOutline) {
                        OutlineSheet(model: model)
                    }
                    Color.clear.sheet(isPresented: $showBookmarks) {
                        BookmarksSheet(model: model)
                    }
                    ReaderNavigationSheets(model: model, navigation: model.navigation) // ux-navigation hook
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
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Araç", selection: $model.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Group {
                        if compact { Image(systemName: tool.symbol) } else { Text(tool.title) }
                    }
                    .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 190 : 300)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if compact {
                Menu {
                    Section { aiButtons }
                    Section { JumpMenuItems(navigation: model.navigation) } // ux-navigation hook
                    Section { navigationButtons }
                    Section { settingsPickers }
                    fullscreenButton
                } label: {
                    Label("Menü", systemImage: "ellipsis.circle")
                }
            } else {
                Menu { aiButtons } label: { Label("Yapay zekâ", systemImage: "sparkles") }
                navigationButtons
                Menu { settingsPickers } label: { Label("Ayarlar", systemImage: "gearshape") }
                fullscreenButton
            }
        }
    }

    @ViewBuilder
    private var aiButtons: some View {
        Button { model.run(.translatePage, engine: engine, target: target) } label: {
            Label("Sayfayı çevir", systemImage: "character.book.closed")
        }
        Button { model.run(.summarizePage, engine: engine, target: target) } label: {
            Label("Sayfayı özetle", systemImage: "text.redaction")
        }
        Button { asking = true } label: {
            Label("Soru sor", systemImage: "questionmark.bubble")
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        Button { model.showNotes.toggle() } label: {
            Label("Notlar", systemImage: "note.text")
        }
        Button { model.controller?.toggleBookmark() } label: {
            Label(model.currentPageBookmarked ? "Yer imini kaldır" : "Yer imi ekle",
                  systemImage: model.currentPageBookmarked ? "bookmark.fill" : "bookmark")
        }
        Button { showBookmarks = true } label: {
            Label("Yer imleri", systemImage: "bookmark.circle")
        }
        Button { showOutline = true } label: {
            Label("İçindekiler", systemImage: "list.bullet.indent")
        }
        Button { showPages = true } label: {
            Label("Sayfalar", systemImage: "square.grid.2x2")
        }
        Menu {
            Button { model.controller?.export(.annotated) } label: {
                Label("Notlu kopya (Acrobat'ta düzenlenebilir)", systemImage: "doc.badge.ellipsis")
            }
            Button { model.controller?.export(.flattened) } label: {
                Label("Düz kopya (çizimler görüntü olarak)", systemImage: "doc.richtext")
            }
        } label: {
            Label("Dışa aktar", systemImage: "square.and.arrow.up")
        }
    }

    @ViewBuilder
    private var settingsPickers: some View {
        Picker("Klavye kaydırma adımı", selection: $model.keyboardScrollStep) {
            Text("Kısa (40 pt)").tag(40.0)
            Text("Normal (80 pt)").tag(80.0)
            Text("Uzun (160 pt)").tag(160.0)
        }
        Picker("Görünüm", selection: $model.displayMode) {
            Text("Sürekli kaydır").tag("continuous")
            Text("Sayfa sayfa çevir").tag("page")
            Text("İki sayfa").tag("twoUp")
        }
        Picker("Okuma tonu", selection: $model.readingTint) {
            ForEach(ReadingTint.allCases) { tint in
                Text(tint.title).tag(tint)
            }
        }
        Picker("Hedef dil", selection: $target) {
            ForEach(Self.languages, id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
        Picker("Motor", selection: $engine) {
            Text("Opus 5.5 (en iyi kalite)").tag("opus")
            Text("Astra (hızlı)").tag("astra")
            Text("Cihazda (hassas belgeler)").tag("device")
        }
        Button { model.controller?.shareDiagnostics() } label: {
            Label("Tanılama kayıtlarını paylaş", systemImage: "waveform.path.ecg")
        }
    }

    private var fullscreenButton: some View {
        Button {
            model.enterFullscreen()
        } label: {
            Label("Tam ekran", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private var topOverlays: some View {
        VStack(spacing: 8) {
            if model.fullscreen && model.hudVisible { fullscreenBar }
            if model.tool == .draw && (!model.fullscreen || model.hudVisible) { drawBar }
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

    /// ux-navigation hook: chapter title, jump-back capsule; a tap opens "Sayfaya git" (ReaderNavigationViews.swift).
    private var pageIndicator: some View {
        ReaderPageIndicator(model: model, navigation: model.navigation, compact: compact)
    }

    private var fullscreenBar: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button { model.tool = tool; model.showHUD() } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 46, height: 36)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                .accessibilityLabel(tool.title)
            }
            Divider().frame(height: 24)
            Button { model.exitFullscreen() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 46, height: 36)
            }
            .accessibilityLabel("Tam ekrandan çık")
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
    }

    private var drawBar: some View {
        HStack(spacing: 14) {
            Button { model.controller?.undoEdit() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Geri al")
            Button { model.controller?.redoEdit() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Yinele")
            Divider().frame(height: 24)
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

    private var selectionToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            selectionBar
        }
        .frame(maxWidth: 560)
        .frame(height: compact ? 58 : 66)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2)
    }

    private var selectionBar: some View {
        HStack(spacing: compact ? 0 : 4) {
            barButton("Çevir", "character.bubble") { model.run(.translate, engine: engine, target: target) }
            barButton("Açıkla", "sparkles") { model.run(.explain, engine: engine, target: target) }
            Divider().frame(height: 28)
            barButton("Vurgula", "highlighter") { model.controller?.markSelection(.highlight) }
            barButton("Altını çiz", "underline") { model.controller?.markSelection(.underline) }
            barButton("Üstünü çiz", "strikethrough") { model.controller?.markSelection(.strikeOut) }
            barButton("Not", "note.text.badge.plus") { addingNote = true }
            barButton("Kopyala", "doc.on.doc") {
                UIPasteboard.general.string = model.selectionText
                model.controller?.clearSelection()
            }
            barButton("Kapat", "xmark") { model.controller?.clearSelection() }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 3 : 6)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                if !compact { Text(title).font(.caption2) }
            }
            .frame(minWidth: compact ? 38 : 56, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if model.searching {
                    ProgressView()
                    Text(model.searchResults.isEmpty ? "Aranıyor…" : "\(model.searchResults.count) sonuç…").font(.headline)
                } else {
                    Text("\(model.searchResults.count) sonuç").font(.headline)
                }
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
                            Label("Metin cihazdan çıkmadı.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
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
                    .disabled(model.notes.isEmpty || model.notesLoading)
                    Spacer()
                    ShareLink(item: model.markdownExport()) {
                        Label("Dışa aktar", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.notes.isEmpty || model.notesLoading)
                }
                .buttonStyle(.borderless)
            }
            if model.notesLoading {
                ProgressView("Notlar yükleniyor…")
            } else if model.notes.isEmpty {
                Text("Henüz not yok. Seç ile metni işaretle, Vurgula veya Not ekle.")
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
