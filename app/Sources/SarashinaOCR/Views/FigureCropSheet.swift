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
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var magnifyStartZoom: CGFloat?
    @State private var canvasSize: CGSize = .zero

    private let coordinateSpace = "figureCropCanvas"
    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 8
    private let zoomStep: CGFloat = 1.25

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
                    Text("ページ画像上で図を囲む範囲を調整します。ピンチで拡大縮小、背景のドラッグで表示位置を移動できます。OCR 結果は再実行せず、図の画像だけを更新します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    zoomControls
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(16)

            Divider()

            GeometryReader { geometry in
                let baseRect = Self.fitRect(
                    width: CGFloat(image?.size.width ?? CGFloat(page.width)),
                    height: CGFloat(image?.size.height ?? CGFloat(page.height)),
                    in: geometry.size
                )
                let imageRect = imageViewRect(baseRect: baseRect, canvasSize: geometry.size)
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

                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(panGesture(baseRect: baseRect, canvasSize: geometry.size))

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
                .clipped()
                .coordinateSpace(name: coordinateSpace)
                .simultaneousGesture(
                    magnifyGesture(baseRect: baseRect, canvasSize: geometry.size)
                )
                .onAppear {
                    canvasSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    canvasSize = newSize
                    pan = clampedPan(
                        pan,
                        baseRect: Self.fitRect(
                            width: CGFloat(image?.size.width ?? CGFloat(page.width)),
                            height: CGFloat(image?.size.height ?? CGFloat(page.height)),
                            in: newSize
                        ),
                        canvasSize: newSize,
                        zoom: zoom
                    )
                }
            }
            .frame(minHeight: 380)

            Divider()

            HStack(spacing: 10) {
                Button("ページ全体") {
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

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                zoom(by: 1 / zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(isLoading || canvasSize.width < 2 || zoom <= minZoom + 0.001)
            .help("縮小")

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)

            Button {
                zoom(by: zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(isLoading || canvasSize.width < 2 || zoom >= maxZoom - 0.001)
            .help("拡大")

            Button("選択範囲にズーム") {
                zoomToSelection()
            }
            .disabled(isLoading || canvasSize.width < 2)
            .help("図の選択範囲を画面いっぱいに表示します")

            Button {
                resetView()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .disabled(isLoading || (zoom <= minZoom + 0.001 && pan == .zero))
            .help("表示倍率と位置を戻す")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    private var currentBaseRect: CGRect {
        Self.fitRect(
            width: CGFloat(image?.size.width ?? CGFloat(page.width)),
            height: CGFloat(image?.size.height ?? CGFloat(page.height)),
            in: canvasSize
        )
    }

    private func imageViewRect(baseRect: CGRect, canvasSize: CGSize) -> CGRect {
        let width = baseRect.width * zoom
        let height = baseRect.height * zoom
        return CGRect(
            x: canvasSize.width / 2 - width / 2 + pan.width,
            y: canvasSize.height / 2 - height / 2 + pan.height,
            width: width,
            height: height
        )
    }

    private func clampedPan(
        _ candidate: CGSize,
        baseRect: CGRect,
        canvasSize: CGSize,
        zoom: CGFloat
    ) -> CGSize {
        let scaledWidth = baseRect.width * zoom
        let scaledHeight = baseRect.height * zoom
        let limitX = max(0, (scaledWidth - canvasSize.width) / 2)
        let limitY = max(0, (scaledHeight - canvasSize.height) / 2)
        return CGSize(
            width: min(max(candidate.width, -limitX), limitX),
            height: min(max(candidate.height, -limitY), limitY)
        )
    }

    private func setZoom(
        _ newZoom: CGFloat,
        around anchor: CGPoint,
        baseRect: CGRect,
        canvasSize: CGSize
    ) {
        guard canvasSize.width > 1, canvasSize.height > 1, baseRect.width > 1 else {
            return
        }
        let target = min(max(newZoom, minZoom), maxZoom)
        guard abs(target - zoom) > 0.0001 else { return }

        let oldRect = imageViewRect(baseRect: baseRect, canvasSize: canvasSize)
        let anchorX = oldRect.width > 0 ? (anchor.x - oldRect.minX) / oldRect.width : 0.5
        let anchorY = oldRect.height > 0 ? (anchor.y - oldRect.minY) / oldRect.height : 0.5
        zoom = target

        let newWidth = baseRect.width * target
        let newHeight = baseRect.height * target
        let newOriginX = anchor.x - anchorX * newWidth
        let newOriginY = anchor.y - anchorY * newHeight
        let newPan = CGSize(
            width: newOriginX - (canvasSize.width / 2 - newWidth / 2),
            height: newOriginY - (canvasSize.height / 2 - newHeight / 2)
        )
        pan = clampedPan(
            newPan,
            baseRect: baseRect,
            canvasSize: canvasSize,
            zoom: target
        )
    }

    private func zoom(by factor: CGFloat) {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        let baseRect = currentBaseRect
        let imageRect = imageViewRect(baseRect: baseRect, canvasSize: canvasSize)
        let selection = selectionRect(in: imageRect)
        let anchor = CGPoint(
            x: min(max(selection.midX, 0), canvasSize.width),
            y: min(max(selection.midY, 0), canvasSize.height)
        )
        setZoom(
            zoom * factor,
            around: anchor,
            baseRect: baseRect,
            canvasSize: canvasSize
        )
    }

    private func zoomToSelection() {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        let baseRect = currentBaseRect
        let imageRect = imageViewRect(baseRect: baseRect, canvasSize: canvasSize)
        let selection = selectionRect(in: imageRect)
        guard selection.width > 0, selection.height > 0 else { return }

        let fit = min(
            canvasSize.width / selection.width,
            canvasSize.height / selection.height
        ) * 0.82
        let target = min(max(fit, minZoom), maxZoom)
        zoom = target

        let scaledWidth = baseRect.width * target
        let scaledHeight = baseRect.height * target
        let newOriginX = canvasSize.width / 2 - rect.midX * scaledWidth
        let newOriginY = canvasSize.height / 2 - rect.midY * scaledHeight
        let newPan = CGSize(
            width: newOriginX - (canvasSize.width / 2 - scaledWidth / 2),
            height: newOriginY - (canvasSize.height / 2 - scaledHeight / 2)
        )
        pan = clampedPan(
            newPan,
            baseRect: baseRect,
            canvasSize: canvasSize,
            zoom: target
        )
    }

    private func resetView() {
        zoom = minZoom
        pan = .zero
        panStart = nil
        magnifyStartZoom = nil
    }

    private func panGesture(baseRect: CGRect, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard zoom > minZoom + 0.001 else { return }
                if panStart == nil {
                    panStart = pan
                }
                guard let start = panStart else { return }
                pan = clampedPan(
                    CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ),
                    baseRect: baseRect,
                    canvasSize: canvasSize,
                    zoom: zoom
                )
            }
            .onEnded { _ in
                panStart = nil
            }
    }

    private func magnifyGesture(baseRect: CGRect, canvasSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard canvasSize.width > 1, canvasSize.height > 1 else { return }
                if magnifyStartZoom == nil {
                    magnifyStartZoom = zoom
                }
                let start = magnifyStartZoom ?? zoom
                let target = min(max(start * value.magnification, minZoom), maxZoom)
                setZoom(
                    target,
                    around: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                    baseRect: baseRect,
                    canvasSize: canvasSize
                )
            }
            .onEnded { _ in
                magnifyStartZoom = nil
            }
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
