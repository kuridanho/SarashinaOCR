import AppKit
import SwiftUI

/// Rectangular crop editor for an extracted figure. The crop is taken from
/// the processed page image, so OCR does not need to run again.
struct FigureCropSheet: View {
    let page: PageRecord
    let figure: FigureInfo
    let onApply: ([Double]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rect: CGRect
    @State private var initialRect: CGRect
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var message: String?
    @State private var dragStartRect: CGRect?
    @State private var dragStartPoint: CGPoint?

    private let coordinateSpace = "figureCropCanvas"

    init(page: PageRecord, figure: FigureInfo, onApply: @escaping ([Double]) -> Void) {
        self.page = page
        self.figure = figure
        self.onApply = onApply
        let initial = Self.normalizedRect(from: figure.bbox)
        _rect = State(initialValue: initial)
        _initialRect = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("図\(figure.index)の切り取り範囲を修正")
                        .font(.title3.bold())
                    Text("ページ画像上で図を囲む範囲を調整します。OCR 結果は再実行せず、図の画像だけを更新します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            GeometryReader { geometry in
                let imageRect = Self.fitRect(
                    width: CGFloat(image?.size.width ?? CGFloat(page.width)),
                    height: CGFloat(image?.size.height ?? CGFloat(page.height)),
                    in: geometry.size
                )
                let selection = selectionRect(in: imageRect)
                ZStack {
                    Color.black.opacity(0.92)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    } else {
                        ProgressView().tint(.white)
                    }

                    Canvas { context, size in
                        guard imageRect.width > 1, imageRect.height > 1 else { return }
                        var mask = Path(CGRect(origin: .zero, size: size))
                        mask.addRect(selection)
                        context.fill(
                            mask,
                            with: .color(.black.opacity(0.55)),
                            style: FillStyle(eoFill: true)
                        )
                    }
                    .allowsHitTesting(false)

                    if image != nil, selection.width > 0, selection.height > 0 {
                        Rectangle()
                            .fill(Color.orange.opacity(0.12))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.orange, lineWidth: 2)
                            )
                            .frame(width: selection.width, height: selection.height)
                            .contentShape(Rectangle())
                            .position(x: selection.midX, y: selection.midY)
                            .gesture(moveGesture(imageRect: imageRect))

                        ForEach(Handle.allCases, id: \.self) { handle in
                            let point = handlePoint(handle, in: selection)
                            Circle()
                                .fill(Color.orange)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                )
                                .frame(width: 14, height: 14)
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                                .position(point)
                                .gesture(resizeGesture(handle, imageRect: imageRect))
                        }
                    }
                }
                .coordinateSpace(name: coordinateSpace)
            }
            .frame(minHeight: 380)

            Divider()

            HStack(spacing: 10) {
                Button("全体") {
                    rect = CGRect(x: 0.01, y: 0.01, width: 0.98, height: 0.98)
                    message = nil
                }
                .disabled(isLoading)
                .help("ページ全体を図の範囲にします")

                Button("初期値") {
                    rect = initialRect
                    message = nil
                }
                .disabled(isLoading)
                .help("OCR が検出した元の範囲に戻します")

                Text("幅 \(Int((rect.width * 100).rounded()))% ・ 高さ \(Int((rect.height * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

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
                    onApply([
                        Double(rect.minX) * 1000,
                        Double(rect.minY) * 1000,
                        Double(rect.maxX) * 1000,
                        Double(rect.maxY) * 1000
                    ])
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 840, height: 720)
        .task { loadImage() }
    }

    private var isValid: Bool {
        image != nil && !isLoading && rect.width >= 0.01 && rect.height >= 0.01
    }

    private func loadImage() {
        isLoading = true
        defer { isLoading = false }
        guard let loaded = NSImage(contentsOfFile: page.displayPath) else {
            message = "ページ画像を読み込めませんでした。"
            return
        }
        image = loaded
    }

    private func selectionRect(in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private func handlePoint(_ handle: Handle, in selection: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: selection.minX, y: selection.minY)
        case .topRight:
            return CGPoint(x: selection.maxX, y: selection.minY)
        case .bottomLeft:
            return CGPoint(x: selection.minX, y: selection.maxY)
        case .bottomRight:
            return CGPoint(x: selection.maxX, y: selection.maxY)
        }
    }

    private func moveGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard imageRect.width > 1, imageRect.height > 1 else { return }
                if dragStartRect == nil {
                    dragStartRect = rect
                    dragStartPoint = value.startLocation
                }
                guard let start = dragStartRect, let startPoint = dragStartPoint else { return }
                let dx = (value.location.x - startPoint.x) / imageRect.width
                let dy = (value.location.y - startPoint.y) / imageRect.height
                let width = min(max(start.width, 0.01), 1)
                let height = min(max(start.height, 0.01), 1)
                rect = CGRect(
                    x: min(max(start.minX + dx, 0), 1 - width),
                    y: min(max(start.minY + dy, 0), 1 - height),
                    width: width,
                    height: height
                )
            }
            .onEnded { _ in
                dragStartRect = nil
                dragStartPoint = nil
            }
    }

    private func resizeGesture(_ handle: Handle, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard imageRect.width > 1, imageRect.height > 1 else { return }
                if dragStartRect == nil {
                    dragStartRect = rect
                }
                guard let start = dragStartRect else { return }
                let x = min(max((value.location.x - imageRect.minX) / imageRect.width, 0), 1)
                let y = min(max((value.location.y - imageRect.minY) / imageRect.height, 0), 1)
                rect = resized(start, handle: handle, x: x, y: y)
            }
            .onEnded { _ in
                dragStartRect = nil
                dragStartPoint = nil
            }
    }

    private func resized(_ start: CGRect, handle: Handle, x: CGFloat, y: CGFloat) -> CGRect {
        let minimum: CGFloat = 0.01
        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY

        switch handle {
        case .topLeft:
            minX = min(x, maxX - minimum)
            minY = min(y, maxY - minimum)
        case .topRight:
            maxX = max(x, minX + minimum)
            minY = min(y, maxY - minimum)
        case .bottomLeft:
            minX = min(x, maxX - minimum)
            maxY = max(y, minY + minimum)
        case .bottomRight:
            maxX = max(x, minX + minimum)
            maxY = max(y, minY + minimum)
        }

        minX = min(max(minX, 0), 1)
        minY = min(max(minY, 0), 1)
        maxX = min(max(maxX, 0), 1)
        maxY = min(max(maxY, 0), 1)
        return CGRect(
            x: minX,
            y: minY,
            width: max(minimum, maxX - minX),
            height: max(minimum, maxY - minY)
        )
    }

    private static func normalizedRect(from bbox: [Double]) -> CGRect {
        guard bbox.count == 4 else {
            return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        }
        let x1 = min(max(bbox[0], 0), 1000) / 1000
        let y1 = min(max(bbox[1], 0), 1000) / 1000
        let x2 = min(max(bbox[2], 0), 1000) / 1000
        let y2 = min(max(bbox[3], 0), 1000) / 1000
        guard x2 > x1, y2 > y1 else {
            return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

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
        if aspect > viewAspect {
            let w = available.width
            return CGRect(
                x: inset,
                y: inset + (available.height - w / aspect) / 2,
                width: w,
                height: w / aspect
            )
        } else {
            let h = available.height
            return CGRect(
                x: inset + (available.width - h * aspect) / 2,
                y: inset,
                width: h * aspect,
                height: h
            )
        }
    }

    private enum Handle: CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
}
