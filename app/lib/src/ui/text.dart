import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../doc.dart' show stamp;
import '../models.dart';
import '../rust/api/textlayer.dart';
import 'errors.dart';
import 'theme.dart';
import 'window_controls.dart';

/// 跑到哪一步了。存这个而不是存拼好的那句话 —— 那句要在 build 里翻
enum _Stage { prep, downloading, loading, page }

/// 提取文字: 把每一页认出来的字摊开, 能看、能选、能复制、能导成 txt
///
/// 跟「转文档」是两件事。那边出的是 Word, 带版式、表格、段落合并 —— 要的是
/// 一份能接着编辑的文件。这边只要字本身: 抄一个身份证号、把一段条款贴进
/// 微信、拿合同里的一句话去搜。为这个去开一次 Word 是绕远路。
///
/// 走的是 `api::textlayer` 那条流水线, 跟「可搜索 PDF」同一条 —— 那条只出
/// 每行字和它的坐标, 不做版面重建, 正好是这里要的。
class TextPage extends StatefulWidget {
  const TextPage({super.key, required this.pages, this.title});

  final List<String> pages;
  final String? title;

  @override
  State<TextPage> createState() => _TextPageState();
}

class _TextPageState extends State<TextPage> {
  bool _running = false;
  _Stage? _stage;
  int _at = 0, _of = 0;
  double? _frac;
  /// 正在下的那个语言包叫什么; 只在 _Stage.downloading 时有意义
  String _pack = '';
  Object? _error;

  /// 每页一段文字, 页序跟传进来的一致; null 表示还没跑
  List<String>? _out;

  @override
  void initState() {
    super.initState();
    // 进来就开跑。这个页面只有这一件事可做, 先摆一个「开始」按钮等人点,
    // 是白白多要一下 —— 用户点进来时就已经表达过意图了
    _run();
  }

