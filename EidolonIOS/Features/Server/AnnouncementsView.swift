import SwiftUI
import EidolonCore

/// 对话页首那个铃铛打开的公告（位置照上游的 `Announcements.tsx`）。
/// 「关闭」只收起，「已读」把列表里的都记成读过——只记在这台手机上。
struct AnnouncementsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// 打开那一刻的列表：这期间又拉到的新公告等收起之后才算，也就不会被「已读」记上。
    @State private var shown: [ServerAnnouncement] = []

    var body: some View {
        NavigationStack {
            Group {
                if shown.isEmpty {
                    ContentUnavailableView("还没有公告", systemImage: "bell")
                } else {
                    List(shown) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.title).font(.headline)
                                Spacer()
                                if item.id > app.server.latestAnnouncement {
                                    Text("新").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.tint, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                            Text(item.body).font(.callout).foregroundStyle(.secondary)
                            Text(String(item.publishedAt.prefix(10)))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("公告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("已读") {
                        app.server.markAnnouncementsSeen()
                        dismiss()
                    }
                    .disabled(shown.isEmpty)
                }
            }
        }
        .onAppear { shown = app.server.announcements }
    }
}
