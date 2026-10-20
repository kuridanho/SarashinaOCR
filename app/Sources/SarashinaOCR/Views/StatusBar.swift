import SwiftUI

struct StatusBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var model: ModelManager

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engineColor)
                .frame(width: 8, height: 8)
            Text("MLX 4bit")
                .font(.caption2.weight(.medium))

            Divider().frame(height: 11)

            Label(model.status.label, systemImage: "cpu")
                .font(.caption2)
                .lineLimit(1)
                .help(model.modelDirectory?.path ?? "モデルが未導入です")

            if let total = model.manifest?.totalBytes, total > 0, model.status.isReady {
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 11)

            if app.isRunning || app.statusTokPerSec > 0 {
                Text(String(format: "%.1f tok/s", app.statusTokPerSec))
                    .font(.caption2.monospacedDigit())
                Text("\(app.statusTokens) tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if app.isBatchRunning {
                Text("連続 \(app.batchCurrent)/\(app.batchTotal)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("画像は送信されません")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("処理はすべてこの Mac 上で完結します。外部への送信は行いません。")

            Spacer(minLength: 8)

            Text(app.statusMessage)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var engineColor: Color {
        switch app.engine.state {
        case .running:
            if app.isRunning { return .orange }
            return app.engineReady ? .green : .blue
        case .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }
}
