import AppKit
import SwiftUI

extension Notification.Name {
    static let sarashinaOpenDocuments = Notification.Name("jp.sarashina.ocr.openDocuments")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .sarashinaOpenDocuments, object: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        let urls = arguments
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .sarashinaOpenDocuments, object: urls)
        }
    }
}

@main
struct SarashinaOCRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        Window("Sarashina OCR", id: "main") {
            MainWindow()
                .environmentObject(app)
                .environmentObject(app.modelManager)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { app.start() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1320, height: 860)
        .commands {
            SarashinaCommands(app: app)
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(app.modelManager)
        }
    }
}

struct SarashinaCommands: Commands {
    @ObservedObject var app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("取り込み…") { app.importFromPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("クリップボードから貼付") { paste() }
                .keyboardShortcut("v", modifiers: .command)
        }

        CommandMenu("OCR") {
            Button(app.isRunning ? "停止" : "実行") {
                if app.isRunning { app.cancelOCR() } else { app.runOCR() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!app.isRunning && !app.canRunOCR)

            Button("未処理ページを連続スキャン") { app.runAllPages() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!app.canRunAllPages)

            Button("停止") { app.cancelOCR() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isRunning)

            Divider()

            Button("前のページ") { previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("次のページ") { nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Divider()

            Button("コピー") { copyMarkdown() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(app.selectedResult == nil && !app.isRunning)
            Button("全ページをコピー") { app.copyAllPages() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!(app.selectedDocument?.hasResults ?? false))
        }

        CommandGroup(after: .saveItem) {
            Button("書き出し…") {
                app.export(format: .markdown, range: .allPages)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(app.selectedDocument?.hasResults ?? false))
        }

        CommandGroup(after: .toolbar) {
            Button("拡大") { app.fontSize = min(200, app.fontSize + 10) }
                .keyboardShortcut("+", modifiers: .command)
            Button("縮小") { app.fontSize = max(80, app.fontSize - 10) }
                .keyboardShortcut("-", modifiers: .command)
            Button("実際のサイズ") { app.fontSize = 100 }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// The raw Markdown editor is a regular text view. Preserve the standard
    /// editing behavior of ⌘C/⌘V/⌘←/⌘→ when it has focus.
    private var focusedTextView: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private func paste() {
        if let textView = focusedTextView {
            textView.paste(nil)
        } else {
            app.pasteFromClipboard()
        }
    }

    private func copyMarkdown() {
        app.copyCurrentSelectionOrMarkdown()
    }

    private func previousPage() {
        if let textView = focusedTextView {
            textView.moveToBeginningOfLine(nil)
        } else {
            app.previousPage()
        }
    }

    private func nextPage() {
        if let textView = focusedTextView {
            textView.moveToEndOfLine(nil)
        } else {
            app.nextPage()
        }
    }
}
