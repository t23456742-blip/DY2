import UIKit
import AVFoundation
import SwiftUI

enum FloatingAction {
    static let didScan = Notification.Name("dy.slim.float.scan")
    static let didSlim = Notification.Name("dy.slim.float.slim")
    static let didOneTap = Notification.Name("dy.slim.float.onetap")
    static let visibilityChanged = Notification.Name("dy.slim.float.visibility")
}

/// 全局悬浮球：窗口只包住球/菜单（整窗拖动），避免全屏穿透窗吞手势。
final class FloatingBallController: NSObject {
    static let shared = FloatingBallController()

    private(set) var isVisible = false
    private var overlayWindow: UIWindow?
    private var host: FloatBallHostView?
    private var audioPlayer: AVAudioPlayer?
    private var savedOrigin: CGPoint?
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    private let ballSize: CGFloat = 48
    private let chipSize: CGFloat = 40
    private let chipCount: CGFloat = 4
    private let chipGap: CGFloat = 8
    private let pad: CGFloat = 6

    private override init() {
        super.init()
        let c = NotificationCenter.default
        c.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        c.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        c.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func show() {
        DispatchQueue.main.async {
            self.startKeepAlive()
            self.presentOverlay()
            self.isVisible = true
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: true)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            if let win = self.overlayWindow {
                self.savedOrigin = win.frame.origin
            }
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
        startKeepAlive(); beginBgTask(); reassertOverlay()
    }

    @objc private func appDidEnterBackground() {
        guard isVisible else { return }
        startKeepAlive(); beginBgTask(); reassertOverlay()
    }

    @objc private func appDidBecomeActive() {
        guard isVisible else { return }
        reassertOverlay()
    }

    private var systemFloatLevel: UIWindow.Level {
        UIWindow.Level(rawValue: CGFloat(2_000_000_000))
    }

    private func collapsedSize() -> CGSize {
        CGSize(width: ballSize + pad * 2, height: ballSize + pad * 2)
    }

    private func expandedSize() -> CGSize {
        let menuH = chipSize * chipCount + chipGap * (chipCount - 1)
        let w = max(ballSize, chipSize) + pad * 2
        let h = ballSize + 10 + menuH + pad * 2
        return CGSize(width: w, height: h)
    }

    private func presentOverlay() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
        host = nil

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let screenBounds = scene?.screen.bounds ?? UIScreen.main.bounds
        let size = collapsedSize()
        var origin = savedOrigin ?? CGPoint(
            x: screenBounds.width - size.width - 10,
            y: screenBounds.height * 0.42
        )
        origin = clampOrigin(origin, size: size, in: screenBounds)

        let win: UIWindow
        if let scene {
            win = UIWindow(windowScene: scene)
        } else {
            win = UIWindow(frame: CGRect(origin: origin, size: size))
        }
        win.frame = CGRect(origin: origin, size: size)
        win.backgroundColor = .clear
        win.windowLevel = systemFloatLevel
        applySystemFloatTricks(to: win)

        let hostView = FloatBallHostView(ballSize: ballSize, chipSize: chipSize)
        hostView.onDrag = { [weak self] translation in
            self?.moveWindow(by: translation)
        }
        hostView.onDragEnded = { [weak self] in
            self?.snapWindow()
        }
        hostView.onExpandChanged = { [weak self] expanded in
            self?.resizeWindow(expanded: expanded)
        }
        hostView.onScan = { NotificationCenter.default.post(name: FloatingAction.didScan, object: nil) }
        hostView.onClean = { NotificationCenter.default.post(name: FloatingAction.didSlim, object: nil) }
        hostView.onOneTap = { NotificationCenter.default.post(name: FloatingAction.didOneTap, object: nil) }
        hostView.onClose = { [weak self] in self?.hide() }

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.addSubview(hostView)
        hostView.frame = root.view.bounds
        hostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        win.rootViewController = root
        win.makeKeyAndVisible()
        overlayWindow = win
        host = hostView
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func moveWindow(by translation: CGPoint) {
        guard let win = overlayWindow else { return }
        var f = win.frame
        f.origin.x += translation.x
        f.origin.y += translation.y
        let bounds = win.windowScene?.screen.bounds ?? UIScreen.main.bounds
        f.origin = clampOrigin(f.origin, size: f.size, in: bounds)
        win.frame = f
    }

    private func snapWindow() {
        guard let win = overlayWindow else { return }
        let bounds = win.windowScene?.screen.bounds ?? UIScreen.main.bounds
        var f = win.frame
        f.origin = clampOrigin(f.origin, size: f.size, in: bounds)
        UIView.animate(withDuration: 0.15) { win.frame = f }
        savedOrigin = f.origin
    }

    private func resizeWindow(expanded: Bool) {
        guard let win = overlayWindow else { return }
        let bounds = win.windowScene?.screen.bounds ?? UIScreen.main.bounds
        let newSize = expanded ? expandedSize() : collapsedSize()
        var f = win.frame
        // 展开时向上长，球仍在窗口底部
        if expanded {
            let bottom = f.maxY
            f.size = newSize
            f.origin.y = bottom - newSize.height
        } else {
            let bottom = f.maxY
            f.size = newSize
            f.origin.y = bottom - newSize.height
        }
        f.origin = clampOrigin(f.origin, size: f.size, in: bounds)
        UIView.animate(withDuration: 0.18) {
            win.frame = f
            self.host?.frame = CGRect(origin: .zero, size: newSize)
        }
        savedOrigin = f.origin
    }

    private func clampOrigin(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        let x = min(max(4, origin.x), bounds.width - size.width - 4)
        let y = min(max(40, origin.y), bounds.height - size.height - 4)
        return CGPoint(x: x, y: y)
    }

    private func reassertOverlay() {
        guard let win = overlayWindow else { return }
        applySystemFloatTricks(to: win)
        win.windowLevel = systemFloatLevel
        win.isHidden = false
        win.makeKeyAndVisible()
    }

    private func applySystemFloatTricks(to win: UIWindow) {
        let selVisible = NSSelectorFromString("setCanBecomeVisibleWithoutActiveApp:")
        if win.responds(to: selVisible) {
            _ = win.perform(selVisible, with: true)
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
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
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
    }

    private func stopKeepAlive() {
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

// MARK: - 球 + 菜单（画在小窗口里）

final class FloatBallHostView: UIView {
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onExpandChanged: ((Bool) -> Void)?
    var onScan: (() -> Void)?
    var onClean: (() -> Void)?
    var onOneTap: (() -> Void)?
    var onClose: (() -> Void)?

    private let ballSize: CGFloat
    private let chipSize: CGFloat
    private let ball = UIView()
    private var strip: UIStackView?
    private var statusLabel: UILabel?
    private var expanded = false
    private var didDrag = false
    private var lastPanPoint: CGPoint = .zero

    init(ballSize: CGFloat, chipSize: CGFloat) {
        self.ballSize = ballSize
        self.chipSize = chipSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        setupBall()
        setupStatus()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onBusyNote(_:)),
            name: Notification.Name("dy.slim.float.status"),
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 球贴窗口底边居中
        ball.bounds = CGRect(x: 0, y: 0, width: ballSize, height: ballSize)
        ball.center = CGPoint(x: bounds.midX, y: bounds.height - 6 - ballSize / 2)
        layoutStrip()
    }

    private func setupBall() {
        ball.backgroundColor = UIColor(red: 0.07, green: 0.12, blue: 0.2, alpha: 0.96)
        ball.layer.cornerRadius = ballSize / 2
        ball.layer.borderWidth = 1.5
        ball.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1).cgColor
        ball.layer.shadowOpacity = 0.35
        ball.layer.shadowRadius = 4
        ball.layer.shadowOffset = CGSize(width: 0, height: 2)
        ball.isUserInteractionEnabled = true

        if let img = UIImage(named: "FloatIcon") {
            let iv = UIImageView(frame: CGRect(x: 6, y: 6, width: ballSize - 12, height: ballSize - 12))
            iv.image = img
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = (ballSize - 12) / 2
            iv.isUserInteractionEnabled = false
            ball.addSubview(iv)
        } else {
            let lab = UILabel(frame: CGRect(x: 0, y: 0, width: ballSize, height: ballSize))
            lab.text = "DY"
            lab.textAlignment = .center
            lab.font = .systemFont(ofSize: 13, weight: .black)
            lab.textColor = .white
            lab.isUserInteractionEnabled = false
            ball.addSubview(lab)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        ball.addGestureRecognizer(pan)
        addSubview(ball)
    }

    private func setupStatus() {
        let lab = UILabel()
        lab.font = .systemFont(ofSize: 10, weight: .semibold)
        lab.textColor = .white
        lab.textAlignment = .center
        lab.backgroundColor = UIColor(white: 0.05, alpha: 0.88)
        lab.layer.cornerRadius = 8
        lab.clipsToBounds = true
        lab.isHidden = true
        lab.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lab)
        statusLabel = lab
        // 状态条放在球上方一点（展开时仍可见区域有限，主要靠 Notification 短闪）
        NSLayoutConstraint.activate([
            lab.centerXAnchor.constraint(equalTo: centerXAnchor),
            lab.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            lab.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            lab.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            didDrag = false
            lastPanPoint = g.location(in: nil)
            if expanded {
                setExpanded(false, animated: true)
                onExpandChanged?(false)
            }
        case .changed:
            let p = g.location(in: nil)
            let dx = p.x - lastPanPoint.x
            let dy = p.y - lastPanPoint.y
            if hypot(dx, dy) > 2 { didDrag = true }
            lastPanPoint = p
            onDrag?(CGPoint(x: dx, y: dy))
        case .ended, .cancelled:
            if !didDrag {
                toggleExpand()
            } else {
                onDragEnded?()
            }
            didDrag = false
        default:
            break
        }
    }

    private func toggleExpand() {
        let next = !expanded
        onExpandChanged?(next)
        setExpanded(next, animated: true)
    }

    func setExpanded(_ on: Bool, animated: Bool) {
        expanded = on
        strip?.removeFromSuperview()
        strip = nil
        guard on else { return }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.addArrangedSubview(chip("扫描", UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1), #selector(doScan)))
        stack.addArrangedSubview(chip("清理", UIColor(red: 1, green: 0.35, blue: 0.4, alpha: 1), #selector(doClean)))
        stack.addArrangedSubview(chip("一键刷新", UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1), #selector(doOneTap)))
        stack.addArrangedSubview(chip("关悬浮", UIColor(white: 0.92, alpha: 1), #selector(doClose)))
        addSubview(stack)
        strip = stack
        layoutStrip()
        if animated {
            stack.alpha = 0
            stack.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            UIView.animate(withDuration: 0.18) {
                stack.alpha = 1
                stack.transform = .identity
            }
        }
    }

    private func layoutStrip() {
        guard let strip else { return }
        let h = chipSize * 4 + 8 * 3
        let w = chipSize
        strip.frame = CGRect(
            x: (bounds.width - w) / 2,
            y: ball.frame.minY - h - 10,
            width: w,
            height: h
        )
    }

    private func chip(_ title: String, _ color: UIColor, _ action: Selector) -> UIView {
        let wrap = UIView(frame: CGRect(x: 0, y: 0, width: chipSize, height: chipSize))
        wrap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: chipSize),
            wrap.heightAnchor.constraint(equalToConstant: chipSize)
        ])
        let b = UIButton(type: .custom)
        b.frame = wrap.bounds
        b.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        b.backgroundColor = UIColor(red: 0.1, green: 0.13, blue: 0.18, alpha: 0.96)
        b.layer.cornerRadius = chipSize / 2
        b.layer.borderWidth = 1
        b.layer.borderColor = color.withAlphaComponent(0.85).cgColor
        b.setTitle(title, for: .normal)
        b.setTitleColor(color, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: title.count > 2 ? 8 : 11, weight: .bold)
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.addTarget(self, action: action, for: .touchUpInside)
        wrap.addSubview(b)
        return wrap
    }

    @objc private func doScan() { collapseThen { self.onScan?() }; flash("后台扫描中…") }
    @objc private func doClean() { collapseThen { self.onClean?() }; flash("后台清理中…") }
    @objc private func doOneTap() { collapseThen { self.onOneTap?() }; flash("一键刷新中…") }
    @objc private func doClose() { collapseThen { self.onClose?() } }

    private func collapseThen(_ block: @escaping () -> Void) {
        if expanded {
            setExpanded(false, animated: true)
            onExpandChanged?(false)
        }
        block()
    }

    @objc private func onBusyNote(_ note: Notification) {
        if let text = note.object as? String { flash(text) }
    }

    private func flash(_ text: String) {
        guard let statusLabel else { return }
        statusLabel.text = " \(text) "
        statusLabel.isHidden = false
        statusLabel.alpha = 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideStatus), object: nil)
        perform(#selector(hideStatus), with: nil, afterDelay: 1.6)
    }

    @objc private func hideStatus() {
        UIView.animate(withDuration: 0.25) { self.statusLabel?.alpha = 0 } completion: { _ in
            self.statusLabel?.isHidden = true
        }
    }
}

struct FloatPiPAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
