import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 出 PDF 时的三个选项
///
/// 跟 [Doc] 一样落成一个 JSON, 不上 shared_preferences —— 就三个字段, 为它多
/// 背一个插件不划算, 而且那东西在 iOS 上写的是 NSUserDefaults, 出问题时不像
/// 一个能直接打开看的文件那么好查。
class PdfOpts {
  const PdfOpts({
    this.size = 'a4',
    this.margin = 0,
    this.maxEdge = 2400,
    this.searchable = false,
  });

  /// `a4` / `letter` / `fit`
  final String size;

  /// 页边距, 单位是点(1/72 英寸); 0 就是不留
  final double margin;

  /// 图的长边压到多少像素, 0 = 原图
  ///
  /// 默认压到 2400: A4 长边 297mm, 2400 像素折合约 205 dpi, 比打印够用的
  /// 150 dpi 还高一档, 而 iPad 后摄拍出来的 4032 像素长边在纸上是看不出差别的
  /// —— 差别只在文件大小上, 一页从 3 MB 掉到 1 MB 左右。
  final int maxEdge;

  /// 出可搜索 PDF: 先把每页认一遍, 再把认出来的字铺成一层看不见的文字
  ///
  /// 默认关着 —— 它要跑一遍完整识别, 一页一两秒, 而多数时候导 PDF 只是想
  /// 把几张纸发出去。真需要"能搜"的人自己会去开。
  final bool searchable;

  PdfOpts copyWith(
          {String? size, double? margin, int? maxEdge, bool? searchable}) =>
      PdfOpts(
        size: size ?? this.size,
        margin: margin ?? this.margin,
        maxEdge: maxEdge ?? this.maxEdge,
        searchable: searchable ?? this.searchable,
      );

  Map<String, dynamic> toJson() => {
        'size': size,
        'margin': margin,
        'maxEdge': maxEdge,
        'searchable': searchable,
      };

  static PdfOpts fromJson(Map<String, dynamic> m) => PdfOpts(
        size: m['size'] as String? ?? 'a4',
        margin: (m['margin'] as num?)?.toDouble() ?? 0,
        maxEdge: m['maxEdge'] as int? ?? 2400,
        searchable: m['searchable'] as bool? ?? false,
      );

  String get sizeLabel => switch (size) {
        'letter' => 'Letter',
        'fit' => '贴合原图',
        _ => 'A4',
      };

  String get marginLabel => switch (margin) {
        0 => '无边距',
        <= 24 => '窄边距',
        _ => '常规边距',
      };

  String get qualityLabel => switch (maxEdge) {
        0 => '原图画质',
        <= 1600 => '省空间',
        _ => '高画质',
      };

  /// 一行摘要, 导完给用户回一句"刚才出的是什么"
  String get summary =>
      '$sizeLabel · $marginLabel · $qualityLabel${searchable ? ' · 可搜索' : ''}';
}

/// 全局设置, 存在 Application Support/settings.json
///
/// 读一次就缓存在内存里: 每次导出都去碰一次磁盘没必要, 而且这个文件只有本
/// App 会写。
class Settings {
  static PdfOpts? _pdf;

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}/settings.json');
  }

  static Future<PdfOpts> pdf() async {
    if (_pdf != null) return _pdf!;
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _pdf = PdfOpts.fromJson((m['pdf'] as Map).cast<String, dynamic>());
      }
    } catch (_) {
      // 文件坏了就当没设置过 —— 一个读不出来的配置不该让人导不了 PDF
    }
    return _pdf ??= const PdfOpts();
  }

  static Future<void> setPdf(PdfOpts v) async {
    _pdf = v;
    try {
      final f = await _file();
      final t = File('${f.path}.tmp');
      await t.writeAsString(jsonEncode({'pdf': v.toJson()}), flush: true);
      await t.rename(f.path);
    } catch (_) {
      // 存不下就只在这次运行里生效, 不值得打断导出
    }
  }
}
