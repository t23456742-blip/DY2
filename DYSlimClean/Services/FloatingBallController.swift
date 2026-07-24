import UIKit
import AVFoundation

enum FloatingAction {
    static let visibilityChanged = Notification.Name("dy.slim.float.visibility")
}

/// 全屏穿透悬浮球：拖动只改球位置（不闪）；点开菜单直调 ViewModel。
/// 切到其它 App 时靠静音音频 + SpringBoard 窗口权限尽量保活（进程被划掉仍会消失）。
final class FloatingBallController: NSObject {
    static let shared = FloatingBallController()

    private(set) var isVisible = false
    /// 强引用，避免只绑 weak 时回调空跑「没功能」
    private var cleanModel: CleanViewModel?
    private var overlayWindow: PassthroughWindow?
    private var host: FloatBallHostView?
    private var audioPlayer: AVAudioPlayer?
    private var savedCenter: CGPoint?
    private var bgTask = UIBackgroundTaskIdentifier.invalid
    private var keepAliveTimer: Timer?

    private let ballSize: CGFloat = 52
    private let prefsKey = "dy.slim.float.enabled"
    private let centerKey = "dy.slim.float.center"

    private override init() {
        super.init()
        let c = NotificationCenter.default
        c.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        c.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        c.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func bind(cleanModel: CleanViewModel) {
        self.cleanModel = cleanModel
        // 上次开着悬浮，冷启动自动恢复
        if UserDefaults.standard.bool(forKey: prefsKey), !isVisible {
            show()
        }
    }

    func show() {
        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: self.prefsKey)
            self.startKeepAlive()
            if self.overlayWindow == nil {
                self.presentOverlay()
            } else {
                self.reassertOverlay(forceKey: false)
            }
            self.isVisible = true
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: true)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            if let c = self.host?.ballCenter {
                self.savedCenter = c
                UserDefaults.standard.set(NSStringFromCGPoint(c), forKey: self.centerKey)
            }
            UserDefaults.standard.set(false, forKey: self.prefsKey)
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
            self.host = nil
            self.stopKeepAlive()
            self.endBgTask()
            self.isVisible = false
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: false)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    @objc private func appWillResignActive() {
        guard isVisible else { return }
        startKeepAlive()
        beginBgTask()
        // 不要反复 makeKey，会闪
        reassertOverlay(forceKey: false)
    }

    @objc private func appDidEnterBackground() {
        guard isVisible else { return }
        startKeepAlive()
        beginBgTask()
        reassertOverlay(forceKey: true)
    }

    @objc private func appDidBecomeActive() {
        guard isVisible else { return }
        reassertOverlay(forceKey: false)
        startKeepAlive()
    }

    /// AssistiveTouch 量级，避免 20亿 level 被系统反复打回导致闪烁
    private var systemFloatLevel: UIWindow.Level {
        UIWindow.Level(rawValue: 1_000_001)
    }

    private func presentOverlay() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let bounds = scene?.screen.bounds ?? UIScreen.main.bounds
        let win: PassthroughWindow
        if let scene {
            win = PassthroughWindow(windowScene: scene)
        } else {
            win = PassthroughWindow(frame: bounds)
        }
        win.frame = bounds
        win.backgroundColor = .clear
        win.isOpaque = false
        win.windowLevel = systemFloatLevel
        applySystemFloatTricks(to: win)

        let hostView = FloatBallHostView(ballSize: ballSize)
        hostView.frame = bounds
        hostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let s = UserDefaults.standard.string(forKey: centerKey) {
            let p = CGPointFromString(s)
            if p.x > 10, p.y > 10 {
                hostView.initialCenter = p
            }
        } else if let c = savedCenter, c.x > 10, c.y > 10 {
            hostView.initialCenter = c
        }
        hostView.onScan = { [weak self] in
            guard let model = self?.cleanModel else {
                self?.host?.flash("未绑定，请回助手页重开悬浮")
                return
            }
            self?.host?.flash("扫描中…")
            model.scan(fromFloat: true)
        }
        hostView.onClean = { [weak self] in
            guard let model = self?.cleanModel else {
                self?.host?.flash("未绑定，请回助手页重开悬浮")
                return
            }
            self?.host?.flash("清理中…")
            model.requestSlimFromFloat()
        }
        hostView.onOneTap = { [weak self] in
            guard let model = self?.cleanModel else {
                self?.host?.flash("未绑定，请回助手页重开悬浮")
                return
            }
            self?.host?.flash("一键刷新中…")
            model.runOneTapReset(fromFloat: true)
        }
        hostView.onClose = { [weak self] in self?.hide() }

        let root = UIViewController()
        root.view = PassthroughRootView(frame: bounds)
        root.view.backgroundColor = .clear
        root.view.addSubview(hostView)
        win.rootViewController = root
        win.isHidden = false
        win.makeKeyAndVisible()
        // 立刻把 key 还回去，避免抢焦点闪屏，但仍保持悬浮窗可见
        DispatchQueue.main.async {
            Self.resignOverlayKeyIfNeeded(keeping: win)
        }

        overlayWindow = win
        host = hostView
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private static func resignOverlayKeyIfNeeded(keeping win: UIWindow) {
        guard win.isKeyWindow else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows where w !== win && !w.isHidden {
                w.makeKey()
                return
            }
        }
    }

    private func reassertOverlay(forceKey: Bool) {
        guard let win = overlayWindow else {
            if isVisible { presentOverlay() }
            return
        }
        applySystemFloatTricks(to: win)
        win.windowLevel = systemFloatLevel
        win.isHidden = false
        if forceKey || UIApplication.shared.applicationState != .active {
            win.makeKeyAndVisible()
            DispatchQueue.main.async {
                Self.resignOverlayKeyIfNeeded(keeping: win)
            }
        }
    }

    private func applySystemFloatTricks(to win: UIWindow) {
        let tricks = [
            "setCanBecomeVisibleWithoutActiveApp:",
            "_setCanBecomeVisibleWithoutActiveApp:",
            "setKeepContextInBackground:",
            "_setSecure:"
        ]
        for name in tricks {
            let sel = NSSelectorFromString(name)
            guard win.responds(to: sel) else { continue }
            win.perform(sel, with: true)
        }
        win.windowLevel = systemFloatLevel
    }

    private func beginBgTask() {
        endBgTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "dy.slim.float") { [weak self] in
            self?.endBgTask()
        }
    }

    private func endBgTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    private func startKeepAlive() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if audioPlayer == nil, let url = Self.makeSilentWavURL() {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            audioPlayer?.prepareToPlay()
        }
        audioPlayer?.play()
        UIApplication.shared.isIdleTimerDisabled = true
        beginBgTask()

        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if self.audioPlayer?.isPlaying != true {
                self.audioPlayer?.play()
            }
            self.beginBgTask()
            if UIApplication.shared.applicationState != .active {
                self.reassertOverlay(forceKey: true)
            }
        }
        if let t = keepAliveTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        audioPlayer?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func makeSilentWavURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dy_slim_silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = Data([
            0x52,0x49,0x46,0x46, 0x28,0x00,0x00,0x00, 0x57,0x41,0x56,0x45, 0x66,0x6D,0x74,0x20,
            0x10,0x00,0x00,0x00, 0x01,0x00,0x01,0x00, 0x44,0xAC,0x00,0x00, 0x88,0x58,0x01,0x00,
            0x02,0x00,0x10,0x00, 0x64,0x61,0x74,0x61, 0x04,0x00,0x00,0x00, 0x00,0x00,0x00,0x00
        ])
        try? data.write(to: url)
        return url
    }
}

