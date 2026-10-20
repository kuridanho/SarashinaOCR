import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var model: ModelManager
    @State private var isDropTarget = false

    var body: some View {
        NavigationSplitView {
            LibraryPane()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } content: {
            PreviewPane()
                .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        } detail: {
            ResultPane()
                .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 42))
                            Text("画像または PDF をドロップ").font(.title3)
                        }
                        .foregroundStyle(Color.accentColor)
                    )
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.importFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .sheet(isPresented: $app.showSetup) {
            SetupSheet()
                .environmentObject(app)
                .environmentObject(model)
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { app.lastError != nil },
                set: { if !$0 { app.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
        .navigationTitle(app.selectedDocument?.title ?? "Sarashina OCR")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                app.importFromPanel()
            } label: {
                Label("取り込み", systemImage: "square.and.arrow.down")
            }
            .help("画像または PDF を取り込む (⌘O)")

            Button {
                app.pasteFromClipboard()
            } label: {
                Label("貼付", systemImage: "doc.on.clipboard")
            }
            .help("クリップボードから貼り付ける (⌘V)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if app.isRunning { app.cancelOCR() } else { app.runOCR() }
            } label: {
                Label(app.isRunning ? "停止" : "実行", systemImage: app.isRunning ? "stop.fill" : "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.isRunning && !app.canRunOCR)
            .help(app.isRunning ? "OCR を停止 (⌘.)" : "OCR を実行 (⌘R)")

            Menu {
                Button("Markdown（現在のページ）") {
                    app.export(format: .markdown, range: .currentPage)
                }
                Button("Markdown（全ページ）") {
                    app.export(format: .markdown, range: .allPages)
                }
                Divider()
                Button("プレーンテキスト（全ページ）") {
                    app.export(format: .plainText, range: .allPages)
                }
                Button("構造化 JSON（全ページ）") {
                    app.export(format: .json, range: .allPages)
                }
            } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .disabled(!(app.selectedDocument?.hasResults ?? false))
            .help("書き出し (⌘E)")

            SettingsLink {
                Label("設定", systemImage: "gearshape")
            }
            .help("設定 (⌘,)")
        }
    }
}
