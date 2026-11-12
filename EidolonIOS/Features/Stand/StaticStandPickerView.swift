import EidolonCore
import SwiftUI
import UIKit

/// The static-stand wardrobe: outfit and pose are independent dimensions, unlike SC's
/// card + everyday/stage layout. It shares the selection value with the call screen but
/// keeps its own controls.
struct StaticStandPickerView: View {
    let character: CharacterConfig
    let onClose: () -> Void

    @Environment(AppModel.self) private var app
    @State private var bases: [StaticStandManifest.Base] = []
    @State private var selected: StaticAppearanceSelection
    @State private var images: [String: URL] = [:]
    @State private var image: UIImage?
    @State private var failure: String?

    private let emotions = StandEmotion.allCases

    init(character: CharacterConfig, onClose: @escaping () -> Void) {
        self.character = character
        self.onClose = onClose
        _selected = State(initialValue: StaticAppearanceStore().selection(for: character.id))
    }

    private var outfits: [String] { Array(Set(bases.map(\.outfit))).sorted() }
    private var poses: [String] { Array(Set(bases.map(\.pose))).sorted() }
    private var currentBase: StaticStandManifest.Base? {
        bases.first { $0.outfit == selected.outfit && $0.pose == selected.pose }
            ?? bases.first
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
            }
            selector("姿态", value: selected.pose ?? "—", options: poses) { value in
                selected.pose = value
            }
        }
    }

    private func selector(
        _ title: String,
        value: String,
        options: [String],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { value }, set: { onSelect($0) })) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
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
        bases = found
        if currentBase == nil {
            selected.outfit = outfits.first
            selected.pose = poses.first
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
        StaticAppearanceStore().remember(selected, for: character.id)
    }

    private func showEmotion() {
        guard let url = images[selected.emotion.rawValue] else { image = nil; return }
        image = UIImage(contentsOfFile: url.path)
        StaticAppearanceStore().remember(selected, for: character.id)
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


/// The last static appearance chosen per character, on this device only.
struct StaticAppearanceSelection: Codable, Hashable {
    var outfit: String?
    var pose: String?
    var emotion: StandEmotion

    init(outfit: String? = nil, pose: String? = nil, emotion: StandEmotion = .calm) {
        self.outfit = outfit
        self.pose = pose
        self.emotion = emotion
    }
}

struct StaticAppearanceStore {
    private let defaults = UserDefaults.standard
    private let key = "eidolon.staticAppearance"

    func selection(for characterID: String) -> StaticAppearanceSelection {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: StaticAppearanceSelection].self, from: data),
              let found = all[characterID]
        else { return StaticAppearanceSelection() }
        return found
    }

    func remember(_ selection: StaticAppearanceSelection, for characterID: String) {
        var all: [String: StaticAppearanceSelection] = [:]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: StaticAppearanceSelection].self, from: data) {
            all = decoded
        }
        all[characterID] = selection
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }
}
