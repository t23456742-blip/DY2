import UIKit
import AVKit
import AVFoundation
import SwiftUI

enum FloatingAction {
    static let didScan = Notification.Name("dy.slim.float.scan")
    static let didSlim = Notification.Name("dy.slim.float.slim")
    static let visibilityChanged = Notification.Name("dy.slim.float.visibility")
}

/// 全局悬浮：系统画中画叠在其它 App 上；失败则回退高优先级窗口 + 保活
final class FloatingBallController: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = FloatingBallController()

    private(set) var isVisible = false
    weak var sourceView: UIView?

    private var pipController: AVPictureInPictureController?
    private var pipContentVC: FloatPiPContentViewController?
    private var audioPlayer: AVAudioPlayer?
    private var fallbackWindow: UIWindow?

    private override init() { super.init() }

    func show() {
        DispatchQueue.main.async {
            self.startKeepAlive()
            if self.startGlobalPiP() {
                self.isVisible = true
                NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: true)
            } else {
                self.startFallbackOverlay()
                self.isVisible = true
                NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: true)
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.pipController?.stopPictureInPicture()
            self.pipController = nil
            self.pipContentVC = nil
            self.fallbackWindow?.isHidden = true
            self.fallbackWindow = nil
            self.stopKeepAlive()
            self.isVisible = false
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: false)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: PiP（真正能盖在其它 App 上）

    @discardableResult
    private func startGlobalPiP() -> Bool {
        guard #available(iOS 15.0, *) else { return false }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
        guard let source = sourceView ?? keyRootView() else { return false }

        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let content = FloatPiPContentViewController()
        content.onScan = { NotificationCenter.default.post(name: FloatingAction.didScan, object: nil) }
        content.onSlim = { NotificationCenter.default.post(name: FloatingAction.didSlim, object: nil) }
        content.onClose = { [weak self] in self?.hide() }
        pipContentVC = content

        let cfg = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: source,
            contentViewController: content
        )
        let pip = AVPictureInPictureController(contentSource: cfg)
        pip.delegate = self
        // 视频通话 PiP 无 canStartPictureInPictureAutomaticallyWhenEnteringBackground
        pipController = pip

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if pip.isPictureInPicturePossible {
                        pip.startPictureInPicture()
                    } else {
                        self.pipController = nil
                        self.startFallbackOverlay()
                    }
                }
            }
        }
        return true
    }

    private func keyRootView() -> UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .view
    }

    // MARK: Fallback

    private func startFallbackOverlay() {
        fallbackWindow?.isHidden = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let win: UIWindow = {
            if let scene { return UIWindow(windowScene: scene) }
            return UIWindow(frame: UIScreen.main.bounds)
        }()
        win.windowLevel = UIWindow.Level(rawValue: 1_000_000)
        win.backgroundColor = .clear
        let sel = NSSelectorFromString("setCanBecomeVisibleWithoutActiveApp:")
        if win.responds(to: sel) { win.perform(sel, with: true) }

        let root = OverlayFloatViewController()
        root.onScan = { NotificationCenter.default.post(name: FloatingAction.didScan, object: nil) }
        root.onSlim = { NotificationCenter.default.post(name: FloatingAction.didSlim, object: nil) }
        root.onClose = { [weak self] in self?.hide() }
        win.rootViewController = root
        win.isHidden = false
        win.makeKeyAndVisible()
        fallbackWindow = win
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: Keep alive

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

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if fallbackWindow == nil {
            isVisible = false
            stopKeepAlive()
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: false)
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        startFallbackOverlay()
    }
}

// MARK: - 画中画内容（系统级全局窗口）

final class FloatPiPContentViewController: AVPictureInPictureVideoCallViewController {
    var onScan: (() -> Void)?
    var onSlim: (() -> Void)?
    var onClose: (() -> Void)?

    private let ball = UIButton(type: .custom)
    private let panel = UIStackView()
    private var expanded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        preferredContentSize = CGSize(width: 88, height: 88)

