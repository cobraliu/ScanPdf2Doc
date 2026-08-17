import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import 'native.dart';
import 'settings.dart';

/// 一种识别语言
///
/// 识别这一步认得出哪些字, 完全由 rec 那个 .onnx 决定 —— 字表是转 onnx 时
/// 塞进模型 metadata 里的, 换个文件就换了一整套字。检测(框在哪)和方向分类
/// (正着还是倒着)跟语言无关, 它们只看笔画怎么分布, 不认字。
///
/// 所以一个"语言包"就是一个 rec 文件, 没有别的。
class OcrLang {
  const OcrLang({
    required this.code,
    required this.file,
    this.remote,
    this.bytes = 0,
    this.sha = '',
  });

  /// 存进设置里的键, 也是查名字用的
  final String code;

  /// rec 模型文件名; Rust 那侧拿它跟模型目录拼出完整路径
  final String file;

  /// 在 ModelScope 仓库里的路径; null = 内置在 App 包里, 不用下
  final String? remote;

  /// 文件应有的字节数
  final int bytes;

  /// 文件应有的 sha256
  final String sha;

  bool get builtin => remote == null;

  /// 下载地址
  ///
  /// 钉死在 v3.9.2 这个 tag 上, 不用 master —— 上游哪天换了模型, 我们这边
  /// 的 sha256 会全部对不上, 而那时候用户看到的只是"下载失败", 查起来很远。
  /// 钉住之后上游怎么动都跟已经装出去的版本无关。
  String get url => 'https://www.modelscope.cn/models/RapidAI/RapidOCR'
      '/resolve/v3.9.2/onnx/$remote';

  /// 界面上叫什么
  ///
  /// 收 L 而不是在表里写死: 这几个名字是给用户读的, 得跟界面语言走
  String name(L l) => switch (code) {
        'ko' => l.ocrLangKo,
        'ja' => l.ocrLangJa,
        'ru' => l.ocrLangRu,
        'ar' => l.ocrLangAr,
        'th' => l.ocrLangTh,
        'hi' => l.ocrLangHi,
        _ => l.ocrLangBuiltin,
      };

  /// 下面那行小字: 这个包能干什么、什么时候该选它
  String note(L l) => switch (code) {
        'ko' => l.ocrLangKoNote,
        'ja' => l.ocrLangJaNote,
        'ru' => l.ocrLangRuNote,
        'ar' => l.ocrLangArNote,
        'th' => l.ocrLangThNote,
        'hi' => l.ocrLangHiNote,
        _ => l.ocrLangBuiltinNote,
      };

  /// "13.5 MB"
  String get size => '${(bytes / 1000000).toStringAsFixed(1)} MB';
}

