import UIKit

enum FloatingAction {
    static let didScan = Notification.Name("dy.slim.float.scan")
    static let didSlim = Notification.Name("dy.slim.float.slim")
    static let visibilityChanged = Notification.Name("dy.slim.float.visibility")
}

/// 可拖动悬浮球（巨魔高 windowLevel），点击展开：扫描 / 瘦身
final class FloatingBallController: NSObject {
    static let shared = FloatingBallController()

    private(set) var isVisible = false
    private var window: UIWindow?
    private var ballView: UIView?
    private var menuView: UIView?
    private var menuExpanded = false
    private let ballSize: CGFloat = 58
    private var savedCenter: CGPoint?

    private override init() {
        super.init()
    }

    func show() {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.window?.isHidden = false
            self.isVisible = true
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: true)
            self.collapseMenu()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.collapseMenu()
            self.window?.isHidden = true
            self.isVisible = false
            NotificationCenter.default.post(name: FloatingAction.visibilityChanged, object: false)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    private func ensureWindow() {
        if window != nil { return }

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let win: UIWindow
        if let scene {
            win = UIWindow(windowScene: scene)
        } else {
            win = UIWindow(frame: UIScreen.main.bounds)
        }
        win.windowLevel = UIWindow.Level.statusBar + 120
        win.backgroundColor = .clear
        win.isUserInteractionEnabled = true

        let root = UIViewController()
        root.view.backgroundColor = .clear
        win.rootViewController = root

        let ball = makeBall()
        let screen = win.bounds
        let margin: CGFloat = 16
        let defaultCenter = CGPoint(
            x: screen.width - ballSize / 2 - margin,
            y: screen.height * 0.55
        )
        ball.center = savedCenter ?? defaultCenter
        root.view.addSubview(ball)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        ball.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        ball.addGestureRecognizer(tap)

        self.ballView = ball
        self.window = win
        win.isHidden = false
    }

    private func makeBall() -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: ballSize, height: ballSize))
        v.backgroundColor = UIColor(red: 0.06, green: 0.12, blue: 0.22, alpha: 0.95)
        v.layer.cornerRadius = ballSize / 2
        v.layer.borderWidth = 1.5
        v.layer.borderColor = UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 0.9).cgColor
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.35
        v.layer.shadowRadius = 8
        v.layer.shadowOffset = CGSize(width: 0, height: 3)

        let iv = UIImageView(frame: v.bounds.insetBy(dx: 6, dy: 6))
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = (ballSize - 12) / 2
        if let img = UIImage(named: "FloatIcon") {
            iv.image = img
        } else {
            // 文字兜底
            let label = UILabel(frame: v.bounds)
            label.numberOfLines = 2
            label.textAlignment = .center
            label.text = "DY\n瘦身"
            label.font = .systemFont(ofSize: 11, weight: .black)
            label.textColor = .white
            v.addSubview(label)
        }
        v.addSubview(iv)
        return v
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let ball = ballView, let host = ball.superview else { return }
        if menuExpanded { collapseMenu() }
        let t = g.translation(in: host)
        g.setTranslation(.zero, in: host)
        var c = ball.center
        c.x += t.x
        c.y += t.y
        let half = ballSize / 2
        let b = host.bounds.insetBy(dx: half + 4, dy: half + 4)
        c.x = min(max(c.x, b.minX), b.maxX)
        c.y = min(max(c.y, b.minY), b.maxY)
        ball.center = c
        if g.state == .ended || g.state == .cancelled {
            savedCenter = c
            snapToEdge()
        }
    }

    private func snapToEdge() {
        guard let ball = ballView, let host = ball.superview else { return }
        let mid = host.bounds.midX
        let half = ballSize / 2
        let margin: CGFloat = 10
        let targetX = ball.center.x < mid ? (half + margin) : (host.bounds.width - half - margin)
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            ball.center.x = targetX
            self.savedCenter = ball.center
        }
    }

    @objc private func handleTap() {
        if menuExpanded {
            collapseMenu()
        } else {
            expandMenu()
        }
    }

    private func expandMenu() {
        guard let ball = ballView, let host = ball.superview, menuView == nil else { return }
        menuExpanded = true

        let menu = UIView()
        menu.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 0.96)
        menu.layer.cornerRadius = 14
        menu.layer.borderWidth = 1
        menu.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        menu.clipsToBounds = true

        let titles = ["扫描", "瘦身", "关闭悬浮"]
        let colors: [UIColor] = [
            UIColor(red: 0.15, green: 0.85, blue: 0.78, alpha: 1),
            UIColor(red: 1.0, green: 0.35, blue: 0.40, alpha: 1),
            UIColor.white.withAlphaComponent(0.7)
        ]
        let h: CGFloat = 44
        let w: CGFloat = 112
        menu.frame = CGRect(x: 0, y: 0, width: w, height: h * CGFloat(titles.count))

        for (i, title) in titles.enumerated() {
            let btn = UIButton(type: .system)
            btn.frame = CGRect(x: 0, y: CGFloat(i) * h, width: w, height: h)
            btn.setTitle(title, for: .normal)
            btn.setTitleColor(colors[i], for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            btn.tag = i
            btn.addTarget(self, action: #selector(menuTapped(_:)), for: .touchUpInside)
            menu.addSubview(btn)
            if i < titles.count - 1 {
                let line = UIView(frame: CGRect(x: 10, y: h * CGFloat(i + 1) - 0.5, width: w - 20, height: 0.5))
                line.backgroundColor = UIColor.white.withAlphaComponent(0.1)
                menu.addSubview(line)
            }
        }

        // 优先显示在球上方，空间不够则下方
        let aboveY = ball.frame.minY - menu.bounds.height - 8
        let y = aboveY > 40 ? aboveY : ball.frame.maxY + 8
        var x = ball.center.x - w / 2
        x = min(max(8, x), host.bounds.width - w - 8)
        menu.frame.origin = CGPoint(x: x, y: y)
        menu.alpha = 0
        menu.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        host.addSubview(menu)
        menuView = menu
        UIView.animate(withDuration: 0.18) {
            menu.alpha = 1
            menu.transform = .identity
        }
    }

    private func collapseMenu() {
        menuExpanded = false
        guard let menu = menuView else { return }
        UIView.animate(withDuration: 0.15, animations: {
            menu.alpha = 0
            menu.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }, completion: { _ in
            menu.removeFromSuperview()
        })
        menuView = nil
    }

    @objc private func menuTapped(_ sender: UIButton) {
        collapseMenu()
        switch sender.tag {
        case 0:
            flashToast("正在扫描…")
            NotificationCenter.default.post(name: FloatingAction.didScan, object: nil)
        case 1:
            flashToast("开始瘦身…")
            NotificationCenter.default.post(name: FloatingAction.didSlim, object: nil)
        default:
            hide()
        }
    }

    private func flashToast(_ text: String) {
        guard let host = window?.rootViewController?.view else { return }
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        let size = label.sizeThatFits(CGSize(width: 200, height: 40))
        label.frame = CGRect(x: 0, y: 0, width: max(120, size.width + 24), height: 34)
        label.center = CGPoint(x: host.bounds.midX, y: host.bounds.height * 0.2)
        host.addSubview(label)
        UIView.animate(withDuration: 0.25, delay: 1.0, options: [], animations: {
            label.alpha = 0
        }, completion: { _ in label.removeFromSuperview() })
    }
}