        ball.translatesAutoresizingMaskIntoConstraints = false
        ball.layer.cornerRadius = 32
        ball.clipsToBounds = true
        ball.layer.borderWidth = 2
        ball.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1).cgColor
        if let img = UIImage(named: "FloatIcon") {
            ball.setImage(img, for: .normal)
            ball.imageView?.contentMode = .scaleAspectFill
        } else {
            ball.setTitle("DY瘦身", for: .normal)
            ball.titleLabel?.font = .systemFont(ofSize: 11, weight: .black)
            ball.titleLabel?.numberOfLines = 2
            ball.titleLabel?.textAlignment = .center
            ball.backgroundColor = UIColor(red: 0.06, green: 0.12, blue: 0.22, alpha: 1)
        }
        ball.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        view.addSubview(ball)

        panel.axis = .vertical
        panel.spacing = 6
        panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        panel.addArrangedSubview(chip("扫描", UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1), #selector(scan)))
        panel.addArrangedSubview(chip("瘦身", UIColor(red: 1, green: 0.35, blue: 0.4, alpha: 1), #selector(slim)))
        panel.addArrangedSubview(chip("关闭", .white, #selector(close)))

        NSLayoutConstraint.activate([
            ball.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            ball.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ball.widthAnchor.constraint(equalToConstant: 64),
            ball.heightAnchor.constraint(equalToConstant: 64),
            panel.topAnchor.constraint(equalTo: ball.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
    }

    private func chip(_ t: String, _ c: UIColor, _ sel: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(t, for: .normal)
        b.setTitleColor(c, for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 14)
        b.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    @objc private func toggle() {
        expanded.toggle()
        panel.isHidden = !expanded
        preferredContentSize = expanded ? CGSize(width: 140, height: 210) : CGSize(width: 88, height: 88)
    }

    @objc private func scan() { onScan?(); collapse() }
    @objc private func slim() { onSlim?(); collapse() }
    @objc private func close() { onClose?() }
    private func collapse() {
        expanded = false
        panel.isHidden = true
        preferredContentSize = CGSize(width: 88, height: 88)
    }
}

// MARK: - 回退：可拖动悬浮球

final class OverlayFloatViewController: UIViewController {
    var onScan: (() -> Void)?
    var onSlim: (() -> Void)?
    var onClose: (() -> Void)?

    private let ballSize: CGFloat = 58
    private var ball: UIView!
    private var menu: UIView?
    private var expanded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        ball = UIView(frame: CGRect(x: 0, y: 0, width: ballSize, height: ballSize))
        ball.center = CGPoint(x: view.bounds.width - 40, y: view.bounds.height * 0.55)
        ball.backgroundColor = UIColor(red: 0.06, green: 0.12, blue: 0.22, alpha: 0.95)
        ball.layer.cornerRadius = ballSize / 2
        ball.layer.borderWidth = 2
        ball.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1).cgColor
        let iv = UIImageView(frame: ball.bounds.insetBy(dx: 4, dy: 4))
        iv.image = UIImage(named: "FloatIcon")
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = (ballSize - 8) / 2
        iv.isUserInteractionEnabled = false
        ball.addSubview(iv)
        view.addSubview(ball)
        ball.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        ball.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if ball.center == .zero || ball.center.x < 1 {
            ball.center = CGPoint(x: view.bounds.width - 40, y: view.bounds.height * 0.55)
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        if expanded { collapse() }
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        var c = ball.center
        c.x += t.x; c.y += t.y
        let half = ballSize / 2
        c.x = min(max(half + 4, c.x), view.bounds.width - half - 4)
        c.y = min(max(half + 4, c.y), view.bounds.height - half - 4)
        ball.center = c
        if g.state == .ended {
            let x = c.x < view.bounds.midX ? half + 8 : view.bounds.width - half - 8
            UIView.animate(withDuration: 0.2) { self.ball.center.x = x }
        }
    }

    @objc private func tap() {
        expanded ? collapse() : expand()
    }

    private func expand() {
        collapse()
        expanded = true
        let m = UIView(frame: CGRect(x: 0, y: 0, width: 112, height: 132))
        m.backgroundColor = UIColor(red: 0.1, green: 0.13, blue: 0.18, alpha: 0.96)
        m.layer.cornerRadius = 14
        let titles = ["扫描", "瘦身", "关闭悬浮"]
        for (i, t) in titles.enumerated() {
            let b = UIButton(type: .system)
            b.frame = CGRect(x: 0, y: CGFloat(i) * 44, width: 112, height: 44)
            b.setTitle(t, for: .normal)
            b.setTitleColor(i == 1 ? .systemRed : (i == 0 ? UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1) : .white), for: .normal)
            b.tag = i
            b.addTarget(self, action: #selector(menu(_:)), for: .touchUpInside)
            m.addSubview(b)
        }
        let y = ball.frame.minY - 140 > 40 ? ball.frame.minY - 140 : ball.frame.maxY + 8
        var x = ball.center.x - 56
        x = min(max(8, x), view.bounds.width - 120)
        m.frame.origin = CGPoint(x: x, y: y)
        view.addSubview(m)
        menu = m
    }

    private func collapse() {
        expanded = false
        menu?.removeFromSuperview()
        menu = nil
    }

    @objc private func menu(_ s: UIButton) {
        collapse()
        switch s.tag {
        case 0: onScan?()
        case 1: onSlim?()
        default: onClose?()
        }
    }
}

struct FloatPiPAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        DispatchQueue.main.async { FloatingBallController.shared.sourceView = v }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        FloatingBallController.shared.sourceView = uiView
    }
}