/// 内置的那套 + 能下的那几个
///
/// 内置模型的字表实测覆盖: 简繁汉字、日文假名、拉丁字母(含 ä ö ü ß ñ á é
/// 这些重音)、希腊字母。**一个字都不覆盖**: 谚文、西里尔、阿拉伯、泰文、
/// 天城文。所以前五个包是"从不认到认"; 日语那个不是, 它排在最后, 理由见
/// 那一条上面的注释。
///
/// 一次只能装一套字进去。实测(同一张韩文样张):
///
/// - 内置 -> 三行只吐出一个 `02`
/// - 韩语包 -> 三行全对, 置信度 0.98~1.00
///
/// 反过来拿韩语包认中文样张, 三行汉字全丢, 只剩 `3` 和 `2026` 两个数字。
/// 这不是我们的取舍, 是 CTC 识别头就一个输出维度, 一个模型一张字表。
const _langs = <OcrLang>[
  OcrLang(code: '', file: 'PP-OCRv6_rec_small.onnx'),
  OcrLang(
    code: 'ko',
    file: 'korean_PP-OCRv5_rec_mobile.onnx',
    remote: 'PP-OCRv5/rec/korean_PP-OCRv5_rec_mobile.onnx',
    bytes: 13488748,
    sha: 'cd6e2ea50f6943ca7271eb8c56a877a5a90720b7047fe9c41a2e541a25773c9b',
  ),
  OcrLang(
    code: 'ru',
    file: 'cyrillic_PP-OCRv5_rec_mobile.onnx',
    remote: 'PP-OCRv5/rec/cyrillic_PP-OCRv5_rec_mobile.onnx',
    bytes: 8074092,
    sha: '90f761b4bfcce0c8c561c0cb5c887b0971d3ec01c32164bdf7374a35b0982711',
  ),
  OcrLang(
    code: 'ar',
    file: 'arabic_PP-OCRv5_rec_mobile.onnx',
    remote: 'PP-OCRv5/rec/arabic_PP-OCRv5_rec_mobile.onnx',
    bytes: 8023828,
    sha: 'c1192e632d0baa9146ae5b756a0e635e3dc63c1733737ebfd1629e87144e9295',
  ),
  OcrLang(
    code: 'th',
    file: 'th_PP-OCRv5_rec_mobile.onnx',
    remote: 'PP-OCRv5/rec/th_PP-OCRv5_rec_mobile.onnx',
    bytes: 7915294,
    sha: 'de541dd83161c241ff426f7ecfd602a0ba77d686cf3ab9a6c255ea82fd08006e',
  ),
  OcrLang(
    code: 'hi',
    file: 'devanagari_PP-OCRv5_rec_mobile.onnx',
    remote: 'PP-OCRv5/rec/devanagari_PP-OCRv5_rec_mobile.onnx',
    bytes: 7940361,
    sha: 'd6f0a906580e3fa6b324a318718f1f31f268b6ea8ef985f91c2012a37f52c91e',
  ),
  // 排在最后, 因为它跟上面五个不是一回事: 内置那个本来就认假名和汉字。
  // 拿一张清晰的日文样张实测, 两边都是三行全对, 内置给的还是半角的 3,
  // 日语包给的是全角 ３ —— 落进 docx 反倒是前者更顺手。留着它是因为
  // 拍糊的、字体怪的日文件上专门训过的那个也许还是有用, 但那个"也许"
  // 我们没量到, 所以界面上那行小字写的是"只有内置认不好时才需要它"
  OcrLang(
    code: 'ja',
    file: 'japan_PP-OCRv4_rec_mobile.onnx',
    // 日语只有 v4, 上游没出 v5 的。v4 的输入高度也是动态的, 跟我们写死的
    // 48 对得上 —— v3 那批是 32, 喂 48 进去直接报维度不符, 所以不能用
    remote: 'PP-OCRv4/rec/japan_PP-OCRv4_rec_mobile.onnx',
    bytes: 9753335,
    sha: 'e1075a67dba758ecfc7ebc78a10ae61c95ac8fb66a9c86fab5541e33f085cb7a',
  ),
];

/// 这次识别用哪个目录、哪个 rec 文件
///
/// 三个调用点(转文档、提取文字、可搜索 PDF)拿到的必须是同一个答案 ——
/// 同一份文件在三个地方认出不一样的字, 没法跟用户解释
class OcrSetup {
  const OcrSetup(this.dir, this.recFile);

  final String dir;

  /// null = 用内置那个
  final String? recFile;
}

/// 模型的落盘、下载、删除
///
/// 三个内置模型跟着 App 包走, 第一次用的时候解到 Application Support/models;
/// 语言包下到同一个目录里 —— Rust 那侧只认一个模型目录。
class Models {
  static const _builtin = [
    'PP-OCRv6_det_small.onnx',
    'PP-OCRv6_rec_small.onnx',
    'ch_ppocr_mobile_v2.0_cls_mobile.onnx',
  ];

  static String? _dir;
  static bool _unpacked = false;

  /// 能选的语言, 内置那个排在最前
  static List<OcrLang> get langs => _langs;

  static OcrLang byCode(String code) =>
      _langs.firstWhere((e) => e.code == code, orElse: () => _langs.first);

