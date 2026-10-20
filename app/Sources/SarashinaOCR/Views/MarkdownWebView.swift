import AppKit
import SwiftUI
import WebKit

enum WebResources {
    static var rootURL: URL? {
        Bundle.module.url(forResource: "Resources", withExtension: nil)?
            .appendingPathComponent("web", isDirectory: true)
    }

    static var indexURL: URL? {
        rootURL?.appendingPathComponent("index.html")
    }
}

/// WKWebView-backed Markdown renderer with bundled markdown-it + KaTeX.
struct MarkdownWebView: NSViewRepresentable {
    var markdown: String
    var baseDirectory: URL?
    var zoom: Double = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.webView = webView
#if DEBUG
        if ProcessInfo.processInfo.environment["SARASHINA_DEV_LOG"] == "1" {
            let index = WebResources.indexURL?.path ?? "nil"
            let root = WebResources.rootURL?.path ?? "nil"
            FileHandle.standardError.write(Data("[web] index=\(index) root=\(root)\n".utf8))
        }
#endif
        if let index = WebResources.indexURL, let root = WebResources.rootURL {
            webView.loadFileURL(index, allowingReadAccessTo: root)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let inlined = AssetInliner.inline(markdown: markdown, baseDirectory: baseDirectory)
        context.coordinator.update(markdown: inlined, zoom: zoom)
        if !context.coordinator.didLogLayout {
            context.coordinator.didLogLayout = true
#if DEBUG
            if ProcessInfo.processInfo.environment["SARASHINA_DEV_LOG"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    FileHandle.standardError.write(Data(
                        "[web] frame=\(webView.frame) hidden=\(webView.isHidden) window=\(webView.window != nil) superview=\(String(describing: webView.superview?.frame))\n".utf8
                    ))
                }
            }
#endif
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: WKWebView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var didLogLayout = false
        private var isLoaded = false
        private var pendingMarkdown = ""
        private var renderedMarkdown = ""
        private var pendingZoom: Double = 1.0
        private var lastZoom: Double = 1.0

        func update(markdown: String, zoom: Double) {
            pendingMarkdown = markdown
            pendingZoom = zoom
            guard isLoaded else { return }
            if markdown != renderedMarkdown {
                renderedMarkdown = markdown
                let literal = (try? JSONEncoder().encode(markdown))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
                webView?.evaluateJavaScript("window.renderMarkdown(\(literal));")
            }
            if abs(zoom - lastZoom) > 0.001 {
                lastZoom = zoom
                webView?.evaluateJavaScript("window.setZoom(\(zoom * 100));")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
#if DEBUG
            if ProcessInfo.processInfo.environment["SARASHINA_DEV_LOG"] == "1" {
                FileHandle.standardError.write(Data("[web] didFinish\n".utf8))
            }
#endif
            let literal = (try? JSONEncoder().encode(pendingMarkdown))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.evaluateJavaScript("window.renderMarkdown(\(literal));")
            webView.evaluateJavaScript("window.setZoom(\(pendingZoom * 100));")
#if DEBUG
            if ProcessInfo.processInfo.environment["SARASHINA_DEV_LOG"] == "1" {
                FileHandle.standardError.write(Data(
                    "[web] pending=\(pendingMarkdown.count) chars\n".utf8
                ))
                webView.evaluateJavaScript("document.body.innerText") { value, error in
                    let text = (value as? String) ?? "nil"
                    FileHandle.standardError.write(Data(
                        "[web] body=\(text.prefix(120)) error=\(String(describing: error))\n".utf8
                    ))
                }
            }
#endif
            renderedMarkdown = pendingMarkdown
            lastZoom = pendingZoom
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
#if DEBUG
            FileHandle.standardError.write(Data("[web] didFail: \(error)\n".utf8))
#endif
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
#if DEBUG
            FileHandle.standardError.write(Data("[web] didFailProvisional: \(error)\n".utf8))
#endif
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Converts relative `assets/...` image links to data URLs so the preview does
/// not depend on WKWebView's local file access rules.
enum AssetInliner {
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#
    )

    static func inline(markdown: String, baseDirectory: URL?) -> String {
        guard let baseDirectory else { return markdown }
        let source = markdown as NSString
        let matches = imagePattern.matches(
            in: markdown, range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return markdown }
        var output = markdown
        for match in matches.reversed() {
            let path = source.substring(with: match.range(at: 2))
            if path.hasPrefix("data:") || path.hasPrefix("http://") || path.hasPrefix("https://") {
                continue
            }
            let fileURL = baseDirectory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let mime = mimeType(for: fileURL.pathExtension)
            let replacement = "data:\(mime);base64,\(data.base64EncodedString())"
            if let range = Range(match.range(at: 2), in: output) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}
