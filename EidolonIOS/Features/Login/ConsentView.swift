import SwiftUI

struct ConsentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("同意隐私政策和使用条款")
                .font(.title3.bold())

            Text("这是自用实验客户端。继续之前，需要像网页版一样同意条款并声明年满 13 岁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await app.agree() }
            } label: {
                if app.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("同意并继续")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.isBusy)

            if let error = app.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(24)
    }
}