  /// 模型目录, 只保证目录在, 不管里面有什么
  ///
  /// 跟 [ensure] 分开是因为"这个语言包下了没"和"下载存到哪"都只要一个路径。
  /// 走 ensure 的话, 光是打开一次设置页就要把 31 MB 的内置模型从 App 包里
  /// 解出来 —— 那是识别第一次真跑的时候才该付的钱。
  static Future<String> _path() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/models');
    await dir.create(recursive: true);
    // 标在目录上, 后面下进来的语言包跟着一起算。每次都标一遍是因为这是个
    // 属性不是个状态, 重设一次几乎不要钱, 而漏标一次就是几十兆进 iCloud
    await Native.excludeFromBackup(dir.path);
    _dir = dir.path;
    return dir.path;
  }

  /// 确保三个内置模型在位, 返回模型目录
  static Future<String> ensure() async {
    final dir = Directory(await _path());
    if (_unpacked) return dir.path;
    for (final name in _builtin) {
      final f = File('${dir.path}/$name');
      final data = await rootBundle.load('assets/models/$name');
      // 按字节数判等而不是只看存在: 上一次解到一半被杀掉, 留下的半个文件
      // 照样"存在", 而 ONNX 那侧读到的会是一句难懂的报错
      if (await f.exists() && await f.length() == data.lengthInBytes) continue;
      await f.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true);
    }
    _unpacked = true;
    return dir.path;
  }

  /// 这个语言包下好了没
  static Future<bool> installed(OcrLang lang) async {
    if (lang.builtin) return true;
    final dir = await _path();
    final f = File('$dir/${lang.file}');
    return await f.exists() && await f.length() == lang.bytes;
  }

  /// 识别该按哪个语言跑
  ///
  /// 选的包要是不在了就退回内置 —— 这不是假想的情况: 模型目录被我们标成了
  /// 不备份, 所以从 iCloud 恢复出来的新设备上, 设置里写着"韩语"而文件是没有
  /// 的。那时候用内置的认一遍(认出来的字不对)也好过直接报错跑不动。
  static Future<OcrSetup> setup() async {
    final dir = await ensure();
    final lang = byCode(Settings.ocrLang.value);
    if (lang.builtin) return OcrSetup(dir, null);
    return await installed(lang)
        ? OcrSetup(dir, lang.file)
        : OcrSetup(dir, null);
  }

  /// 下载一个语言包, 边下边报进度(0..1)
  ///
  /// 先下到 `.part` 再改名: 下到一半被杀掉的话, 留在磁盘上的是个 .part,
  /// 而不是一个大小对不上的模型文件 —— 后者会被下一次 [installed] 当成
  /// "没下全"重下, 前者则连问都不用问。改名在同一个目录里, 是原子的。
  static Stream<double> download(OcrLang lang) async* {
    final dir = await _path();
    final dst = File('$dir/${lang.file}');
    final part = File('${dst.path}.part');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final res = await client.getUrl(Uri.parse(lang.url)).then((r) => r.close());
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(lang.url));
      }
      final sink = part.openWrite();
      var got = 0;
      // 上一次报到百分之几。每来一个包就 yield 一次的话, 一个 13 MB 的文件
      // 要触发上千次 setState —— 进度条根本画不出这个精度
      var last = -1;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          final pct = (got * 100 ~/ lang.bytes).clamp(0, 100);
          if (pct != last) {
            last = pct;
            yield pct / 100;
          }
        }
      } finally {
        await sink.close();
      }

      final n = await part.length();
      if (n != lang.bytes) {
        await part.delete();
        throw HttpException('下载不完整: $n / ${lang.bytes} 字节');
      }
      // 校验哈希。HTTPS 加上字节数对得上, 已经挡掉了绝大多数情况; 留这一道
      // 是因为剩下那种最难查 —— 一个内容不对的模型不会报错, 它照样跑, 只是
      // 认出来的每个字都是错的
      final h = sha256.convert(await part.readAsBytes()).toString();
      if (h != lang.sha) {
        await part.delete();
        throw HttpException('文件校验不过: $h');
      }
      await part.rename(dst.path);
    } finally {
      client.close(force: true);
    }
  }

  /// 删掉一个语言包
  static Future<void> remove(OcrLang lang) async {
    if (lang.builtin) return;
    final dir = await _path();
    for (final p in ['$dir/${lang.file}', '$dir/${lang.file}.part']) {
      final f = File(p);
      if (await f.exists()) await f.delete();
    }
    // 正在用的那个被删了就退回内置, 不然下次识别会走 setup() 的兜底 ——
    // 兜底是给意外准备的, 用户明说要删的时候该当场把设置改对
    if (Settings.ocrLang.value == lang.code) await Settings.setOcrLang('');
  }
}
