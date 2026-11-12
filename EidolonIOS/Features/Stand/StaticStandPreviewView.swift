import EidolonCore
import SwiftUI
import UIKit

/// A deliberately small first renderer for image-based stands. It proves the package
/// binding and expression mapping without touching the Spine/Unity runtime protocols.
struct StaticStandPreviewView: View {
    @Environment(AppModel.self) private var app

    @State private var character: CharacterConfig?
    @State private var expressions: [String: URL] = [:]
    @State private var selected = "calm"
    @State private var bases: [StaticStandManifest.Base] = []
    @State private var outfit = ""
    @State private var pose = ""
    @State private var image: UIImage?
    @State private var failure: String?

    private let order = ["calm", "happy", "shy", "surprised", "sad", "angry", "thinking"]

    var body: some View {
        VStack(spacing: 0) {
            stage
            controls
        }
        .navigationTitle("静态立绘")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var stage: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.26)],
                startPoint: .top,
                endPoint: .bottom
            )
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            } else if let failure {
                ContentUnavailableView {
                    Label("没有静态立绘", systemImage: "person.crop.rectangle")
                } description: {
                    Text(failure)
                }
                .foregroundStyle(.white)
            } else {
                ProgressView("正在载入静态立绘…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if let character {
                Text(character.name)
                    .font(.headline)
                Text("contentSetID \(app.bundleInfo?.contentSetID ?? "legacy") · \(app.staticStandInfo?.contentSetID ?? "未绑定")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if outfits.count > 1 {
                axis("衣装", values: outfits, selected: outfit) { value in
                    outfit = value
                    Task { await loadBase() }
                }
            }
            if poses.count > 1 {
                axis("姿态", values: poses, selected: pose) { value in
                    pose = value
                    Task { await loadBase() }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(order.filter { expressions[$0] != nil }, id: \.self) { emotion in
                        Button(emotionName(emotion)) { select(emotion) }
                            .buttonStyle(.bordered)
                            .tint(selected == emotion ? .accentColor : .secondary)
                            .accessibilityIdentifier("staticStand.expression.\(emotion)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 42)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var outfits: [String] { Array(Set(bases.map(\.outfit))).sorted() }
    private var poses: [String] { Array(Set(bases.map(\.pose))).sorted() }

    private func axis(_ title: String, values: [String], selected: String, choose: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Button(value) { choose(value) }
                            .buttonStyle(.bordered)
                            .tint(selected == value ? .accentColor : .secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func emotionName(_ raw: String) -> String {
        switch raw {
        case "calm": "平静"
        case "happy": "开心"
        case "shy": "害羞"
        case "surprised": "惊讶"
        case "sad": "难过"
        case "angry": "生气"
        case "thinking": "思考"
        default: raw
        }
    }

    private func load() async {
        guard let first = app.characters.first else {
            failure = "当前内容包里没有角色"
            return
        }
        character = first
        guard let found = await app.staticStandBases(characterID: first.id), !found.isEmpty else {
            failure = "当前内容包没有配对静态立绘，或立绘包未安装"
            return
        }
        bases = found
        outfit = found.first?.outfit ?? ""
        pose = found.first?.pose ?? ""
        await loadBase()
    }

    private func loadBase() async {
        guard let base = bases.first(where: { $0.outfit == outfit && $0.pose == pose }),
              let first = character
        else { return }
        let found = await app.staticStandExpressions(characterID: first.id, baseID: base.id) ?? [:]
        expressions = found
        if found[selected] == nil, let firstKey = order.first(where: { found[$0] != nil }) {
            selected = firstKey
        }
        select(selected)
    }

    private func select(_ emotion: String) {
        guard let path = expressions[emotion],
              let loaded = UIImage(contentsOfFile: path.path)
        else { return }
        selected = emotion
        image = loaded
        failure = nil
    }
}
