import SwiftUI

struct ReplyListView: View {
    let video: BiliVideo
    let rootComment: BiliComment
    let repository: PaladalaRepository

    @StateObject private var model: ReplyListViewModel

    init(video: BiliVideo, rootComment: BiliComment, repository: PaladalaRepository) {
        self.video = video
        self.rootComment = rootComment
        self.repository = repository
        _model = StateObject(wrappedValue: ReplyListViewModel(video: video, rootComment: rootComment))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Root comment as a header
                    VStack(alignment: .leading, spacing: 12) {
                        CommentHeader(comment: rootComment)
                            .environmentObject(model)
                            .environmentObject(repository)
                        Divider()
                        Text("全部回覆 (\(model.totalCount))")
                            .font(PaladalaTheme.FontRole.sectionHeader)
                            .foregroundStyle(PaladalaTheme.ink)
                            .textCase(.uppercase)
                            .padding(.top, 4)
                    }
                    .padding(16)
                    .background(PaladalaTheme.paper)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .frame(height: PaladalaTheme.borderWidth)
                    }

                    // Replies list
                    LazyVStack(spacing: 0) {
                        if model.isLoading && model.replies.isEmpty {
                            ProgressView()
                                .padding()
                        } else if model.replies.isEmpty {
                            ContentUnavailableView(
                                L10n.replies.empty,
                                systemImage: "bubble.left",
                                description: Text(L10n.replies.emptyHint)
                            )
                            .padding(.vertical, 24)
                        } else {
                            ForEach(Array(model.replies.enumerated()), id: \.element.id) { index, reply in
                                ReplyItemRow(comment: reply, repository: repository, model: model)
                                    .onAppear {
                                        if index >= max(0, model.replies.count - 5) {
                                            Task { await model.loadMore(repository: repository) }
                                        }
                                    }
                                Divider()
                                    .padding(.leading, 62)
                            }
                        }

                        if model.isLoadingMore {
                            ProgressView()
                                .padding()
                        }
                    }
                    .background(PaladalaTheme.paper)
                }
            }
            
            commentInputField
                .padding()
                .background(PaladalaTheme.paper)
                .overlay(Divider(), alignment: .top)
        }
        .background(PaladalaTheme.canvas)
        .navigationTitle("回覆詳情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(repository: repository)
        }
    }

    @State private var newReplyText = ""
    @State private var isSubmitting = false

    private var commentInputField: some View {
        HStack(spacing: 12) {
            TextField("發表你的回覆…", text: $newReplyText)
                .font(PaladalaTheme.FontRole.bodySmall)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .disabled(isSubmitting)

            Button {
                isSubmitting = true
                Task {
                    if await model.submitReply(repository: repository, message: newReplyText) {
                        newReplyText = ""
                    }
                    isSubmitting = false
                }
            } label: {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("回覆")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.ink)
                }
            }
            .frame(minWidth: 52, minHeight: 44)
            .background(PaladalaTheme.biliPink)
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
            .buttonStyle(PaladalaPressBounceButtonStyle())
            .disabled(newReplyText.isEmpty || isSubmitting)
        }
    }
}

private struct CommentHeader: View {
    let comment: BiliComment
    @EnvironmentObject var model: ReplyListViewModel
    @EnvironmentObject var repository: PaladalaRepository

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(url: comment.avatarURL)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(
                            vipBadgeNicknameColor(for: comment.vipBadge)
                                ?? PaladalaTheme.ink
                        )
                        .textCase(.uppercase)
                    if let badge = comment.vipBadge, badge.isActive {
                        VipBadgeView(badge: badge, size: .small)
                    }
                    Spacer()
                    Button {
                        Task { await model.performCommentAction(repository: repository, rpid: comment.id, actionType: "like") }
                    } label: {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(comment.message)
                    .font(PaladalaTheme.FontRole.body)
                    .foregroundStyle(PaladalaTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReplyItemRow: View {
    let comment: BiliComment
    let repository: PaladalaRepository
    let model: ReplyListViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(url: comment.avatarURL)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(
                            vipBadgeNicknameColor(for: comment.vipBadge)
                                ?? PaladalaTheme.ink
                        )
                    if let badge = comment.vipBadge, badge.isActive {
                        VipBadgeView(badge: badge, size: .small)
                    }
                    Spacer()
                    Button {
                        Task { await model.performCommentAction(repository: repository, rpid: comment.id, actionType: "like") }
                    } label: {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(comment.message)
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(PaladalaTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AvatarImage: View {
    let url: URL?

    var body: some View {
        ResilientImage(url: url, maximumPixelSize: 160)
            .clipShape(Rectangle())
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
    }
}
