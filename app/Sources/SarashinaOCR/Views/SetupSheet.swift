import AppKit
import SwiftUI

struct SetupSheet: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var model: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sarashina OCR へようこそ")
                        .font(.title2.bold())
                    Text("日本語の文書を、この Mac だけで読み取ります。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if model.status.isReady {
                readyView
            } else {
                setupView
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                Link(
                    "モデルカード",
                    destination: URL(string: "https://huggingface.co/tokimoa/sarashina2.2-ocr-mlx-4bit")!
                )
                .font(.caption)
                Link(
                    "ライセンス (MIT)",
                    destination: URL(string: "https://huggingface.co/tokimoa/sarashina2.2-ocr-mlx-4bit")!
                )
                .font(.caption)
                Spacer()
                Button("閉じる") { app.showSetup = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 540)
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("モデルの準備ができました", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let directory = model.modelDirectory {
                Text(directory.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("オフラインのまま OCR を実行できます。画像や結果が外部へ送信されることはありません。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("モデルを検証") {
                    Task { await model.verifyInstalledModel() }
                }
                Button("使い始める") { app.showSetup = false }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("初回のみ、モデル（約 2.98 GB）をダウンロードします。")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Label("MLX 4bit 版を利用（Apple Silicon 専用）", systemImage: "bolt.fill")
                Label("ダウンロードは再開できます。SHA-256 で破損を検証します", systemImage: "checkmark.shield")
                Label("導入後の OCR は完全にオフラインで動作します", systemImage: "wifi.slash")
                Label("すでにモデルがある場合はフォルダからインポートできます", systemImage: "folder")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            statusArea

            HStack(spacing: 10) {
                switch model.status {
                case .downloading:
                    Button("一時停止") { model.pauseDownload() }
                    Button("中止") { model.cancelDownload() }
                        .foregroundStyle(.red)
                case .paused:
                    Button("再開") { model.resumeDownload() }
                        .buttonStyle(.borderedProminent)
                    Button("中止") { model.cancelDownload() }
                        .foregroundStyle(.red)
                case .verifying:
                    ProgressView().controlSize(.small)
                    Text("検証中…").font(.callout).foregroundStyle(.secondary)
                default:
                    Button("ダウンロードを開始") { model.startDownload() }
                        .buttonStyle(.borderedProminent)
                }

                Button("フォルダからインポート…") { importFolder() }
                    .disabled(model.status == .downloading || model.status == .verifying)
                Spacer()
            }

            Text("保存先: \(model.modelsRoot.path)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch model.status {
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.progress)
                Text(model.progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.progress)
                Text("一時停止中 ・ \(model.progressText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            ProgressView()
                .progressViewStyle(.linear)
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .missing, .unknown:
            EmptyView()
        case .ready:
            EmptyView()
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "モデルフォルダを選択"
        panel.message = "config.json と model.safetensors を含むフォルダを選択してください"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importModel(from: url) }
        }
    }
}
