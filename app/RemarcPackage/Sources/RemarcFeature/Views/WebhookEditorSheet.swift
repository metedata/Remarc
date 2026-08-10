import SwiftUI

/// Wraps the webhook being edited so `.sheet(item:)` can drive add vs edit.
struct WebhookEditorState: Identifiable {
    let id = UUID()
    var webhook: Webhook
    let isNew: Bool
}

/// Add/edit sheet for a webhook endpoint: name, URL, event subscriptions,
/// optional signing secret, and optional custom payload template.
struct WebhookEditorSheet: View {
    let state: WebhookEditorState
    let onSave: (Webhook) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: Webhook
    @State private var useCustomTemplate: Bool

    init(state: WebhookEditorState, onSave: @escaping (Webhook) -> Void) {
        self.state = state
        self.onSave = onSave
        _draft = State(initialValue: state.webhook)
        _useCustomTemplate = State(initialValue: !(state.webhook.customTemplate ?? "").isEmpty)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedURL: String {
        draft.url.trimmingCharacters(in: .whitespaces)
    }

    private var urlIsValid: Bool {
        var candidate = draft
        candidate.url = trimmedURL
        return candidate.hasValidURL
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && urlIsValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.isNew ? "Add Webhook" : "Edit Webhook")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                labeledField("Name") {
                    TextField("Slack alerts", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                labeledField("URL") {
                    TextField("https://hooks.example.com/...", text: $draft.url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                if !trimmedURL.isEmpty && !urlIsValid {
                    CalloutView(.warning, "Enter a valid http or https URL.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Events")
                    .font(.system(size: 12, weight: .medium))
                ForEach(WebhookEventType.subscribable, id: \.self) { event in
                    Toggle(event.label, isOn: eventBinding(event))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
                Text("Sending a card manually always works, regardless of subscriptions.")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.4))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Signing secret (optional)")
                    .font(.system(size: 12, weight: .medium))
                SecureField("whsec_...", text: secretBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("When set, requests include a webhook-signature header (HMAC SHA-256, Standard Webhooks format).")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Custom payload template", isOn: $useCustomTemplate)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Replace the default JSON payload with your own body, e.g. for Slack incoming webhooks")

                if useCustomTemplate {
                    TextEditor(text: templateBinding)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 90)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                        )
                    Text("Placeholders: {{event}}, {{timestamp}}, {{comment.text}}, {{comment.shortID}}, {{comment.status}}, {{comment.selectedText}}, {{comment.source}}, {{comment.resolutionSummary}}, {{comment.resolvedBy}}, {{comment.id}}, {{session.name}}, {{session.id}}. Values are JSON-escaped.")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(state.isNew ? "Add" : "Save") {
                    var final = draft
                    final.name = trimmedName
                    final.url = trimmedURL
                    let template = (final.customTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    final.customTemplate = (useCustomTemplate && !template.isEmpty) ? template : nil
                    let secret = (final.secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    final.secret = secret.isEmpty ? nil : secret
                    onSave(final)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            content()
        }
    }

    private func eventBinding(_ event: WebhookEventType) -> Binding<Bool> {
        Binding(
            get: { draft.events.contains(event) },
            set: { isOn in
                if isOn {
                    draft.events.insert(event)
                } else {
                    draft.events.remove(event)
                }
            }
        )
    }

    private var secretBinding: Binding<String> {
        Binding(
            get: { draft.secret ?? "" },
            set: { draft.secret = $0 }
        )
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: { draft.customTemplate ?? "" },
            set: { draft.customTemplate = $0 }
        )
    }
}
