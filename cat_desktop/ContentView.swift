import SwiftUI
import AVFoundation

// MARK: - Main View

enum CatVideo: String, CaseIterable {
    case steal = "cat_animation"
    case pat = "cat_pat"
    case sleep = "cat_sleep"
    case snore = "cat_snore"
    case roll = "cat_roll"

    var emoji: String {
        switch self {
        case .steal: "🐟"
        case .pat:   "🐱"
        case .sleep: "😴"
        case .snore: "💤"
        case .roll:  "🙀"
        }
    }

    static var tapVideos: [CatVideo] { [.pat, .sleep] }

    static func randomTapVideo() -> CatVideo {
        tapVideos.randomElement()!
    }
}

struct ContentView: View {
    @State private var currentVideo: CatVideo?
    @State private var videoReady = false
    @State private var catImage: NSImage?
    @State private var tapDetector = TapDetector()

    var body: some View {
        ZStack {
            // Cat image / video area
            ZStack {
                if let image = catImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 400, height: 225)
                        .opacity(videoReady ? 0 : 1)
                }

                if let video = currentVideo {
                    VideoPlayerView(
                        videoName: video.rawValue,
                        onReady: { videoReady = true },
                        onFinished: {
                            currentVideo = nil
                            videoReady = false
                        }
                    )
                        .frame(width: 400, height: 225)
                        .id(video.rawValue)
                }
            }
        }
        .frame(width: 400, height: 280)
        .overlay(
            DragAndClickView(
                isPlaying: currentVideo != nil,
                onClick: { video in
                    if currentVideo == nil { playVideo(video) }
                }
            )
        )
        .background(WindowConfigurator())
        .contextMenu {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .onAppear {
            loadCatImage()
            tapDetector.onTapDetected = {
                if currentVideo == nil { playVideo(.randomTapVideo()) }
            }
            tapDetector.start()
        }
    }

    private func playVideo(_ video: CatVideo) {
        currentVideo = video
    }

    private func loadCatImage() {
        guard let url = Bundle.main.url(forResource: "cat_idle", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let processed = removeWhiteBackground(from: cgImage)
        else { return }
        catImage = NSImage(cgImage: processed, size: nsImage.size)
    }
}

// MARK: - Tap Detector (microphone amplitude, like tap_detect.sh)

class TapDetector {
    var onTapDetected: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private let threshold: Float = 0.15
    private var cooldown = false

    func start() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, !self.cooldown else { return }

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)

            var maxAmp: Float = 0
            for i in 0..<frameCount {
                let abs = Swift.abs(channelData[i])
                if abs > maxAmp { maxAmp = abs }
            }

            if maxAmp > self.threshold {
                self.cooldown = true
                DispatchQueue.main.async {
                    self.onTapDetected?()
                }
                // Cooldown to avoid repeat triggers
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    self.cooldown = false
                }
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            print("TapDetector: failed to start audio engine: \(error)")
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    deinit { stop() }
}

// MARK: - Native Drag & Click with Arc Emoji Buttons

struct DragAndClickView: NSViewRepresentable {
    let isPlaying: Bool
    let onClick: (CatVideo) -> Void

    func makeNSView(context: Context) -> _DragClickNSView {
        let view = _DragClickNSView()
        view.onVideoSelected = onClick
        view.isPlaying = isPlaying
        return view
    }

    func updateNSView(_ nsView: _DragClickNSView, context: Context) {
        nsView.onVideoSelected = onClick
        nsView.isPlaying = isPlaying
        if isPlaying {
            nsView.hideButtons()
        }
    }
}

class _EmojiButton: NSView {
    let video: CatVideo
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    init(video: CatVideo) {
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 36) }

    override func draw(_ dirtyRect: NSRect) {
        let bg = isHighlighted ? NSColor.white : NSColor.white.withAlphaComponent(0.85)
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()

        let emoji = video.emoji as NSString
        let font = NSFont.systemFont(ofSize: 18)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = emoji.size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        emoji.draw(at: point, withAttributes: attrs)
    }
}

class _DragClickNSView: NSView {
    var onVideoSelected: ((CatVideo) -> Void)?
    var isPlaying = false
    private var mouseDownLocation: NSPoint = .zero
    private let dragThreshold: CGFloat = 3.0
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var emojiButtons: [_EmojiButton] = []
    private var hoveredButton: _EmojiButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupButtons() {
        for video in CatVideo.allCases {
            let btn = _EmojiButton(video: video)
            btn.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
            btn.isHidden = true
            btn.alphaValue = 0
            addSubview(btn)
            emojiButtons.append(btn)
        }
    }

    private func layoutButtons() {
        let centerX = bounds.midX
        let topY = bounds.maxY - 30
        let arcRadius: CGFloat = 70
        let count = emojiButtons.count
        // Arc from 210° to 330° (centered at top, opening downward like a fan above)
        let startAngle = CGFloat.pi * 7 / 6   // 210°
        let endAngle = CGFloat.pi * 11 / 6    // 330°

        for (i, btn) in emojiButtons.enumerated() {
            let t = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
            let angle = startAngle + t * (endAngle - startAngle)
            let x = centerX + arcRadius * cos(angle) - 18
            let y = topY + arcRadius * sin(angle) - 18
            btn.frame = NSRect(x: x, y: y, width: 36, height: 36)
        }
    }

