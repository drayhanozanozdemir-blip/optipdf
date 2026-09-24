import SwiftUI

/// A note to write or edit; `save` makes the change through the undoable controller paths.
struct NoteEditorRequest: Identifiable {
    let id = UUID()
    let title: String
    let quote: String
    let text: String
    let accent: Color
    /// Editing an existing note may clear it; a new note needs text.
    let allowsEmpty: Bool
    let save: (String) -> Void
}

/// The note sheet: the marked passage on top, a multi-line editor below, Kaydet and Vazgeç (⌘↩ and Esc).
struct NoteEditorSheet: View {
    let request: NoteEditorRequest
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != request.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if !request.quote.isEmpty {
                    Text("“\(request.quote)”")
                        .font(.callout)
                        .italic()
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(request.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Notunu yaz…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Not")
            }
            .padding()
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        request.save(trimmed)
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!request.allowsEmpty && trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(changed)
        .task {
            guard !loaded else { return }
            loaded = true
            text = request.text
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .onDisappear(perform: onClose)
    }
}

/// "Nota ekle" in the result sheet: the output becomes the note of the passage it came from (a new highlight when the
/// passage was only selected) or, for page results, a note icon on the page. Both show up in Notlar.
struct ResultNoteButton: View {
    @ObservedObject var model: EditorModel
    @State private var added: UUID?

    var body: some View {
        let result = model.result
        let done = result != nil && result?.id == added
        let ready = !(result?.output ?? "").isEmpty && result?.streaming == false && model.resultNote != nil
        Button(done ? "Eklendi" : "Nota ekle") {
            guard let result, let target = model.resultNote else { return }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            model.controller?.attachNote(result.title + "\n" + output, to: target)
            added = result.id
            model.show(toast: "Not eklendi.")
        }
        .disabled(done || !ready)
    }
}
