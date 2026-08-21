import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    /// 存成字段是必须的: 只是 new 出来的话它立刻被释放, MethodChannel 跟着没,
    /// Dart 那边的调用就石沉大海
    private var scanner: DocScanner?
    private var windowControls: WindowControls?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    /// Flutter 3.27 起 iOS 走 UIScene 生命周期, 引擎不再是在
    /// didFinishLaunching 里现成的 —— 注册通道要挪到这个回调里, 而且
    /// AppDelegate 手上也不再有 window 了(窗口归 SceneDelegate)
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        let messenger = engineBridge.applicationRegistrar.messenger()
        scanner = DocScanner(messenger: messenger)
        windowControls = WindowControls(messenger: messenger)
    }
}
