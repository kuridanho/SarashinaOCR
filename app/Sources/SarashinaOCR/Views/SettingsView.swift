import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var model: ModelManager
    @State private var showDeleteConfirmation = false

    var body: some View {
        TabView {
            general.tabItem { Label("一般", systemImage: "gearshape") }
            inference.tabItem { Label("推論", systemImage: "cpu") }
            modelTab.tabItem { Label("モデル", systemImage: "shippingbox") }
            about.tabItem { Label("情報", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(width: 620, height: 500)
        .alert("モデルを削除しますか？", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) {
                Task {
                    await app.unloadModel()
                    model.deleteModel()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("約 2.98 GB のモデルファイルを削除します。再度利用するにはダウンロードが必要です。")
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("起動と常駐") {
                Toggle("起動時にモデルを読み込む", isOn: $app.autoLoadModel)
                Picker("アイドル時にアンロード", selection: $app.idleUnloadMinutes) {
                    Text("しない").tag(0)
                    Text("5 分").tag(5)
                    Text("10 分").tag(10)
                    Text("30 分").tag(30)
                    Text("60 分").tag(60)
                }
                Text("モデルをアンロードするとメモリを解放します。次回の実行時に再読み込みします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("取り込み") {
                Toggle("書類の自動検出と台形補正", isOn: $app.applyDocumentDetection)
                Text("写真から書類領域を検出し、まっすぐに補正します。次回の取り込みから適用されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("表示") {
                HStack {
                    Text("プレビューの文字サイズ")
                    Slider(value: $app.fontSize, in: 80...200, step: 10)
                    Text("\(Int(app.fontSize))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Toggle("全ページ書き出しにページ見出しを含める", isOn: $app.includePageHeadings)
            }

            Section("保存場所") {
                HStack {
                    Text(AppPaths.appSupport.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Finder で表示") {
                        NSWorkspace.shared.open(AppPaths.appSupport)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Inference

    private var inference: some View {
        Form {
            Section("解像度プリセット") {
                Picker("プリセット", selection: $app.preset) {
                    ForEach(OCRPreset.allCases) { preset in
                        Text("\(preset.title)（\(preset.maxPixels / 10_000) 万 px）").tag(preset)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(presetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("生成") {
                Stepper(value: $app.maxNewTokens, in: 1000...8192, step: 500) {
                    HStack {
                        Text("最大出力トークン数")
                        Spacer()
                        Text("\(app.maxNewTokens)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("長い表や数式が多いページでは多めに設定してください。上限に達すると末尾に警告が付きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("品質とメモリ") {
                LabeledContent("推論バックエンド", value: "MLX 4bit")
                LabeledContent("想定ピークメモリ", value: "約 4.7 GB")
                LabeledContent("推奨メモリ", value: "16 GB 以上")
                Text("メモリ不足（E3001）が発生した場合、モデルを解放して標準プリセットで一度だけ自動再試行します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var presetDescription: String {
        switch app.preset {
        case .high:
            return "小さい文字や細かい表向け。A4 で最大約 3,136 visual tokens。処理時間は約 90 秒の目安です。"
        case .standard:
            return "速度と精度のバランス。多くの文書はこの設定で十分です。約 55 秒の目安です。"
        case .fast:
            return "下書きやスクリーンショット向け。約 30 秒の目安です。"
        }
    }

    // MARK: - Model

    private var modelTab: some View {
        Form {
            Section("インストール状態") {
                LabeledContent("状態") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.status.isReady ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.status.label)
                    }
                }
                if let directory = model.modelDirectory {
                    LabeledContent("場所") {
                        Text(directory.path)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if model.status.isReady && !model.isManagedModel {
                    Text("リポジトリ内の開発用モデルを使用しています。アプリからの削除は無効です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let revision = model.manifest?.revision {
                    LabeledContent("リビジョン") {
                        Text(String(revision.prefix(12)))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("サイズ") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: model.manifest?.totalBytes ?? 0,
                        countStyle: .file
                    ))
                }
            }

            Section("操作") {
                HStack(spacing: 12) {
                    if model.status.isReady {
                        Button("検証") {
                            Task { await model.verifyInstalledModel() }
                        }
                        Button("フォルダから再インポート…") { importFolder() }
                        Button("削除", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .disabled(!model.isManagedModel)
                        .help(model.isManagedModel
                              ? "アプリが管理するモデルを削除します"
                              : "リポジトリ内の開発用モデルは Finder から削除してください")
                    } else {
                        Button("ダウンロードを開始") { model.startDownload() }
                            .buttonStyle(.borderedProminent)
                        Button("フォルダからインポート…") { importFolder() }
                        Button("セットアップ画面を開く") { app.openSetup() }
                    }
                }
                .disabled(app.isRunning)

                if model.status == .downloading || model.status == .verifying {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: model.progress)
                        Text(model.progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if case .failed(let message) = model.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("ライセンス") {
                Text("モデル: Sarashina2.2-OCR（SB Intuitions） / MLX 4bit 変換: tokimoa / MIT License")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "モデルフォルダを選択"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await app.unloadModel()
                await model.importModel(from: url)
            }
        }
    }

    // MARK: - About

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "viewfinder.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sarashina OCR")
                            .font(.title2.bold())
                        Text("バージョン \(appVersion)（\(buildNumber)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("プライバシー") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("画像・PDF・OCR 結果は外部へ送信されません", systemImage: "lock.shield")
                        Label("モデルの初回ダウンロード時のみネットワークを使用します", systemImage: "network")
                        Label("処理はすべてこの Mac 上で完結します", systemImage: "desktopcomputer")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("クレジット") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sarashina2.2-OCR（SB Intuitions、MIT License）を MLX 4bit に変換したモデルを利用しています。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("モデルカード（tokimoa/sarashina2.2-ocr-mlx-4bit）",
                             destination: URL(string: "https://huggingface.co/tokimoa/sarashina2.2-ocr-mlx-4bit")!)
                            .font(.callout)
                        Link("Sarashina2.2-OCR（sbintuitions）",
                             destination: URL(string: "https://huggingface.co/sbintuitions/sarashina2.2-ocr")!)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("技術情報") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("描画: markdown-it + KaTeX + DOMPurify（同梱）")
                        Text("推論: Python 3.12 / MLX / mlx-vlm 0.6.6")
                        Text("モデル: \(model.manifest?.revision ?? "未導入")")
                    }
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
                }

                HStack {
                    Button("診断情報をコピー") { copyDiagnostics() }
                    Spacer()
                }
            }
            .padding(8)
        }
    }

    private func copyDiagnostics() {
        let version = appVersion
        let build = buildNumber
        let engine: String
        switch app.engine.state {
        case .running: engine = "running"
        case .starting: engine = "starting"
        case .stopped: engine = "stopped"
        case .failed(let message): engine = "failed: \(message)"
        }
        let text = """
        Sarashina OCR \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Engine: \(engine)
        Model: \(model.modelDirectory?.path ?? "missing")
        Revision: \(model.manifest?.revision ?? "unknown")
        Last log: \(app.engine.lastLogLine)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        app.statusMessage = "診断情報をコピーしました"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
}
