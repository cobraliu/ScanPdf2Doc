import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';

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

  // 三个挡位的名字要收 L 而不是当 getter: 它们最后会拼进导出成功那句提示,
  // 而那句是给用户看的 —— 界面切到日文之后还回一句"A4 · 无边距"就露馅了
  String sizeLabel(L l) => switch (size) {
        'letter' => 'Letter',
        'fit' => l.exportSizeFit,
        _ => 'A4',
      };

  String marginLabel(L l) => switch (margin) {
        0 => l.exportMarginNoneLabel,
        <= 24 => l.exportMarginNarrowLabel,
        _ => l.exportMarginNormalLabel,
      };

  String qualityLabel(L l) => switch (maxEdge) {
        0 => l.exportQualityOriginalLabel,
        <= 1600 => l.exportQualitySmallLabel,
        _ => l.exportQualityHighLabel,
      };

  /// 一行摘要, 导完给用户回一句"刚才出的是什么"
  String summary(L l) => '${sizeLabel(l)} · ${marginLabel(l)} · ${qualityLabel(l)}'
      '${searchable ? ' · ${l.exportSearchableTag}' : ''}';
}

/// 全局设置, 存在 Application Support/settings.json
///
/// 读一次就缓存在内存里: 每次导出都去碰一次磁盘没必要, 而且这个文件只有本
/// App 会写。
class Settings {
  static PdfOpts _pdf = const PdfOpts();

  /// 用户挑的界面语言; null = 跟随系统
  ///
  /// 用 ValueNotifier 而不是让首页 setState: 改语言要让整个 MaterialApp 重建,
  /// 而 MaterialApp 在首页的上面 —— 首页 setState 到不了它。
  static final locale = ValueNotifier<Locale?>(null);

  /// 识别语言, 存的是 [OcrLang.code]; 空串 = 内置那个中英混排的
  ///
  /// 跟界面语言是两件事, 所以分开存: 一个韩国用户可能把界面设成韩语, 却
  /// 整天在扫中文合同。也用 ValueNotifier —— 设置页改完之后, 上一层那行
  /// "当前: 韩语"要跟着变。
  static final ocrLang = ValueNotifier<String>('');

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}/settings.json');
  }

  /// 开机读一次。放在 runApp 前 —— 晚一步的话第一帧会拿系统语言画出来,
  /// 然后当着用户的面闪一下换成他选的那种
  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final p = m['pdf'];
      if (p is Map) _pdf = PdfOpts.fromJson(p.cast<String, dynamic>());
      final t = m['locale'];
      if (t is String && t.isNotEmpty) locale.value = _parse(t);
      final o = m['ocrLang'];
      if (o is String) ocrLang.value = o;
    } catch (_) {
      // 文件坏了就当没设置过 —— 一个读不出来的配置不该让人导不了 PDF
    }
  }

  static Future<PdfOpts> pdf() async => _pdf;

  static Future<void> setPdf(PdfOpts v) async {
    _pdf = v;
    await _save();
  }

  /// null = 跟随系统
  static Future<void> setLocale(Locale? v) async {
    locale.value = v;
    await _save();
  }

  /// 空串 = 内置那个
  static Future<void> setOcrLang(String v) async {
    ocrLang.value = v;
    await _save();
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      final t = File('${f.path}.tmp');
      await t.writeAsString(
          jsonEncode({
            'pdf': _pdf.toJson(),
            'locale': _tag(locale.value),
            'ocrLang': ocrLang.value,
          }),
          flush: true);
      await t.rename(f.path);
    } catch (_) {
      // 存不下就只在这次运行里生效, 不值得打断导出
    }
  }

  /// 存成 BCP 47 那一套(`zh-Hant`), 不是 Dart 的 `toString()`(`zh_Hant`)
  static String _tag(Locale? l) => l == null
      ? ''
      : [l.languageCode, ?l.scriptCode, ?l.countryCode].join('-');

  static Locale? _parse(String s) {
    final p = s.split(RegExp('[-_]'));
    if (p.isEmpty || p.first.isEmpty) return null;
    return Locale.fromSubtags(
      languageCode: p.first,
      // 脚本码是四位且首字母大写(Hant/Hans), 地区码是两位全大写 —— 靠长度
      // 就能分开, 不用再引一个 BCP 47 的解析库
      scriptCode: p.length > 1 && p[1].length == 4 ? p[1] : null,
      countryCode: p.length > 1 && p.last.length == 2 ? p.last : null,
    );
  }
}
