import UIKit
import AVFoundation
import SwiftUI

enum FloatingAction {
    static let didScan = Notification.Name("dy.slim.float.scan")
    static let didSlim = Notification.Name("dy.slim.float.slim")
    static let didOneTap = Notification.Name("dy.slim.float.onetap")
    static let visibilityChanged = Notification.Name("dy.slim.float.visibility")
}

/// 事件穿透：空白处把触摸交给下层窗口（本 App / 其他 App），只有球和菜单可点。
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

/// 全局小悬浮球：可拖动 · 菜单 · 穿透触摸 · 后台保活（尽量盖在其他 App 上）
final class FloatingBallController: NSObject {
    static let shared = FloatingBallController()

    private(set) var isVisible = false
    private var overlayWindow: PassthroughWindow?
    private var audioPlayer: AVAudioPlayer?
    private var savedCenter: CGPoint?
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
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
            if let root = self.overlayWindow?.rootViewController as? CompactFloatViewController {
                self.savedCenter = root.ballCenter
            }
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
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
        reassertOverlay()
    }

    @objc private func appDidEnterBackground() {
        guard isVisible else { return }
        startKeepAlive()
        beginBgTask()
        reassertOverlay()
    }

    @objc private func appDidBecomeActive() {
        guard isVisible else { return }
        reassertOverlay()
    }

    private func reassertOverlay() {
        guard let win = overlayWindow else { return }
        applySystemFloatTricks(to: win)
        win.windowLevel = Self.systemFloatLevel
        win.isHidden = false
        // 穿透窗可一直作为 key：空白处 hitTest 为 nil，主界面/其它 App 仍可点
        win.makeKeyAndVisible()
    }

    private static var systemFloatLevel: UIWindow.Level {
        // 高于 alert / statusBar，尽量盖住其他界面
        UIWindow.Level(rawValue: CGFloat(2_000_000_000))
    }

    private func presentOverlay() {
        overlayWindow?.isHidden = true
        overlayWindow = nil

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let win: PassthroughWindow = {
            if let scene { return PassthroughWindow(windowScene: scene) }
            return PassthroughWindow(frame: UIScreen.main.bounds)
        }()
        win.backgroundColor = .clear
        win.windowLevel = Self.systemFloatLevel
        applySystemFloatTricks(to: win)

        let root = CompactFloatViewController()
        root.initialCenter = savedCenter
        root.onScan = { NotificationCenter.default.post(name: FloatingAction.didScan, object: nil) }
        root.onClean = { NotificationCenter.default.post(name: FloatingAction.didSlim, object: nil) }
        root.onOneTap = { NotificationCenter.default.post(name: FloatingAction.didOneTap, object: nil) }
        root.onToggleFloat = { [weak self] in self?.hide() }
        win.rootViewController = root
        win.makeKeyAndVisible()
        overlayWindow = win
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func applySystemFloatTricks(to win: UIWindow) {
        // 巨魔 / 无沙盒环境：无前台 App 时仍尝试保持可见（系统私有）
        let selVisible = NSSelectorFromString("setCanBecomeVisibleWithoutActiveApp:")
        if win.responds(to: selVisible) {
            _ = win.perform(selVisible, with: true)
        }
        let selSecure = NSSelectorFromString("_setSecure:")
        if win.responds(to: selSecure) {
            _ = win.perform(selSecure, with: false)
        }
        win.windowLevel = Self.systemFloatLevel
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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 保活失败不阻断悬浮
        }
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

// MARK: - 球 + 竖条菜单

final class CompactFloatViewController: UIViewController {
    var onScan: (() -> Void)?
    var onClean: (() -> Void)?
    var onOneTap: (() -> Void)?
    var onToggleFloat: (() -> Void)?
    var initialCenter: CGPoint?

    private let ballSize: CGFloat = 44
    private let chipSize: CGFloat = 40
    private var ball: UIView!
    private var strip: UIView?
    private var statusLabel: UILabel!
    private var expanded = false
    private var didDrag = false
    private var isPanning = false
    private var panStartCenter: CGPoint = .zero

    var ballCenter: CGPoint { ball?.center ?? .zero }

    override func loadView() {
        // 根视图也穿透：只点子视图
        let v = PassthroughRootView(frame: UIScreen.main.bounds)
        v.backgroundColor = .clear
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        ball = makeBall()
        view.addSubview(ball)

        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor(white: 0.05, alpha: 0.88)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.heightAnchor.constraint(equalToConstant: 30)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onBusyNote(_:)),
            name: Notification.Name("dy.slim.float.status"),
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if ball.superview != nil, !isPanning {
            let invalid = ball.center == .zero || (ball.center.x < 1 && ball.center.y < 1)
            if invalid {
                if let c = initialCenter, c.x > 1, c.y > 1 {
                    ball.center = clamp(c)
                } else {
                    ball.center = CGPoint(x: view.bounds.width - 30, y: view.bounds.height * 0.42)
                }
            }
        }
        layoutStrip()
    }

    private func makeBall() -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: ballSize, height: ballSize))
        v.isUserInteractionEnabled = true
        v.backgroundColor = UIColor(red: 0.07, green: 0.12, blue: 0.2, alpha: 0.95)
        v.layer.cornerRadius = ballSize / 2
        v.layer.borderWidth = 1.5
        v.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1).cgColor
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.35
        v.layer.shadowRadius = 4
        v.layer.shadowOffset = CGSize(width: 0, height: 2)

        if let img = UIImage(named: "FloatIcon") {
            let iv = UIImageView(frame: v.bounds.insetBy(dx: 5, dy: 5))
            iv.image = img
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = (ballSize - 10) / 2
            iv.isUserInteractionEnabled = false
            v.addSubview(iv)
        } else {
            let lab = UILabel(frame: v.bounds)
            lab.text = "DY"
            lab.textAlignment = .center
            lab.font = .systemFont(ofSize: 12, weight: .black)
            lab.textColor = .white
            lab.isUserInteractionEnabled = false
            v.addSubview(lab)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pan)
        return v
    }

    private func clamp(_ c: CGPoint) -> CGPoint {
        let half = ballSize / 2
        let w = max(view.bounds.width, 1)
        let h = max(view.bounds.height, 1)
        let x = min(max(half + 4, c.x), w - half - 4)
        let y = min(max(half + 4, c.y), h - half - 4)
        return CGPoint(x: x, y: y)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            isPanning = true
            didDrag = false
            panStartCenter = ball.center
            if expanded { collapse() }
        case .changed:
            let t = g.translation(in: view)
            if hypot(t.x, t.y) > 4 { didDrag = true }
            ball.center = clamp(CGPoint(x: panStartCenter.x + t.x, y: panStartCenter.y + t.y))
            layoutStrip()
        case .ended, .cancelled:
            isPanning = false
            if !didDrag {
                tapBall()
            } else {
                UIView.animate(withDuration: 0.15) {
                    self.ball.center = self.clamp(self.ball.center)
                }
            }
            didDrag = false
        default:
            break
        }
    }

    @objc private func tapBall() {
        if expanded { collapse() } else { expand() }
    }

    private func expand() {
        collapse()
        expanded = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        // 纯 frame 布局，避免和 Auto Layout 打架
        stack.translatesAutoresizingMaskIntoConstraints = true

        stack.addArrangedSubview(roundChip(title: "扫描", color: UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1), action: #selector(doScan)))
        stack.addArrangedSubview(roundChip(title: "清理", color: UIColor(red: 1, green: 0.35, blue: 0.4, alpha: 1), action: #selector(doClean)))
        stack.addArrangedSubview(roundChip(title: "一键刷新", color: UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1), action: #selector(doOneTap)))
        stack.addArrangedSubview(roundChip(title: "关悬浮", color: UIColor(white: 0.92, alpha: 1), action: #selector(doClose)))

        view.addSubview(stack)
        strip = stack
        layoutStrip()

        stack.alpha = 0
        stack.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.18) {
            stack.alpha = 1
            stack.transform = .identity
        }
    }

    private func layoutStrip() {
        guard let strip else { return }
        let count = CGFloat(4)
        let h = chipSize * count + 8 * (count - 1)
        let w = chipSize
        var x = ball.center.x - w / 2
        x = min(max(6, x), view.bounds.width - w - 6)
        let aboveY = ball.frame.minY - h - 10
        let y: CGFloat = aboveY > 12 ? aboveY : ball.frame.maxY + 10
        strip.frame = CGRect(x: x, y: y, width: w, height: h)
    }

    private func roundChip(title: String, color: UIColor, action: Selector) -> UIView {
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

    private func collapse() {
        expanded = false
        strip?.removeFromSuperview()
        strip = nil
    }

    @objc private func doScan() {
        collapse()
        flash("后台扫描中…")
        onScan?()
    }

    @objc private func doClean() {
        collapse()
        flash("后台清理中…")
        onClean?()
    }

    @objc private func doOneTap() {
        collapse()
        flash("一键刷新中…")
        onOneTap?()
    }

    @objc private func doClose() {
        collapse()
        onToggleFloat?()
    }

    @objc private func onBusyNote(_ note: Notification) {
        if let text = note.object as? String {
            flash(text)
        }
    }

    private func flash(_ text: String) {
        statusLabel.text = "  \(text)  "
        statusLabel.isHidden = false
        statusLabel.alpha = 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideStatus), object: nil)
        perform(#selector(hideStatus), with: nil, afterDelay: 1.6)
    }

    @objc private func hideStatus() {
        UIView.animate(withDuration: 0.25) { self.statusLabel.alpha = 0 } completion: { _ in
            self.statusLabel.isHidden = true
        }
    }
}

/// 根视图穿透：只有子视图（球/菜单）命中
final class PassthroughRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 占位（兼容旧调用）
struct FloatPiPAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