final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

final class PassthroughRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

final class FloatBallHostView: UIView, UIGestureRecognizerDelegate {
    var onScan: (() -> Void)?
    var onClean: (() -> Void)?
    var onOneTap: (() -> Void)?
    var onClose: (() -> Void)?
    var initialCenter: CGPoint?

    private let ballSize: CGFloat
    private let chipH: CGFloat = 36
    private let chipW: CGFloat = 78
    private let ball = UIView()
    private var menuContainer: UIView?
    private var statusLabel: UILabel!
    private var didPlaceBall = false
    private var isDragging = false
    private var panStartCenter: CGPoint = .zero

    var ballCenter: CGPoint { ball.center }

    init(ballSize: CGFloat) {
        self.ballSize = ballSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    private func setup() {
        ball.bounds = CGRect(x: 0, y: 0, width: ballSize, height: ballSize)
        ball.backgroundColor = UIColor(red: 0.07, green: 0.12, blue: 0.2, alpha: 0.96)
        ball.layer.cornerRadius = ballSize / 2
        ball.layer.borderWidth = 1.5
        ball.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1).cgColor
        ball.layer.shadowOpacity = 0.3
        ball.layer.shadowRadius = 3
        ball.isUserInteractionEnabled = true

        let lab = UILabel(frame: ball.bounds)
        lab.text = "DY"
        lab.textAlignment = .center
        lab.font = .systemFont(ofSize: 14, weight: .black)
        lab.textColor = .white
        lab.isUserInteractionEnabled = false
        ball.addSubview(lab)
        addSubview(ball)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        ball.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        tap.delegate = self
        ball.addGestureRecognizer(tap)

        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor(white: 0.05, alpha: 0.9)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            statusLabel.heightAnchor.constraint(equalToConstant: 32)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onBusyNote(_:)),
            name: Notification.Name("dy.slim.float.status"),
            object: nil
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 只首次定位，拖动时绝不在 layout 里改 center（闪的主因）
        if !didPlaceBall, bounds.width > 1, !isDragging {
            if let c = initialCenter { ball.center = clamp(c) }
            else { ball.center = CGPoint(x: bounds.width - 36, y: bounds.height * 0.42) }
            didPlaceBall = true
        }
        if menuContainer != nil {
            layoutMenu()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func clamp(_ c: CGPoint) -> CGPoint {
        let half = ballSize / 2
        guard bounds.width > 1 else { return c }
        return CGPoint(
            x: min(max(half + 4, c.x), bounds.width - half - 4),
            y: min(max(half + 48, c.y), bounds.height - half - 4)
        )
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            isDragging = false
            panStartCenter = ball.center
            if menuContainer != nil { collapseMenu() }
            ball.layer.shadowOpacity = 0
        case .changed:
            let t = g.translation(in: self)
            if hypot(t.x, t.y) > 4 { isDragging = true }
            // 关隐式动画，避免一闪一闪
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ball.center = clamp(CGPoint(x: panStartCenter.x + t.x, y: panStartCenter.y + t.y))
            CATransaction.commit()
        case .ended, .cancelled, .failed:
            ball.layer.shadowOpacity = 0.3
            isDragging = false
        default:
            break
        }
    }

