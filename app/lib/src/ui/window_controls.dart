import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 系统窗口按钮压住的那一块
///
/// iPadOS 26 的窗口模式会在窗口左上角画一组按钮(关闭/最小化/缩放), 直接压在
/// App 内容上, 又不算进 safe area —— `MediaQuery.padding` 看不见它们, 顶栏的
/// 返回按钮和标题就这么被盖住(flutter#170461, 上游还没修)。原生那侧按 Apple 的
/// layout region 量出该让多少, 从 `scanpdf2doc/window_controls` 送过来。
///
/// 全屏、iOS 26 以下、以及非 iOS 平台一律是零, 这条路等于不存在。
class WindowControls extends StatefulWidget {
  const WindowControls({super.key, required this.child});

  final Widget child;

  /// 顶栏该让开多少。没人提供过就是零 —— 找不到就当没有, 不要在这儿抛
  static EdgeInsets of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Insets>()?.insets ??
      EdgeInsets.zero;

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> {
  static const _ch = EventChannel('scanpdf2doc/window_controls');

  EdgeInsets _v = EdgeInsets.zero;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    // 只有 iOS 那侧接了这个通道。别的平台上订阅会一直等不到应答
    if (!Platform.isIOS) return;
    // 出错就按零走: 顶栏挤一点总比整个 App 起不来好
    _sub = _ch.receiveBroadcastStream().listen(_take, onError: (Object _) {});
  }

  void _take(dynamic e) {
    if (e is! Map) return;
    final v = EdgeInsets.only(
      left: (e['left'] as num?)?.toDouble() ?? 0,
      right: (e['right'] as num?)?.toDouble() ?? 0,
    );
    if (v != _v) setState(() => _v = v);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _Insets(insets: _v, child: widget.child);
}

class _Insets extends InheritedWidget {
  const _Insets({required this.insets, required super.child});

  final EdgeInsets insets;

  @override
  bool updateShouldNotify(_Insets old) => old.insets != insets;
}

/// 顶栏, 给左上角的系统窗口按钮让开地方
///
/// AppBar 内部本来就套了一层 SafeArea, 把量到的宽度垫进 `padding.left`, 返回
/// 按钮和标题就会一起右移, 而背景照旧铺满整条 —— 比逐个去调 leadingWidth 和
/// titleSpacing 省事, 也不会漏掉 leading 为空、标题顶在最左边的那几屏。
///
/// 只垫顶栏, 正文的左边界不动: 那组按钮只占顶上一个角, 把整条左边界推进去,
/// 列表在窄窗口里会白白瘦一截。
class SysBar extends StatelessWidget implements PreferredSizeWidget {
  const SysBar(this.bar, {super.key});

  final PreferredSizeWidget bar;

  @override
  Size get preferredSize => bar.preferredSize;

  @override
  Widget build(BuildContext context) {
    final add = WindowControls.of(context);
    if (add == EdgeInsets.zero) return bar;
    final m = MediaQuery.of(context);
    return MediaQuery(
      data: m.copyWith(
        padding: m.padding.copyWith(
          left: m.padding.left + add.left,
          right: m.padding.right + add.right,
        ),
      ),
      child: bar,
    );
  }
}