  /// 语言包的名字要走 L, 而 L 在 initState 里还够不着(它是 InheritedWidget)
  ///
  /// 放这儿正好: initState 里的 _run() 一进 await 就把控制权交回来了, 这个
  /// 回调跑在那之后、第一次 build 之前, 等下载进度真的开始报时它已经填好了
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pack = Models.current.name(L.of(context));
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
      _out = null;
      _stage = _Stage.prep;
      _frac = null;
    });
    try {
      final ocr = await Models.prepare(onDownload: (p) {
        if (!mounted) return;
        setState(() {
          _stage = _Stage.downloading;
          _frac = p;
        });
      });
      await for (final p in ocrImages(
        modelDir: ocr.dir,
        images: widget.pages,
        // 跟另外两条路同一个值。同一份文件在三个地方认出不一样的字, 没法解释
        longEdge: 2560,
        lowMemory: true,
        recFile: ocr.recFile,
      )) {
        if (!mounted) return;
        switch (p) {
          case OcrProgress_Loading():
            setState(() {
              _stage = _Stage.loading;
              _frac = null;
            });
          case OcrProgress_Page(:final index, :final total):
            setState(() {
              _stage = _Stage.page;
              _at = index;
              _of = total;
              _frac = index / total;
            });
          case OcrProgress_Done(:final pages):
            setState(() => _out = [for (final x in pages) linesOf(x.boxes)]);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String _allText(L l) {
    final xs = _out ?? const <String>[];
    if (xs.length == 1) return xs.first;
    // 多页时标上页号。一份合同的文字连成一片之后, "这句在第几页"是最先丢掉
    // 也最常被问起的信息
    return [
      for (final (i, s) in xs.indexed)
        if (s.trim().isNotEmpty) '${l.textPageMarker(i + 1)}\n$s',
    ].join('\n\n');
  }

  Future<void> _copy(String s, String what) async {
    if (s.trim().isEmpty) return;
    final l = L.of(context);
    await Clipboard.setData(ClipboardData(text: s));
    await HapticFeedback.lightImpact();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.textCopied(what))));
  }

  Future<void> _exportTxt() async {
    final l = L.of(context);
    final s = _allText(l);
    if (s.trim().isEmpty) return;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/out');
    await dir.create(recursive: true);
    final name = (widget.title ?? l.commonDefaultDocName(stamp()))
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .trim();
    // 兜底用时间戳而不是某种语言的"扫描件": 名字被过滤成空是极少数情况,
    // 而这时候再翻一次只会让文件名跟着界面语言变, 反倒不好找
    final f = File('${dir.path}/${name.isEmpty ? stamp() : name}.txt');
    // UTF-8 带 BOM: 不带的话, Windows 记事本和一部分老 Excel 会把中文认成
    // 乱码。多三个字节换掉一整类"打开是天书"的反馈。写成转义而不是直接敲一个
    // U+FEFF —— 那个字符在编辑器里是看不见的, 谁都不知道行首多了个什么
    await f.writeAsString('\u{FEFF}$s', flush: true);
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final done = _out != null;
    final all = done ? _allText(l) : '';
    return Scaffold(
      appBar: SysBar(
        AppBar(
          title: Text(l.textTitle),
          // 跑的时候不让退: Rust 那侧没有中断的口子, 界面退了它还在后台算
          automaticallyImplyLeading: !_running,
          actions: [
            if (all.trim().isNotEmpty) ...[
              IconButton(
                icon: const Icon(Icons.copy_all_outlined),
                tooltip: l.textCopyAll,
                onPressed: () => _copy(all, l.textAll),
              ),
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: l.textExportTxt,
                onPressed: _exportTxt,
              ),
            ],
          ],
        ),
      ),
      body: Readable(child: _body(l)),
    );
  }

  Widget _body(L l) {
    if (_error != null) {
      return EmptyHint(
        icon: Icons.error_outline,
        title: l.textFailedTitle,
        hint: humanError(l, _error!),
        actionLabel: l.commonRetry,
        onAction: _run,
      );
    }
    if (_running || _out == null) {
      return Padding(
        padding: const EdgeInsets.all(Ui.gapLg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LinearProgressIndicator(value: _frac),
            const SizedBox(height: Ui.gap),
            Text(switch (_stage) {
              _Stage.prep => l.convertPreparing,
              _Stage.downloading =>
                l.ocrDownloadingPack(_pack, ((_frac ?? 0) * 100).round()),
              _Stage.loading => l.convertLoading,
              _Stage.page => l.convertPageOf(_at, _of),
              null => '',
            }),
            const SizedBox(height: Ui.gapSm),
            Text(l.ocrFirstPageNote,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }
    final xs = _out!;
    if (xs.every((s) => s.trim().isEmpty)) {
      return EmptyHint(
        icon: Icons.text_fields_outlined,
        title: l.textNothingTitle,
        hint: l.textNothingHint,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          Ui.gapMd, Ui.gapSm, Ui.gapMd, Ui.gapLg),
      itemCount: xs.length,
      itemBuilder: (ctx, i) => _card(l, i, xs[i]),
    );
  }

  Widget _card(L l, int i, String s) {
    final t = Theme.of(context);
    final empty = s.trim().isEmpty;
    return Card(
      margin: const EdgeInsets.only(bottom: Ui.gap),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ui.gap, Ui.gapSm, Ui.gapSm, Ui.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(l.commonPageN(i + 1),
                      style: t.textTheme.labelLarge
                          ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
                if (!empty)
                  IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    tooltip: l.textCopyPage,
                    onPressed: () => _copy(s, l.commonPageN(i + 1)),
                  ),
              ],
            ),
            if (empty)
              Text(l.textPageEmpty, style: t.textTheme.bodySmall)
            else
              // SelectableText 而不是 Text: 一整页复制走是一种用法, 只挑
              // 其中一个账号、一个日期出来是另一种, 后者更常见
              SelectableText(s, style: t.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// 把一页的文字框拼回一段可读的文字
///
/// Rust 那侧给的框已经按"先上后下、再左右"排好了, 但一个框是检测出来的一块
/// 文字区域, 不一定等于纸上的一行 —— 两栏排版、行中间空一大格, 都会被切成
/// 两个框。这里把纵向重叠得多的相邻框并回同一行, 不然导出的文字每隔几个字
/// 就断一次。
String linesOf(List<TextBox> boxes) {
  if (boxes.isEmpty) return '';
  final xs = [...boxes]..sort((a, b) {
      final d = a.y0.compareTo(b.y0);
      return d != 0 ? d : a.x0.compareTo(b.x0);
    });

  final out = <String>[];
  var line = <TextBox>[xs.first];
  for (final b in xs.skip(1)) {
    if (_sameLine(line.last, b)) {
      line.add(b);
    } else {
      out.add(_joinLine(line));
      line = [b];
    }
  }
  out.add(_joinLine(line));
  return out.join('\n');
}

/// 两个框算不算同一行: 纵向重叠超过矮的那个的一半
///
/// 按中心点距离判会栽在字号不一样的地方 —— 标题旁边的小字注释, 两个中心
/// 差不了多少, 但明显不是一行
bool _sameLine(TextBox a, TextBox b) {
  final over = (a.y1 < b.y1 ? a.y1 : b.y1) - (a.y0 > b.y0 ? a.y0 : b.y0);
  if (over <= 0) return false;
  final ha = a.y1 - a.y0, hb = b.y1 - b.y0;
  final lo = ha < hb ? ha : hb;
  return lo > 0 && over / lo > 0.5;
}

String _joinLine(List<TextBox> line) {
  final xs = [...line]..sort((a, b) => a.x0.compareTo(b.x0));
  var out = '';
  for (final b in xs) {
    final s = b.text.trim();
    if (s.isEmpty) continue;
    // 中文之间不加空格, 西文之间要加。判两边贴着的那个字符就够了 —— 猜错
    // 的代价是多一个或少一个空格, 而按框间距猜会被字号和缩放带偏
    if (out.isNotEmpty && _wordy(out[out.length - 1]) && _wordy(s[0])) {
      out += ' ';
    }
    out += s;
  }
  return out;
}

bool _wordy(String c) => RegExp(r'[A-Za-z0-9)\]}.,;:%]').hasMatch(c);
