import AppKit
import SwiftUI

/// Manual four-corner adjustment for document perspective correction (FR-04).
struct CropSheet: View {
    let page: PageRecord
    let initialQuad: [CGPoint]?
    let loadSource: () async throws -> URL
    let onApply: ([CGPoint]) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var points: [CGPoint] = []
    @State private var image: NSImage?
    @State private var sourceURL: URL?
    @State private var isLoading = true
    @State private var isDetecting = false
    @State private var confirmReset = false
    @State private var message: String?

    init(
        page: PageRecord,
        initialQuad: [CGPoint]?,
        loadSource: @escaping () async throws -> URL,
        onApply: @escaping ([CGPoint]) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.page = page
        self.initialQuad = initialQuad
        self.loadSource = loadSource
        self.onApply = onApply
        self.onReset = onReset
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("切り取り範囲を編集")
                        .font(.title3.bold())
                    Text("元の画像から残す範囲の4隅を指定します。適用すると、このページの OCR 結果は破棄されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading || isDetecting {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            GeometryReader { geometry in
                let rect = Self.fitRect(
                    width: CGFloat(image?.size.width ?? CGFloat(page.width)),
                    height: CGFloat(image?.size.height ?? CGFloat(page.height)),
                    in: geometry.size
                )
                ZStack {
                    Color.black.opacity(0.92)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    } else {
                        ProgressView().tint(.white)
                    }

                    Canvas { context, _ in
                        guard points.count == 4, rect.width > 1, rect.height > 1 else { return }
                        var path = Path()
                        let mapped = points.map { point in
                            CGPoint(
                                x: rect.minX + point.x * rect.width,
                                y: rect.minY + point.y * rect.height
                            )
                        }
                        path.addLines(mapped)
                        path.closeSubpath()
                        context.fill(path, with: .color(.orange.opacity(0.13)))
                        context.stroke(path, with: .color(.orange), lineWidth: 2)
                        for (index, point) in mapped.enumerated() {
                            let circle = CGRect(
                                x: point.x - 11, y: point.y - 11, width: 22, height: 22
                            )
                            context.fill(Path(ellipseIn: circle), with: .color(.orange))
                            context.stroke(
                                Path(ellipseIn: circle),
                                with: .color(.white),
                                lineWidth: 2
                            )
                            context.draw(
                                Text("\(index + 1)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white),
                                at: point
                            )
                        }
                    }
                    .allowsHitTesting(false)

                    if points.count == 4 {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                                .position(
                                    x: rect.minX + point.x * rect.width,
                                    y: rect.minY + point.y * rect.height
                                )
                                .gesture(
                                    DragGesture(
                                        minimumDistance: 0,
                                        coordinateSpace: .named("cropCanvas")
                                    )
                                    .onChanged { value in
                                        guard rect.width > 1, rect.height > 1 else { return }
                                        let x = min(max((value.location.x - rect.minX) / rect.width, 0), 1)
                                        let y = min(max((value.location.y - rect.minY) / rect.height, 0), 1)
                                        points[index] = CGPoint(x: x, y: y)
                                    }
                                )
                        }
                    }
                }
                .coordinateSpace(name: "cropCanvas")
            }
            .frame(minHeight: 380)

            Divider()

            HStack(spacing: 10) {
                Button("自動検出") { detect() }
                    .disabled(isLoading || isDetecting || sourceURL == nil)
                Button("全体に戻す") {
                    confirmReset = true
                }
                .disabled(isLoading)
                .help("現在の切り取りを解除して、元の全体画像に戻します")
                Button("全画面") {
                    points = Self.fullQuad
                    message = nil
                }
                .disabled(isLoading)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("適用") {
                    onApply(points)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 720)
        .task { await load() }
        .confirmationDialog(
            "切り取りを全体に戻しますか？",
            isPresented: $confirmReset
        ) {
            Button("全体に戻す", role: .destructive) {
                onReset()
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このページの OCR 結果と図は破棄されます。")
        }
    }

    private var isValid: Bool {
        guard image != nil, !isLoading, points.count == 4 else { return false }
        var area: CGFloat = 0
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) / 2 > 0.02
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await loadSource()
            sourceURL = url
            guard let loaded = NSImage(contentsOf: url) else {
                points = Self.fullQuad
                message = "元画像を読み込めませんでした。"
                return
            }
            image = loaded
            if let initialQuad, initialQuad.count == 4 {
                points = initialQuad
            } else {
                points = Self.fullQuad
            }
        } catch {
            points = Self.fullQuad
            message = error.localizedDescription
        }
    }

    private func detect() {
        guard !isDetecting, let sourceURL else { return }
        isDetecting = true
        message = nil
        Task {
            let quad = await Task.detached(priority: .userInitiated) {
                PreprocessService.documentQuad(in: sourceURL)
            }.value
            await MainActor.run {
                isDetecting = false
                if let quad {
                    points = quad
                } else {
                    message = "輪郭を検出できませんでした。手動で調整してください。"
                }
            }
        }
    }

    private static let fullQuad: [CGPoint] = [
        CGPoint(x: 0.01, y: 0.01),
        CGPoint(x: 0.99, y: 0.01),
        CGPoint(x: 0.99, y: 0.99),
        CGPoint(x: 0.01, y: 0.99)
    ]

    private static func fitRect(width: CGFloat, height: CGFloat, in size: CGSize) -> CGRect {
        guard width > 0, height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let inset: CGFloat = 12
        let available = CGSize(
            width: max(1, size.width - inset * 2),
            height: max(1, size.height - inset * 2)
        )
        let aspect = width / height
        let viewAspect = available.width / available.height
        let rect: CGRect
        if aspect > viewAspect {
            let w = available.width
            rect = CGRect(
                x: inset,
                y: inset + (available.height - w / aspect) / 2,
                width: w,
                height: w / aspect
            )
        } else {
            let h = available.height
            rect = CGRect(
                x: inset + (available.width - h * aspect) / 2,
                y: inset,
                width: h * aspect,
                height: h
            )
        }
        return rect
    }
}
