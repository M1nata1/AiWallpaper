import AppKit
import AVFoundation
import QuartzCore
import WallpaperCore

/// A borderless window at the desktop level: above the regular macOS wallpaper, below the
/// desktop icons and every app window, present on all Spaces and invisible to the mouse.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        isRestorable = false
        isMovable = false
        animationBehavior = .none
        // Hiding the app (⌘H) must not take the wallpaper away.
        canHide = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws one wallpaper: an AVPlayerLayer for video, a plain layer for still pictures.
final class WallpaperView: NSView {
    private let playerLayer = AVPlayerLayer()
    private let imageLayer = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var looperStatus: NSKeyValueObservation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
        for sublayer in [imageLayer, playerLayer] {
            sublayer.isHidden = true
            sublayer.frame = bounds
            root.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Content

    func showVideo(at url: URL) {
        clear()
        let player = AVQueuePlayer()
        player.isMuted = true
        // A wallpaper must never keep the display awake or show up as an AirPlay source.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        looperStatus = looper.observe(\.status) { looper, _ in
            if looper.status == .failed {
                let reason = looper.error?.localizedDescription ?? "unknown error"
                Log.playback.error("Cannot play \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            }
        }
        self.looper = looper
        self.player = player
        playerLayer.player = player
        playerLayer.isHidden = false
    }

    func showImage(at url: URL) {
        clear()
        let scale = window?.backingScaleFactor ?? 2
        let longestSide = max(bounds.width, bounds.height) * scale
        // Decoding at screen resolution keeps memory low for huge photos.
        imageLayer.contents = Thumbnailer.image(at: url, maxPixelSize: Int(longestSide.rounded(.up)))
        imageLayer.isHidden = false
    }

    func clear() {
        looperStatus = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        playerLayer.player = nil
        playerLayer.isHidden = true
        imageLayer.contents = nil
        imageLayer.isHidden = true
    }

    // MARK: - Playback settings

    func setPlaying(_ playing: Bool, rate: Float) {
        guard let player else { return }
        if playing {
            if player.rate != rate {
                player.rate = rate
            }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func setAudio(muted: Bool, volume: Float) {
        player?.isMuted = muted
        player?.volume = volume
    }

    func setScaling(_ mode: ScalingMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
            imageLayer.contentsGravity = .resizeAspectFill
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            imageLayer.contentsGravity = .resizeAspect
        case .stretch:
            playerLayer.videoGravity = .resize
            imageLayer.contentsGravity = .resize
        }
        CATransaction.commit()
    }
}
