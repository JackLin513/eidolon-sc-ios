import EidolonCore
import SwiftUI

/// 朋友圈 (spec #98): what she posts when nobody is talking to her. Off until the switch in
/// settings is turned on; when off the page says so and neither generates nor deletes.
struct MomentsView: View {
    @Environment(AppModel.self) private var app

    @State private var posts: [MomentPost] = []
    @State private var loading = true
    @State private var failed = false
    @State private var commenting: MomentPost?
    @State private var commentText = ""
    @State private var deleting: MomentPost?

    var body: some View {
        NavigationStack {
            Group {
                if !app.momentsSettings.enabled {
                    ContentUnavailableView {
                        Label("朋友圈未开启", systemImage: "person.2.slash")
                    } description: {
                        Text("开启以后，她会在这里发自己的日常。")
                    } actions: {
                        Button("去设置开启") { app.selectedTab = .settings }
                            .accessibilityIdentifier("moments.openSettings")
                    }
                    .accessibilityIdentifier("moments.off")
                } else if loading, posts.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if failed, posts.isEmpty {
                    ContentUnavailableView {
                        Label("朋友圈读不出来", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else if posts.isEmpty {
                    ContentUnavailableView {
                        Label("还没有动态", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("她发第一条的时候会出现在这里。")
                    }
                    .accessibilityIdentifier("moments.empty")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(posts) { post in
                                row(post)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("朋友圈")
            .task {
                await load()
                await app.markMomentsOpened()
            }
            .alert("评论", isPresented: commentBinding, presenting: commenting) { post in
                TextField("140 字以内", text: $commentText, axis: .vertical)
                    .lineLimit(1...4)
                Button("取消", role: .cancel) {}
                Button("发送") {
                    Task {
                        if await app.commentMoment(post.id, text: commentText) {
                            commentText = ""
                            await load()
                        }
                    }
                }
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog(
                "删除评论？她的回复也会一起删掉。",
                isPresented: deletingBinding,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let post = deleting {
                        Task {
                            await app.deleteMomentComment(post.id)
                            await load()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .overlay(alignment: .top) {
            CallBar()
        }
    }

    private func row(_ post: MomentPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                avatar(post.characterID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(post.characterID))
                        .font(.subheadline.weight(.semibold))
                    Text(post.revealAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(post.ja)
                .font(.body)
            Text(post.zh)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let image = post.image {
                MomentImageView(record: image)
            }
            meta(post)
            if !post.reactions.isEmpty || post.liked || post.comment != nil {
                reactions(post)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button(post.liked ? "取消赞" : "赞") {
                Task {
                    if post.liked {
                        await app.unlikeMoment(post.id)
                    } else {
                        await app.likeMoment(post.id)
                    }
                    await load()
                }
            }
            if post.comment == nil {
                Button("评论") {
                    commentText = ""
                    commenting = post
                }
            } else {
                Button("删除评论", role: .destructive) { deleting = post }
            }
        }
    }

    private func meta(_ post: MomentPost) -> some View {
        HStack(spacing: 6) {
            if let place = post.place, !place.name.isEmpty {
                if let url = app.momentsSettings.mapProvider.url(
                    name: place.name, latitude: place.lat, longitude: place.lon
                ) {
                    Link(place.name, destination: url)
                        .font(.caption)
                } else {
                    Text(place.name).font(.caption)
                }
            }
            if let weather = post.weather {
                Label {
                    Text("\(weather.temperature)℃")
                } icon: {
                    Image(systemName: weather.kind.symbol)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    private func reactions(_ post: MomentPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let likes = post.reactions.filter { $0.kind == .like }.map { name($0.characterID) }
            if post.liked || !likes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                    Text(((post.liked ? ["制作人"] : []) + likes).joined(separator: "、"))
                        .font(.caption)
                }
            }
            ForEach(post.reactions.filter { $0.kind == .comment }) { reaction in
                VStack(alignment: .leading, spacing: 1) {
                    Text(name(reaction.characterID) + "：")
                        .font(.caption.weight(.semibold))
                        + Text(reaction.ja ?? "")
                        .font(.caption)
                    if let zh = reaction.zh, !zh.isEmpty {
                        Text(zh).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let comment = post.comment {
                VStack(alignment: .leading, spacing: 1) {
                    (Text("制作人：").font(.caption.weight(.semibold)) + Text(comment.text).font(.caption))
                    if let reply = comment.revealedReply {
                        (Text(name(post.characterID) + "：").font(.caption.weight(.semibold))
                            + Text(reply.ja).font(.caption))
                        Text(reply.zh).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func avatar(_ id: String) -> some View {
        Group {
            if let image = app.avatar(for: id) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private func name(_ characterID: String) -> String {
        app.characters.first { $0.id == characterID }.map { $0.nameZh ?? $0.name }
            ?? characterID
    }

    private var commentBinding: Binding<Bool> {
        Binding(
            get: { commenting != nil },
            set: { if !$0 { commenting = nil } }
        )
    }

    private var deletingBinding: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )
    }

    private func load() async {
        guard app.momentsSettings.enabled else {
            loading = false
            return
        }
        do {
            await app.runMoments()
            posts = try await app.core.momentsTimeline()
            failed = false
        } catch {
            failed = true
        }
        loading = false
    }
}

private struct MomentImageView: View {
    @Environment(AppModel.self) private var app
    let record: MomentImageRecord
    @State private var image: UIImage?
    @State private var viewing = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { viewing = true }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(height: 120)
                    .overlay { ProgressView() }
            }
        }
        .task(id: record.id) { image = await app.momentImage(record) }
        .fullScreenCover(isPresented: $viewing) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                Button {
                    viewing = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding()
            }
        }
    }
}
