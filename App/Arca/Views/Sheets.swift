import ArcaKit
import SwiftUI

struct PasswordSheet: View {
    let prompt: PasswordPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)
            VStack(spacing: 4) {
                Text("Password Required").font(.headline)
                Text(prompt.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                    prompt.onCancel?()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unlock", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        dismiss()
        prompt.retry(password)
    }
}

struct TextEditorSheet: View {
    @State var state: TextEditorState
    let onSave: (TextEditorState) -> Void
    let onCancel: () -> Void
    @State private var original = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: FileIcons.icon(for: state.path, isDirectory: false))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(state.path)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if state.text != original {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            TextEditor(text: $state.text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                Text("\(state.text.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save to Archive") { onSave(state) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.text == original)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 440, idealHeight: 560)
        .onAppear { original = state.text }
    }
}
