import 'package:flutter/services.dart' show PlatformException;

import '../../l10n/l10n.dart';

/// 把一个异常翻成给用户看的一句话
///
/// 原生(Swift)和 Rust 那两侧的错误信息一律是中文, 而且不打算跟着界面语言走 ——
/// 它们是诊断, 是给我们排查用的, 用户撞上其中任何一条的概率都很低。为这些
/// 分支在 Swift 和 Rust 里各再搭一套 l10n, 换来的是几乎没人看到的几十句话。
///
/// 所以这里做两件事:
///
/// - 会被正常撞上的那几条(比如 iOS 15 上点「自动增强」)按错误码换成本地化的
///   说法 —— 那不是故障, 是这台设备本来就没这个能力, 该好好说清楚;
/// - 其余的套一句"出错了", 把原文照抄在后面。德语用户至少知道这是一次失败,
///   而不是界面卡住了; 截图发过来我们也还认得出是哪一条。
String humanError(L l, Object e) {
  if (e is PlatformException && e.code == 'os_too_old') return l.enhanceTooOld;
  return l.errorGeneric('$e');
}
