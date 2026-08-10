import SwiftUI

@available(macOS 26, *)
struct TranscriptionHistoryView: View {
    @Binding var searchText: String
    @Binding var sortNewestFirst: Bool
    @ObservedObject private var persistence = PersistenceManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var transcriptions: [Transcription] {
        var result = persistence.transcriptions
        if !sortNewestFirst {
            result.reverse()
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.text.lowercased().contains(query) }
        }
        return result
    }

    var body: some View {
        if transcriptions.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(transcriptions) { transcription in
                        TranscriptionCardView(transcription: transcription)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .background(ScrollerHider())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.primary.opacity(0.25))

            if searchText.isEmpty {
                VStack(spacing: 4) {
                    Text("No transcriptions yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.6))
                    Text("Press ⌃⌥D to dictate")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.4))
                }
            } else {
                Text("No results")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - TranscriptionCardView

@available(macOS 26, *)
struct TranscriptionCardView: View {
    let transcription: Transcription

    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var showDeleteConfirmation = false
    @Environment(\.colorScheme) private var colorScheme

    private var showActions: Bool { isHovered || showDeleteConfirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(transcription.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { isExpanded.toggle() }

            HStack(spacing: 4) {
                Text(metadataText)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 2) {
                    CardActionButton(icon: "doc.on.doc", tooltip: "Copy", tint: Color.remarcPrimary(for: colorScheme)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcription.text, forType: .string)
                        ToastManager.shared.show("Copied")
                    }
                    CardActionButton(icon: "trash", tooltip: "Delete", tint: Color.remarcError(for: colorScheme)) {
                        showDeleteConfirmation = true
                    }
                    .popover(isPresented: $showDeleteConfirmation, arrowEdge: .bottom) {
                        VStack(spacing: 8) {
                            Text("Delete transcription?")
                                .font(.system(size: 12, weight: .medium))
                            Text("This cannot be undone.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.6))
                            HStack(spacing: 8) {
                                ConfirmationButton(label: "Cancel", role: .cancel) {
                                    showDeleteConfirmation = false
                                }
                                ConfirmationButton(label: "Delete", role: .destructive) {
                                    showDeleteConfirmation = false
                                    PersistenceManager.shared.permanentlyDeleteTranscription(transcription.id)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
                .opacity(showActions ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: showActions)
            }
        }
        .padding(12)
        .modifier(CardSurfaceModifier(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }

    private var metadataText: String {
        let timeAgo = transcription.createdAt.formatted(.relative(presentation: .named))
        if let appName = transcription.appName {
            return "\(timeAgo) · \(appName)"
        }
        return timeAgo
    }
}
