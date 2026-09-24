import SwiftUI
import PDFKit

/// Bottom left: the jump-back capsule above the page indicator "245 / 1514 · Kapitel", which opens "Sayfaya git".
struct ReaderPageIndicator: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var navigation: ReaderNavigation
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if navigation.capsuleVisible && model.selectionText == nil {
                JumpCapsule(navigation: navigation)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if model.pageCount > 0 && model.selectionText == nil && (!model.fullscreen || model.hudVisible) {
                Button { navigation.showGoTo = true } label: { indicator }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.pageIndicator")
                    .accessibilityHint("Sayfaya git")
            }
        }
        .padding(16)
        .animation(.easeOut(duration: 0.2), value: navigation.capsuleVisible)
        .task(id: model.pageRevision) {
            // Lazily, once the page is on screen; the outline is read off the main thread.
            try? await Task.sleep(for: .milliseconds(600))
            navigation.prepareChapters()
        }
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            if model.currentPageBookmarked { Image(systemName: "bookmark.fill").font(.caption) }
            Text("\(model.currentPage + 1) / \(model.pageCount)")
            if let chapter = navigation.chapterTitle(for: model.currentPage) {
                Text("· " + Self.shortened(chapter, to: compact ? 16 : 34))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    static func shortened(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// "‹ S. 123'e dön" after a jump, and "S. 245'e git ›" after going back.
struct JumpCapsule: View {
    @ObservedObject var navigation: ReaderNavigation

    var body: some View {
        HStack(spacing: 0) {
            if navigation.backPage != nil {
                Button { navigation.goBack() } label: {
                    Label(navigation.backTitle, systemImage: "chevron.backward")
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reader.jumpBack")
            }
            if navigation.backPage != nil && navigation.forwardPage != nil {
                Divider().frame(height: 22)
            }
            if navigation.forwardPage != nil {
                Button { navigation.goForward() } label: {
                    HStack(spacing: 6) {
                        Text(navigation.forwardTitle)
                        Image(systemName: "chevron.forward")
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reader.jumpForward")
            }
        }
        .font(.callout.weight(.medium))
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
    }
}

/// Menu entries: "Sayfaya git…", back and forward.
struct JumpMenuItems: View {
    @ObservedObject var navigation: ReaderNavigation

    var body: some View {
        Button { navigation.showGoTo = true } label: {
            Label("Sayfaya git…", systemImage: "number")
        }
        if navigation.backPage != nil {
            Button { navigation.goBack() } label: {
                Label(navigation.backTitle, systemImage: "chevron.backward")
            }
        }
        if navigation.forwardPage != nil {
            Button { navigation.goForward() } label: {
                Label(navigation.forwardTitle, systemImage: "chevron.forward")
            }
        }
    }
}

/// "Sayfaya git": number field (Return jumps, clamped), the last places, bookmarks and the page organizer.
struct GoToPageSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var navigation: ReaderNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var fieldFocused: Bool

    private var typedPage: Int? { PageNumberInput.pageIndex(from: input, pageCount: model.pageCount) }

    /// The page printed as the typed number ("612", "xii"), when the PDF's own page labels point elsewhere.
    private var printedPage: Int? {
        guard let index = navigation.chapters?.pageIndex(forLabel: input), index != typedPage else { return nil }
        return index
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        TextField("Sayfa (1–\(model.pageCount))", text: $input)
                            .keyboardType(.numberPad)
                            .submitLabel(.go)
                            .focused($fieldFocused)
                            .onSubmit(goToTypedPage)
                            .accessibilityIdentifier("reader.goto.field")
                        Button("Git", action: goToTypedPage)
                            .buttonStyle(.borderedProminent)
                            .disabled(typedPage == nil && printedPage == nil)
                            .accessibilityIdentifier("reader.goto.go")
                    }
                    if let printedPage {
                        Button {
                            go(to: printedPage)
                        } label: {
                            Text("Kitaptaki s. \(input.trimmingCharacters(in: .whitespaces)) → S. \(printedPage + 1)")
                        }
                    }
                } footer: {
                    Text(currentPlace)
                }
                let recent = navigation.recentPositions(excluding: model.currentPage)
                if !recent.isEmpty {
                    Section("Son konumlar") {
                        ForEach(recent, id: \.page) { position in
                            Button {
                                navigation.jump(to: position)
                                dismiss()
                            } label: {
                                pageRow(position.page)
                            }
                        }
                    }
                }
                if !model.bookmarks.isEmpty {
                    Section("Yer imleri") {
                        ForEach(model.bookmarks) { bookmark in
                            Button {
                                go(to: bookmark.page)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title).lineLimit(1)
                                    Text("S. \(bookmark.page + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        navigation.organizerAfterGoTo = true
                        dismiss()
                    } label: {
                        Label("Sayfalar", systemImage: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("reader.goto.pages")
                }
            }
            .navigationTitle("Sayfaya git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var currentPlace: String {
        var text = "Şu an S. \(model.currentPage + 1) / \(model.pageCount)"
        if let chapter = navigation.chapterTitle(for: model.currentPage) { text += " · " + chapter }
        return text
    }

    private func pageRow(_ page: Int) -> some View {
        HStack(spacing: 8) {
            Text("S. \(page + 1)").monospacedDigit()
            if let chapter = navigation.chapterTitle(for: page) {
                Text(chapter).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func goToTypedPage() {
        guard let page = typedPage ?? printedPage else { return }
        go(to: page)
    }

    private func go(to page: Int) {
        model.controller?.goToPage(page)
        dismiss()
    }
}

/// The go-to sheet and the organizer opened from it; the organizer waits until the go-to sheet is gone.
struct ReaderNavigationSheets: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var navigation: ReaderNavigation

    var body: some View {
        ZStack {
            Color.clear.sheet(isPresented: $navigation.showGoTo, onDismiss: goToClosed) {
                GoToPageSheet(model: model, navigation: navigation)
                    .presentationDetents([.medium, .large])
            }
            Color.clear.sheet(isPresented: $navigation.showOrganizer, onDismiss: { model.controller?.restoreReaderFocus() }) {
                PageOrganizerSheet(model: model)
            }
        }
    }

    private func goToClosed() {
        if navigation.organizerAfterGoTo {
            navigation.organizerAfterGoTo = false
            navigation.showOrganizer = true
        } else {
            model.controller?.restoreReaderFocus()
        }
    }
}