    func showButtons() {
        layoutButtons()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            for btn in emojiButtons {
                btn.isHidden = false
                btn.animator().alphaValue = 1
            }
        })
    }

    func hideButtons() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            for btn in emojiButtons {
                btn.animator().alphaValue = 0
            }
        }, completionHandler: {
            for btn in self.emojiButtons {
                btn.isHidden = true
            }
        })
        hoveredButton?.isHighlighted = false
        hoveredButton = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isPlaying else { return }
        isHovering = true
        showButtons()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hideButtons()
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let hit = emojiButtons.first { !$0.isHidden && $0.frame.contains(loc) }
        if hit !== hoveredButton {
            hoveredButton?.isHighlighted = false
            hoveredButton = hit
            hoveredButton?.isHighlighted = true
        }
        if hit != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func buttonAt(_ event: NSEvent) -> _EmojiButton? {
        let loc = convert(event.locationInWindow, from: nil)
        return emojiButtons.first { !$0.isHidden && $0.frame.contains(loc) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseDownLocation.x
        let dy = current.y - mouseDownLocation.y
        var origin = window.frame.origin
        origin.x += dx
        origin.y += dy
        window.setFrameOrigin(origin)
        mouseDownLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = abs(current.x - mouseDownLocation.x)
        let dy = abs(current.y - mouseDownLocation.y)
        guard dx < dragThreshold && dy < dragThreshold else { return }

        // Check if clicked on an emoji button
        if let btn = buttonAt(event), !btn.isHidden {
            onVideoSelected?(btn.video)
            return
        }

        // Default click: random video
        if !isPlaying {
            onVideoSelected?(CatVideo.allCases.randomElement()!)
        }
    }
}

// MARK: - Window Configurator

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask = [.borderless]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.hasShadow = false
            window.isMovableByWindowBackground = false

            if let screen = window.screen {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - 200
                let y = screenFrame.minY
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Video Player (ProRes 4444 with native alpha)

class PlayerContainerView: NSView {
    var playerLayer: AVPlayerLayer?

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct VideoPlayerView: NSViewRepresentable {
    let videoName: String
    let onReady: () -> Void
    let onFinished: () -> Void

    class Coordinator: NSObject {
        var endObserver: NSObjectProtocol?
        var readyObservation: NSKeyValueObservation?
        var onReady: (() -> Void)?

        deinit {
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            readyObservation?.invalidate()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.clear

        guard let url = Bundle.main.url(forResource: videoName, withExtension: "mov") else {
            return view
        }

        let player = AVPlayer(url: url)
        player.isMuted = true

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor.clear
        view.playerLayer = playerLayer
        view.layer?.addSublayer(playerLayer)

        playerLayer.opacity = 0

        let coordinator = context.coordinator
        coordinator.onReady = onReady

        coordinator.readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { layer, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 1
                CATransaction.commit()
                coordinator.onReady?()
                coordinator.onReady = nil
            }
        }

        coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            onFinished()
        }

        player.play()
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.playerLayer?.frame = nsView.bounds
    }
}

// MARK: - White Background Removal (Edge Flood Fill, for static image only)

private func isWhiteish(_ pixels: UnsafeMutablePointer<UInt8>, at index: Int) -> Bool {
    let offset = index * 4
    let r = Float(pixels[offset]) / 255.0
    let g = Float(pixels[offset + 1]) / 255.0
    let b = Float(pixels[offset + 2]) / 255.0
    let brightness = (r + g + b) / 3.0
    let saturation = max(r, max(g, b)) - min(r, min(g, b))
    return (brightness - saturation * 0.3) > 0.75
}

func removeWhiteBackground(from cgImage: CGImage) -> CGImage? {
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    let pixelCount = width * height

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: pixelCount * bytesPerPixel)

    var isBackground = [Bool](repeating: false, count: pixelCount)
    var queue = [Int]()
    queue.reserveCapacity(pixelCount / 2)

    for x in 0..<width {
        let top = x
        let bottom = (height - 1) * width + x
        if isWhiteish(pixels, at: top) { isBackground[top] = true; queue.append(top) }
        if isWhiteish(pixels, at: bottom) { isBackground[bottom] = true; queue.append(bottom) }
    }
    for y in 1..<(height - 1) {
        let left = y * width
        let right = y * width + (width - 1)
        if isWhiteish(pixels, at: left) { isBackground[left] = true; queue.append(left) }
        if isWhiteish(pixels, at: right) { isBackground[right] = true; queue.append(right) }
    }

    var head = 0
    while head < queue.count {
        let idx = queue[head]
        head += 1
        let x = idx % width
        let y = idx / width

        let neighbors = [(x-1, y), (x+1, y), (x, y-1), (x, y+1)]
        for (nx, ny) in neighbors {
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let nIdx = ny * width + nx
            if !isBackground[nIdx] && isWhiteish(pixels, at: nIdx) {
                isBackground[nIdx] = true
                queue.append(nIdx)
            }
        }
    }

    for i in 0..<pixelCount {
        guard isBackground[i] else { continue }
        let offset = i * bytesPerPixel
        let r = Float(pixels[offset]) / 255.0
        let g = Float(pixels[offset + 1]) / 255.0
        let b = Float(pixels[offset + 2]) / 255.0
        let brightness = (r + g + b) / 3.0
        let saturation = max(r, max(g, b)) - min(r, min(g, b))
        let whiteness = brightness - saturation * 0.3

        let alpha = max(0.0, min(1.0, (0.95 - whiteness) / 0.20))
        let a8 = UInt8(alpha * 255)
        pixels[offset]     = UInt8(min(r * alpha * 255, 255))
        pixels[offset + 1] = UInt8(min(g * alpha * 255, 255))
        pixels[offset + 2] = UInt8(min(b * alpha * 255, 255))
        pixels[offset + 3] = a8
    }

    return context.makeImage()
}