    @objc private func onTap() {
        if menuContainer != nil { collapseMenu() } else { expandMenu() }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    private func expandMenu() {
        collapseMenu()
        let box = UIView()
        box.backgroundColor = UIColor(red: 0.08, green: 0.1, blue: 0.14, alpha: 0.96)
        box.layer.cornerRadius = 14
        box.layer.borderWidth = 1
        box.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 0.45).cgColor
        box.isUserInteractionEnabled = true

        let titles = ["扫描", "清理", "一键刷新", "关悬浮"]
        let colors: [UIColor] = [
            UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1),
            UIColor(red: 1, green: 0.35, blue: 0.4, alpha: 1),
            UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1),
            UIColor(white: 0.9, alpha: 1)
        ]
        let actions: [Selector] = [#selector(doScan), #selector(doClean), #selector(doOneTap), #selector(doClose)]
        let pad: CGFloat = 8
        let gap: CGFloat = 6
        let totalH = pad * 2 + chipH * 4 + gap * 3
        box.bounds = CGRect(x: 0, y: 0, width: chipW + pad * 2, height: totalH)

        for i in 0..<4 {
            let b = UIButton(type: .system)
            b.frame = CGRect(x: pad, y: pad + CGFloat(i) * (chipH + gap), width: chipW, height: chipH)
            b.backgroundColor = UIColor(red: 0.12, green: 0.15, blue: 0.2, alpha: 1)
            b.layer.cornerRadius = 10
            b.layer.borderWidth = 1
            b.layer.borderColor = colors[i].withAlphaComponent(0.85).cgColor
            b.setTitle(titles[i], for: .normal)
            b.setTitleColor(colors[i], for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
            b.addTarget(self, action: actions[i], for: .touchUpInside)
            box.addSubview(b)
        }
        addSubview(box)
        menuContainer = box
        layoutMenu()
        box.alpha = 0
        UIView.animate(withDuration: 0.12) { box.alpha = 1 }
        flash("点菜单执行")
    }

    private func collapseMenu() {
        menuContainer?.removeFromSuperview()
        menuContainer = nil
    }

    private func layoutMenu() {
        guard let box = menuContainer else { return }
        let w = box.bounds.width
        let h = box.bounds.height
        var x = ball.center.x - w / 2
        x = min(max(8, x), bounds.width - w - 8)
        let above = ball.frame.minY - h - 10
        let y = above > 50 ? above : ball.frame.maxY + 10
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = CGRect(x: x, y: y, width: w, height: h)
        CATransaction.commit()
    }

    @objc private func doScan() {
        collapseMenu()
        onScan?()
    }

    @objc private func doClean() {
        collapseMenu()
        onClean?()
    }

    @objc private func doOneTap() {
        collapseMenu()
        onOneTap?()
    }

    @objc private func doClose() {
        collapseMenu()
        onClose?()
    }

    @objc private func onBusyNote(_ note: Notification) {
        if let t = note.object as? String { flash(t) }
    }

    func flash(_ text: String) {
        statusLabel.text = "  \(text)  "
        statusLabel.isHidden = false
        statusLabel.alpha = 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideStatus), object: nil)
        perform(#selector(hideStatus), with: nil, afterDelay: 1.8)
    }

    @objc private func hideStatus() {
        UIView.animate(withDuration: 0.2) { self.statusLabel.alpha = 0 } completion: { _ in
            self.statusLabel.isHidden = true
        }
    }
}
