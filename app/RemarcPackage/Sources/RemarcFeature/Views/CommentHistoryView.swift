import SwiftUI

struct CommentHistoryView: View {
    @Binding var showingHistory: Bool
    @Binding var restoredCommentID: UUID?
    @Binding var searchText: String
    @Binding var sortNewestFirst: Bool
    @ObservedObject private var persistence = PersistenceManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var deletedComments: [Comment] {
        var result = persistence.deletedComments.sorted {
            if sortNewestFirst {
                return ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
            } else {
                return ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast)
            }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { comment in
                if let displayText = comment.type.displayText,
                   displayText.lowercased().contains(query) {
                    return true
                }
                if comment.commentText.lowercased().contains(query) {
                    return true
                }
                if comment.source.lowercased().contains(query) {
                    return true
                }
                return false
            }
        }
        return result
    }

    var body: some View {
        if deletedComments.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(deletedComments) { comment in
                        HistoryCardView(comment: comment, onRestore: {
                            restoreComment(comment)
                        }, onPermanentDelete: {
                            permanentlyDelete(comment)
                        })
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
            Image(systemName: searchText.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.primary.opacity(0.25))

            Text(searchText.isEmpty ? "No deleted comments" : "No results")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func permanentlyDelete(_ comment: Comment) {
        persistence.permanentlyDeleteComment(comment.id)
        ToastManager.shared.show("Permanently deleted")
    }

    private func restoreComment(_ comment: Comment) {
        if let sessionID = persistence.appState.activeSessionID {
            let commentID = comment.id
            persistence.restoreComment(commentID, to: sessionID)
            restoredCommentID = commentID
            withAnimation(.easeInOut(duration: 0.15)) { showingHistory = false }
            MenuBarPopoverController.shared.resizeAfterLayoutSettles()
            // Clear highlight after 1.2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.5)) { restoredCommentID = nil }
            }
            ToastManager.shared.show("Comment restored")
        }
    }
}
