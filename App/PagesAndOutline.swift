import SwiftUI
import PDFKit

struct PageOrganizerSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        PageRow(model: model, index: index, revision: model.pageRevision)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.controller?.goToPage(index)
                                dismiss()
                            }
                            .contextMenu {
                                Button { model.controller?.rotatePage(index, by: -90) } label: {
                                    Label("Sola döndür", systemImage: "rotate.left")
                                }
                                Button { model.controller?.rotatePage(index, by: 90) } label: {
                                    Label("Sağa döndür", systemImage: "rotate.right")
                                }
                                Button { model.controller?.duplicatePage(index) } label: {
                                    Label("Çoğalt", systemImage: "plus.square.on.square")
                                }
                                Button { model.controller?.insertBlankPage(after: index) } label: {
                                    Label("Arkasına boş sayfa ekle", systemImage: "doc.badge.plus")
                                }
                                Button(role: .destructive) { model.controller?.deletePages(IndexSet(integer: index)) } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { source, destination in model.controller?.movePages(from: source, to: destination) }
                    .onDelete { offsets in model.controller?.deletePages(offsets) }
                }
                .onAppear {
                    // 1500 pages: open where the reader is.
                    let current = model.currentPage
                    DispatchQueue.main.async { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .navigationTitle("Sayfalar (\(model.pageCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
    }
}

/// Rows appear lazily; thumbnails render off the main thread and come from an NSCache when scrolled back to
/// (PageThumbnails in ReaderNavigation.swift).
struct PageRow: View {
    @ObservedObject var model: EditorModel
    let index: Int
    let revision: Int
    @State private var thumbnail: UIImage?

    init(model: EditorModel, index: Int, revision: Int) {
        self.model = model
        self.index = index
        self.revision = revision
        _thumbnail = State(initialValue: model.navigation.thumbnails.cached(index: index, revision: revision))
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 64, height: 86)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sayfa \(index + 1)")
                if index == model.currentPage {
                    Text("Şu an burada").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .task(id: "\(index)-\(revision)") {
            let thumbnails = model.navigation.thumbnails
            if let cached = thumbnails.cached(index: index, revision: revision) {
                thumbnail = cached
                return
            }
            guard let document = model.controller?.document else { return }
            if let rendered = await thumbnails.render(page: index, of: document, revision: revision) {
                thumbnail = rendered
            }
        }
    }
}

struct OutlineNode: Identifiable {
    let id = UUID()
    let label: String
    let destination: PDFDestination?
    let children: [OutlineNode]?

    init(_ outline: PDFOutline) {
        label = outline.label ?? "—"
        destination = outline.destination
        let kids = (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.map { OutlineNode($0) }
        children = kids.isEmpty ? nil : kids
    }
}

struct OutlineSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [OutlineNode]?
    @State private var pageInput = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Sayfa numarası (1–\(model.pageCount))", text: $pageInput)
                            .keyboardType(.numberPad)
                        Button("Git") {
                            if let index = PageNumberInput.pageIndex(from: pageInput, pageCount: model.pageCount) {
                                model.controller?.goToPage(index)
                                dismiss()
                            }
                        }
                        .disabled(PageNumberInput.pageIndex(from: pageInput, pageCount: model.pageCount) == nil)
                    }
                }
                if let nodes, !nodes.isEmpty {
                    Section("İçindekiler") {
                        OutlineGroup(nodes, children: \.children) { node in
                            Button(node.label) {
                                if let destination = node.destination { model.controller?.go(to: destination) }
                                dismiss()
                            }
                        }
                    }
                } else if nodes != nil {
                    Text("Bu PDF'te içindekiler bilgisi yok.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("İçindekiler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } }
            }
        }
        .task {
            guard let root = model.controller?.document.outlineRoot else {
                nodes = []
                return
            }
            nodes = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }.map { OutlineNode($0) }
        }
    }
}

struct BookmarksSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.bookmarks.isEmpty {
                    Text("Henüz yer imi yok. Menüden «Yer imi ekle» ile sayfayı işaretle.").foregroundStyle(.secondary)
                }
                ForEach(model.bookmarks) { bookmark in
                    Button {
                        model.controller?.goToPage(bookmark.page)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bookmark.title).lineLimit(2)
                            Text("Sayfa \(bookmark.page + 1) · \(bookmark.added.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let pages = offsets.map { model.bookmarks[$0].page }
                    for page in pages { model.controller?.removeBookmark(page: page) }
                }
            }
            .navigationTitle("Yer imleri")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } }
            }
        }
    }
}
