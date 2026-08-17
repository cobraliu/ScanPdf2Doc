import 'dart:io';

import 'package:flutter/material.dart';

/// 全 App 的主题和几个反复用到的尺寸
///
/// 单独开一份是因为原先这些值是散在各个界面里现写的: 缩略图在文档列表是
/// 48×62、在页列表是 56×74, 圆角一处 4 一处 12, 间距 8/12/16 混着来。单看
/// 每一处都没错, 连起来就是"这个 App 没设计过"的那种感觉。
class Ui {
  /// 主色。文档工具用蓝, 取的是"可靠、中性、不抢内容"那一路 —— 页面上真正
  /// 该被看见的是扫出来的纸, 不是控件
  static const seed = Color(0xFF2F6FED);

  /// 间距只用这几档, 4 的倍数
  static const gapXs = 4.0;
  static const gapSm = 8.0;
  static const gap = 12.0;
  static const gapMd = 16.0;
  static const gapLg = 24.0;

  /// 页面缩略图: 3:4 近似 A4 的比例, 两个列表用同一组
  static const thumbW = 52.0;
  static const thumbH = 69.0;
  static const thumbRadius = 6.0;

  /// 苹果的最小可点尺寸。图标本身小于它时, 要把命中区撑到这么大
  static const tap = 44.0;

  /// iPad 上正文列表的最大宽度
  ///
  /// 不限宽的话, 一行"文档名 …… 3 页 · 2 天前 …… ⋮"会横跨 820pt(竖屏)甚至
  /// 1180pt(横屏), 名字和菜单之间空出一大片, 眼睛要跑很远才对得上。
  /// 手机上这个值够不着, 等于没有限制。
  static const readable = 720.0;

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // 不指定字体族: 中文得靠系统的苹方/思源, 硬塞一款拉丁字体的结果是
      // 西文用它、中文 fallback 回系统字体, 一句话里两套设计的字混着排
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: EdgeInsets.all(gapMd),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: gapMd, vertical: gapSm),
      ),
    );
  }
}

/// 把内容夹在屏幕中间并限宽
///
/// iPad 上直接铺满整屏的列表读起来很累(见 [Ui.readable])
class Readable extends StatelessWidget {
  const Readable({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Ui.readable),
        child: child,
      ),
    );
  }
}

/// 空白页面上的那段引导
///
/// 光写一句"还没有页"是不够的 —— 用户站在这里需要知道下一步点哪。所以图标、
/// 一句说明、一个能直接点的按钮, 三样都给。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Ui.gapLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: t.colorScheme.outlineVariant),
            const SizedBox(height: Ui.gapMd),
            Text(title, style: t.textTheme.titleMedium),
            const SizedBox(height: Ui.gapSm),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall
                  ?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Ui.gapLg),
              FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 页面缩略图, 两个列表共用
///
/// `cacheWidth` 不能省: 不给的话每张图都会把整张四千像素的照片解成位图放进
/// 内存, 二十页就是几百 MB。给的是显示宽度的三倍左右, 够 3x 屏清晰。
class PageThumb extends StatelessWidget {
  const PageThumb({super.key, this.path, this.width, this.height});

  final String? path;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final w = width ?? Ui.thumbW;
    final h = height ?? Ui.thumbH;
    final t = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(Ui.thumbRadius),
      child: SizedBox(
        width: w,
        height: h,
        child: path == null
            ? ColoredBox(
                color: t.colorScheme.surfaceContainerHighest,
                child: Icon(Icons.description_outlined,
                    size: 20, color: t.colorScheme.outline),
              )
            : Image.file(
                File(path!),
                fit: BoxFit.cover,
                cacheWidth: (w * 3).round(),
                errorBuilder: (_, _, _) => ColoredBox(
                  color: t.colorScheme.surfaceContainerHighest,
                  child: Icon(Icons.broken_image_outlined,
                      size: 20, color: t.colorScheme.outline),
                ),
              ),
      ),
    );
  }
}
