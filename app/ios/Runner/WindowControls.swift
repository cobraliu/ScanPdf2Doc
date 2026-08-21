import Flutter
import UIKit

/// 左上角那组系统窗口按钮该让出多宽
///
/// iPadOS 26 的窗口模式会在窗口左上角画一组按钮(关闭/最小化/缩放), 它们直接压
/// 在 App 内容上, 却不算进 `safeAreaInsets` —— Flutter 的 `MediaQuery.padding`
/// 走的正是 safeAreaInsets, 于是看不见它们, 返回按钮和标题就这么被盖住
/// (flutter#170461, 上游还没修)。
///
/// Apple 给的量法是 iOS 26 新增的 layout region: 拿"横向让位"的 safeArea region
/// 去问视图要多少边距, 减掉本来的 safeAreaInsets, 差值就是该给这组按钮腾的地方。
/// 全屏时差值是 0, iOS 26 以下没这套 API, 一律当 0 —— 两种情况下这条通道都只会
/// 送出零, Dart 那边照原样排版。
///
/// 原生这侧没有控件可挪 —— 整个界面就是一块 FlutterView, 只能把数字送上去, 由
/// Dart 垫进 AppBar。
final class WindowControls: NSObject {
    static let channel = "scanpdf2doc/window_controls"

    /// 量出来再大也不该有这么宽。API 万一给个荒唐值, 顶栏在所有机器上都会歪,
    /// 这道闸让最坏情况只是"让多了一点", 而不是标题被推出屏幕
    private static let maxInset: CGFloat = 160

    /// 通道和探针都得存住, 否则跟着 init 的临时对象一起被释放
    private var channel: FlutterEventChannel?
    private var sink: FlutterEventSink?
    private var probe: Probe?
    private var activation: NSObjectProtocol?
    /// 上一次报出去的值。拖动窗口时 layoutSubviews 一秒能来几十回, 值没变就不发
    private var last: [String: Double]?

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let ch = FlutterEventChannel(name: Self.channel, binaryMessenger: messenger)
        channel = ch
        ch.setStreamHandler(self)
    }

    /// 借 layoutSubviews 当"版面变了"的钩子
    ///
    /// 贴一块空视图, 铺满窗口, 不收触摸也不画东西。窗口一改大小、一进出窗口模式,
    /// 它就跟着重排一次。比换掉 FlutterViewController 省事(storyboard 里的类不用
    /// 动), 也不用往 FlutterView 的子视图里插东西 —— 那儿的次序是 platform view
    /// 在管的。
    private final class Probe: UIView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    /// 前台那个窗口。注册通道时它还不存在(UIScene 生命周期下窗口归 SceneDelegate),
    /// 所以等 Dart 开始听了再找 —— 那会儿界面已经在屏上了
    private var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }

    /// 只是"变活跃了再试一次"
    ///
    /// `onListen` 是 Dart 第一帧调过来的, 那会儿窗口一般已经有了; 但 UIScene
    /// 生命周期下这个先后没有保证, 万一那时还没有, attach 会悄悄地什么也不做,
    /// 而 layoutSubviews 这个钩子又挂不上去 —— 让位宽度就永远停在 0。所以再挂
    /// 一个"变活跃"的回调补一次。iPad 上从别的窗口切回来也走这儿。
    private func watchActivation() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.attach()
            self?.report()
        }
    }

    private func attach() {
        guard probe == nil, let host = window else { return }
        let p = Probe()
        p.isUserInteractionEnabled = false
        p.backgroundColor = .clear
        p.translatesAutoresizingMaskIntoConstraints = false
        p.onLayout = { [weak self] in self?.report() }
        host.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: host.topAnchor),
            p.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            p.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        probe = p
    }

    private func detach() {
        probe?.removeFromSuperview()
        probe = nil
        last = nil
        if let a = activation {
            NotificationCenter.default.removeObserver(a)
            activation = nil
        }
    }

    /// 量一次, 变了才往上送
    private func report() {
        guard let sink = sink else { return }
        let v = Self.measure(window)
        guard v != last else { return }
        last = v
        sink(v)
    }

    /// 系统按钮占掉的横向宽度, 单位是点
    ///
    /// "横向让位"的 region 减掉 safeAreaInsets, 得到的不止按钮那一份 —— 屏幕和
    /// 窗口的圆角也要让, 实测全屏的 iPad 上左右各 9pt。直接拿这个数去垫, 所有
    /// 机器的顶栏都会平白右移一截。
    ///
    /// 圆角是左右对称的, 而这组按钮只占前面那一个角。再取左右之差, 对称的那份
    /// 就自己消掉了, 剩下的才是按钮真占的地方: 全屏时两边一样, 差是 0, 顶栏一点
    /// 不动; 进了窗口模式, 有按钮那侧多出来的才报上去。
    ///
    /// 只取左右: 竖直方向该让的高度本来就在 safeAreaInsets 里, 再算一遍会把顶栏
    /// 往下顶一截。
    private static func measure(_ view: UIView?) -> [String: Double] {
        guard let view = view else { return ["left": 0, "right": 0] }
        guard #available(iOS 26.0, *) else { return ["left": 0, "right": 0] }
        let region = UIView.LayoutRegion.safeArea(cornerAdaptation: .horizontal)
        let want = view.edgeInsets(for: region)
        let safe = view.safeAreaInsets
        let l = clamp(want.left - safe.left)
        let r = clamp(want.right - safe.right)
        return [
            "left": Double(max(0, l - r)),
            "right": Double(max(0, r - l)),
        ]
    }

    private static func clamp(_ x: CGFloat) -> CGFloat {
        x.isFinite ? min(max(x, 0), maxInset) : 0
    }
}

extension WindowControls: FlutterStreamHandler {
    func onListen(
        withArguments _: Any?, eventSink: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = eventSink
        attach()
        watchActivation()
        // 头一次得主动送: 探针刚贴上, 下一次 layoutSubviews 可能要等到用户去
        // 拖窗口, 在那之前顶栏就一直是盖住的
        report()
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        detach()
        return nil
    }
}
