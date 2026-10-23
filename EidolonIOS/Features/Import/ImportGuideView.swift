import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The file type of a content bundle. There is no registered UTI, so the
    /// extension is all we have; unknown types fall back to plain data.
    static let eidolonPackage = UTType(filenameExtension: "eidolonpkg") ?? .data
}

/// What the producer sees before any content bundle is installed (ADR-0003).
struct ImportGuideView: View {
    @Environment(AppModel.self) private var app
    @State private var isPicking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Text("先导入内容包")
                    .font(.title2.weight(.semibold))
                Text("在 Mac 上导出 `eidolonpkg`，用隔空投送或「文件」传到这台手机，再从下面选它。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                isPicking = true
            } label: {
                Label("选择内容包", systemImage: "folder")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isImporting)

            if let error = app.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if app.isImporting {
                ProgressView("正在导入…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.eidolonPackage, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await app.importBundle(from: url) }
        }
    }
}
