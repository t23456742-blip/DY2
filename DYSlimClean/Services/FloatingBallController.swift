import UIKit
import AVFoundation
import SwiftUI

enum FloatingAction {
    static let didScan = Notification.Name("dy.slim.float.scan")
    static let didSlim = Notification.Name("dy.slim.float.slim")
    static let visibilityChanged = Notification.Name("dy.slim.float.visibility")
}

/// 小悬浮球：可拖动 · 点开三项 · 后台扫描/清理 · 不用画中画（避免跳出应用）
final class FloatingBallController: NSObject {
    static let shared = FloatingBallController()

    private(set) var isVisible = false
    private var overlayWindow: UIWindow?
    private var audioPlayer: AVAudioPlayer?
    private var savedCenter: CGPoint?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
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
            self.isVisible = false
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: false)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    @objc private func appDidEnterBackground() {
        guard isVisible else { return }
        startKeepAlive()
        // 保持悬浮窗可见，不抢前台、不启动画中画
        overlayWindow?.isHidden = false
    }

    private func presentOverlay() {
        overlayWindow?.isHidden = true
        overlayWindow = nil

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let win: UIWindow = {
            if let scene { return UIWindow(windowScene: scene) }
            return UIWindow(frame: UIScreen.main.bounds)
        }()
        // 盖在本 App 之上；后台时尽量保持（巨魔环境）
        win.windowLevel = .alert + 100
        win.backgroundColor = .clear
        let sel = NSSelectorFromString("setCanBecomeVisibleWithoutActiveApp:")
        if win.responds(to: sel) {
            _ = win.perform(sel, with: true)
        }

        let root = CompactFloatViewController()
        root.initialCenter = savedCenter
        root.onScan = {
            NotificationCenter.default.post(name: FloatingAction.didScan, object: nil)
        }
        root.onClean = {
            NotificationCenter.default.post(name: FloatingAction.didSlim, object: nil)
        }
        root.onToggleFloat = { [weak self] in
            self?.hide()
        }
        win.rootViewController = root
        // 显示但不强制成为 key，减少「跳出/抢焦点」感
        win.isHidden = false
        if !win.isKeyWindow {
            win.makeKeyAndVisible()
            // 立刻把 key 还回去，避免把主界面搞乱
            DispatchQueue.main.async {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: { $0 != win && !$0.isHidden })?
                    .makeKey()
            }
        }
        overlayWindow = win
        UIApplication.shared.isIdleTimerDisabled = true
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

// MARK: - 小图标 + 竖条圆形菜单

final class CompactFloatViewController: UIViewController {
    var onScan: (() -> Void)?
    var onClean: (() -> Void)?
    var onToggleFloat: (() -> Void)?
    var initialCenter: CGPoint?

    private let ballSize: CGFloat = 40
    private let chipSize: CGFloat = 36
    private var ball: UIView!
    private var strip: UIStackView?
    private var statusLabel: UILabel!
    private var expanded = false
    private var didDrag = false

    var ballCenter: CGPoint { ball?.center ?? .zero }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        ball = makeBall()
        view.addSubview(ball)

        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor(white: 0.05, alpha: 0.82)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.heightAnchor.constraint(equalToConstant: 28)
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
        if ball.superview != nil, ball.center == .zero || (ball.center.x < 1 && ball.center.y < 1) {
            if let c = initialCenter, c.x > 1, c.y > 1 {
                ball.center = clamp(c)
            } else {
                ball.center = CGPoint(x: view.bounds.width - 28, y: view.bounds.height * 0.42)
            }
        }
    }

    private func makeBall() -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: ballSize, height: ballSize))
        v.backgroundColor = UIColor(red: 0.07, green: 0.12, blue: 0.2, alpha: 0.92)
        v.layer.cornerRadius = ballSize / 2
        v.layer.borderWidth = 1.5
        v.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1).cgColor
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.25
        v.layer.shadowRadius = 3
        v.layer.shadowOffset = CGSize(width: 0, height: 1)

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
            lab.font = .systemFont(ofSize: 11, weight: .black)
            lab.textColor = .white
            lab.isUserInteractionEnabled = false
            v.addSubview(lab)
        }

        // 拖动；短按无位移则当作点击展开/收起
        v.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        return v
    }

    private func clamp(_ c: CGPoint) -> CGPoint {
        let half = ballSize / 2
        let x = min(max(half + 4, c.x), view.bounds.width - half - 4)
        let y = min(max(half + 4, c.y), view.bounds.height - half - 4)
        return CGPoint(x: x, y: y)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            didDrag = false
            if expanded { collapse() }
        case .changed:
            let t = g.translation(in: view)
            if abs(t.x) + abs(t.y) > 3 { didDrag = true }
            g.setTranslation(.zero, in: view)
            var c = ball.center
            c.x += t.x
            c.y += t.y
            ball.center = clamp(c)
            layoutStrip()
        case .ended, .cancelled:
            if !didDrag {
                tapBall()
            } else {
                // 可贴边，也可停在中间（随意移动）
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
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(roundChip(title: "扫描", color: UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1), action: #selector(doScan)))
        stack.addArrangedSubview(roundChip(title: "清理", color: UIColor(red: 1, green: 0.35, blue: 0.4, alpha: 1), action: #selector(doClean)))
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
        strip.layoutIfNeeded()
        let h = chipSize * 3 + 8 * 2
        let w = chipSize
        // 竖条：优先在球上方，空间不够则下方；左右跟随球，不挡边
        var x = ball.center.x - w / 2
        x = min(max(6, x), view.bounds.width - w - 6)
        let aboveY = ball.frame.minY - h - 10
        let y: CGFloat
        if aboveY > 12 {
            y = aboveY
        } else {
            y = ball.frame.maxY + 10
        }
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
        b.backgroundColor = UIColor(red: 0.1, green: 0.13, blue: 0.18, alpha: 0.95)
        b.layer.cornerRadius = chipSize / 2
        b.layer.borderWidth = 1
        b.layer.borderColor = color.withAlphaComponent(0.85).cgColor
        b.setTitle(title, for: .normal)
        b.setTitleColor(color, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: title.count > 2 ? 8 : 10, weight: .bold)
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

/// 占位（兼容旧调用）；悬浮已不再依赖画中画锚点
struct FloatPiPAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
