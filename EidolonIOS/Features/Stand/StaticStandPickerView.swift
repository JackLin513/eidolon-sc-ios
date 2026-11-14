import EidolonCore
import SwiftUI
import UIKit

/// The static-stand wardrobe: outfit and pose are independent dimensions, unlike SC's
/// card + everyday/stage layout. It shares the selection value with the call screen but
/// keeps its own controls.
struct StaticStandPickerView: View {
    let character: CharacterConfig
    let storageKey: String
    let onClose: () -> Void

    @Environment(AppModel.self) private var app
    @State private var bases: [StaticStandManifest.Base] = []
    @State private var selected: StaticAppearanceSelection
    @State private var images: [String: URL] = [:]
    @State private var image: UIImage?
    @State private var failure: String?

    private let emotions = StandEmotion.allCases

    init(character: CharacterConfig, storageKey: String, onClose: @escaping () -> Void) {
        self.character = character
        self.storageKey = storageKey
        self.onClose = onClose
        _selected = State(initialValue: StaticAppearanceStore().selection(for: storageKey))
    }

    private var outfits: [String] { Array(Set(bases.map(\.outfit))).sorted() }
    private var poses: [String] { Array(Set(bases.map(\.pose))).sorted() }
    private var currentBase: StaticStandManifest.Base? {
        bases.first { $0.outfit == selected.outfit && $0.pose == selected.pose }
            ?? bases.first
    }

    /// A pose is only offered when this outfit actually has that base. Missing
    /// outfit/pose combinations are shown disabled instead of silently falling back
    /// to the first base, which made a made-up selection look real.
    private func hasBase(outfit: String?, pose: String?) -> Bool {
        guard let outfit, let pose else { return false }
        return bases.contains { $0.outfit == outfit && $0.pose == pose }
    }

    private func firstPose(outfit: String) -> String? {
        bases.first { $0.outfit == outfit && $0.expressions[StandEmotion.calm.rawValue] != nil }?.pose
            ?? bases.first { $0.outfit == outfit }?.pose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                if bases.count > 1 {
                    selectors
                }
                emotionPicker
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("换衣装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }
                }
            }
            .task { await load() }
            .onChange(of: selected.outfit) { _, _ in Task { await loadBase() } }
            .onChange(of: selected.pose) { _, _ in Task { await loadBase() } }
            .onChange(of: selected.emotion) { _, _ in showEmotion() }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(hex: character.color ?? "#333333").opacity(0.18))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if let failure {
                ContentUnavailableView("没有静态立绘", systemImage: "person.crop.rectangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .frame(height: 380)
    }

    private var selectors: some View {
        HStack(spacing: 12) {
            selector("衣装", value: selected.outfit ?? "—", options: outfits) { value in
                selected.outfit = value
                if !hasBase(outfit: value, pose: selected.pose) {
                    selected.pose = firstPose(outfit: value)
                }
            }
            selector(
                "姿态",
                value: selected.pose ?? "—",
                options: poses,
                enabled: { hasBase(outfit: selected.outfit, pose: $0) }
            ) { value in
                selected.pose = value
            }
        }
    }

    private func selector(
        _ title: String,
        value: String,
        options: [String],
        enabled: @escaping (String) -> Bool = { _ in true },
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        if enabled(option) {
                            Text(option)
                        } else {
                            Text("\(option)（没有这组）")
                        }
                    }
                    .disabled(!enabled(option))
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.body.weight(.medium))
            }
            .accessibilityLabel("\(title) \(value)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emotionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(emotions, id: \.self) { emotion in
                    Button(emotionName(emotion)) {
                        selected.emotion = emotion
                        showEmotion()
                    }
                    .buttonStyle(.bordered)
                    .tint(selected.emotion == emotion ? .accentColor : .secondary)
                    .disabled(images[emotion.rawValue] == nil)
                }
            }
        }
    }

    private func load() async {
        guard let found = await app.staticStandBases(characterID: character.id), !found.isEmpty else {
            failure = "当前内容包没有 v2 静态立绘，或立绘包未安装"
            return
        }
        bases = found.filter { $0.expressions[StandEmotion.calm.rawValue] != nil }
        guard !bases.isEmpty else {
            failure = "静态立绘没有可用的 calm 表情"
            return
        }
        let catalog = AppearanceCatalog(characterID: character.id, bases: bases)
        if currentBase == nil {
            selected.outfit = catalog.dimension("outfit")?.options.first?.id
            selected.pose = catalog.dimension("pose")?.options.first?.id
        }
        await loadBase()
    }

    private func loadBase() async {
        guard let base = currentBase else { return }
        selected.outfit = base.outfit
        selected.pose = base.pose
        images = await app.staticStandExpressions(characterID: character.id, baseID: base.id) ?? [:]
        if images[selected.emotion.rawValue] == nil,
           let first = emotions.first(where: { images[$0.rawValue] != nil }) {
            selected.emotion = first
        }
        showEmotion()
        StaticAppearanceStore().remember(selected, for: storageKey)
    }

    private func showEmotion() {
        guard let url = images[selected.emotion.rawValue] else { image = nil; return }
        image = UIImage(contentsOfFile: url.path)
        StaticAppearanceStore().remember(selected, for: storageKey)
    }

    private func emotionName(_ emotion: StandEmotion) -> String {
        switch emotion {
        case .calm: "平静"
        case .happy: "开心"
        case .shy: "害羞"
        case .surprised: "惊讶"
        case .sad: "难过"
        case .angry: "生气"
        case .thinking: "思考"
        }
    }
}

