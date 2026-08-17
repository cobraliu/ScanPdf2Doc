import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../doc.dart';
import '../models.dart';
import '../native.dart';
import '../rust/api/textlayer.dart';
import 'convert.dart';
import 'edit.dart';
import 'export_sheet.dart';

/// 一个文档里的那一摞页
///
/// 页序就是 `doc.pages` 的顺序, 一路传到 Rust 那边当页序用, 中间不再排一次。
/// 每一次增删改都立刻落盘 —— 扫描时内存压力大, App 被系统收走是常事,
/// 攒着等退出再存的话, 用户丢的是刚扫的十几页。
class DocPage extends StatefulWidget {
  const DocPage({super.key, required this.doc});

  final Doc doc;

  @override
  State<DocPage> createState() => _DocPageState();
}

class _DocPageState extends State<DocPage> {
  Doc get _doc => widget.doc;

  bool _busy = false;

  /// 忙的时候顶上显示的一行字。导入 PDF 可能要十几秒, 光转个圈用户不知道在等什么
  String _note = '';

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _progress(String note) {
    if (mounted) setState(() => _note = note);
  }

  Future<void> _guard(Future<void> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = '';
    });
    try {
      await body();
    } catch (e) {
      _say('$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _note = '';
        });
      }
    }
  }

  Future<void> _add(Iterable<String> srcs) async {
    final n = await _doc.addPages(srcs);
    if (mounted && n > 0) setState(() {});
  }

  Future<void> _scan() => _guard(() async {
        if (!await Native.scannerAvailable()) {
          _say('这台设备没有系统扫描器（模拟器就没有），用「相册」导入照片测试');
          return;
        }
        await _add(await Native.scan());
      });

  Future<void> _pick() => _guard(() async {
        final xs = await ImagePicker().pickMultiImage();
        if (xs.isEmpty) return;
        // 不做任何缩放/重编码: 相册里那张原图是什么样, 就照什么样喂给识别
        await _add(xs.map((x) => x.path));
      });

  /// 导入已有 PDF: 逐页渲成页图, 之后跟拍出来的页走同一条路
  ///
  /// 注意这条路是"渲染成图再 OCR", 哪怕原 PDF 本来就带文字层。原生的文字层
  /// 只有字和字号, 没有我们重建版式要的框线和栏位, 而这个 App 的价值恰恰在
  /// 版式 —— 所以宁可统一走识别, 也不做两条分叉的流水线
  Future<void> _importPdf() => _guard(() async {
        final pdfs = await Native.pickPdf();
        if (pdfs.isEmpty) return;
        final got = <String>[];
        for (final (i, pdf) in pdfs.indexed) {
          _progress(pdfs.length == 1
              ? '正在展开 PDF…'
              : '正在展开第 ${i + 1} / ${pdfs.length} 个 PDF…');
          got.addAll(await Native.pdfPages(pdf));
        }
        await _add(got);
        if (mounted) _say('导入 ${got.length} 页');
      });

  /// 先问选项再导。面板在 _guard 外面弹 —— 用户在那儿犹豫的十几秒里, 顶上
  /// 不该一直转着进度条, 底下四个按钮也不该是灰的
  Future<void> _exportPdf() async {
    if (_busy) return;
    final opts = await askPdfOpts(context);
    if (opts == null) return;
    await _guard(() async {
      final paths = [for (var i = 0; i < _doc.count; i++) _doc.pagePath(i)];
      final texts = opts.searchable ? await _textLayer(paths) : null;
      _progress('正在生成 PDF…');
      final out = await _outPath('pdf');
      await Native.makePdf(paths, out, opts: opts, texts: texts);
      _say('已导出 PDF · ${opts.summary}');
      await SharePlus.instance.share(ShareParams(files: [XFile(out)]));
    });
  }

  /// 认一遍字, 转成原生那边要的形状
  ///
  /// 这里不复用「转文档」那条流水线: 那条走完了版面重建, 段落会被合并、页眉
  /// 页脚会被丢掉, 而文字层要的是每一行字连同它在纸上的位置, 一行都不能少。
  ///
  /// 某页认不出来就留空 —— 那一页退化成纯图片, 其余页照样能搜, 比整个导出
  /// 失败强
  Future<List<List<Map<String, Object>>>> _textLayer(List<String> paths) async {
    final modelDir = await Models.ensure();
    var out = <List<Map<String, Object>>>[];
    await for (final p in ocrImages(
      modelDir: modelDir,
      images: paths,
      // 跟「转文档」同一个值: 识别效果对这个数很敏感, 两条路给出的文字
      // 不一致会很难解释
      longEdge: 2560,
      lowMemory: true,
    )) {
      switch (p) {
        case OcrProgress_Loading():
          _progress('正在加载识别模型…');
        case OcrProgress_Page(:final index, :final total):
          _progress('正在识别文字 $index / $total 页…');
        case OcrProgress_Done(:final pages):
          out = [
            for (final page in pages)
              [
                for (final b in page.boxes)
                  {'t': b.text, 'x0': b.x0, 'y0': b.y0, 'x1': b.x1, 'y1': b.y1}
              ]
          ];
      }
    }
    return out;
  }

  /// 传一份快照而不是 doc 本身: 识别是在另一个页面上慢慢跑的, 这边要是同时
  /// 被删了一页, 就会跟 Rust 那边正在读的页序对不上
  void _convert() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConvertPage(
        pages: [for (var i = 0; i < _doc.count; i++) _doc.pagePath(i)],
        title: _doc.name,
      ),
    ));
  }

  /// 导出一律放 Documents/out —— Info.plist 里开了文件共享, 这个目录在
  /// 「文件」App 里直接可见, 不想用分享面板时可以自己拷出去
  Future<String> _outPath(String ext) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/out');
    await dir.create(recursive: true);
    return '${dir.path}/${_safeName(_doc.name)}.$ext';
  }

  /// 文档名是用户随手起的, 直接当文件名会撞上路径分隔符
  static String _safeName(String s) {
    final t = s.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    return t.isEmpty ? '扫描件-${stamp()}' : t;
  }

  Future<void> _edit(int i) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditPage(doc: _doc, index: i),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _renameDoc() async {
    final s = await askName(context, '重命名', _doc.name);
    if (s == null) return;
    await _doc.rename(s);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final n = _doc.count;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _busy ? null : _renameDoc,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(_doc.name, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.edit_outlined, size: 16),
            ],
          ),
        ),
        actions: [
          if (n > 0)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: '导出 PDF',
              onPressed: _busy ? null : _exportPdf,
            ),
        ],
      ),
      body: Stack(
        children: [
          n == 0 ? const _Empty() : _list(),
          if (_busy)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LinearProgressIndicator(minHeight: 3),
                if (_note.isNotEmpty)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(_note,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          // 四个等宽按钮, 图标在上文字在下。窄屏上图标和文字并排会把
          // "转文档"挤成三行, 竖着排就不会
          child: Row(
            spacing: 8,
            children: [
              _Act(
                icon: Icons.document_scanner_outlined,
                label: '扫描',
                primary: true,
                onTap: _busy ? null : _scan,
              ),
              _Act(
                icon: Icons.photo_library_outlined,
                label: '相册',
                onTap: _busy ? null : _pick,
              ),
              _Act(
                icon: Icons.file_open_outlined,
                label: 'PDF',
                onTap: _busy ? null : _importPdf,
              ),
              _Act(
                icon: Icons.text_snippet_outlined,
                label: '转文档',
                tonal: true,
                onTap: _busy || n == 0 ? null : _convert,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _doc.count,
      // onReorderItem 而不是老的 onReorder: 后者给的 newIndex 是"还没把元素
      // 拿走时"的下标, 往后拖要自己减一, 一直是这个控件最容易写错的地方。
      // 新回调已经替我们调好了, 直接用
      onReorderItem: (a, b) async {
        await _doc.reorder(a, b);
        if (mounted) setState(() {});
      },
      itemBuilder: (ctx, i) => _tile(i),
    );
  }

  Widget _tile(int i) {
    return ListTile(
      // 页文件名不会重复(见 Doc.nextSeq), 拿它当 key 和图片缓存键都是稳的
      key: ValueKey(_doc.pages[i]),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        // cacheWidth 是必须的: 不给的话每张缩略图都会把整张四千像素的照片解成
        // 位图放进内存, 二十页就是几百 MB —— 识别还没开始就先把内存吃光了
        child: Image.file(
          File(_doc.pagePath(i)),
          width: 56,
          height: 74,
          fit: BoxFit.cover,
          cacheWidth: 160,
          errorBuilder: (_, _, _) => const SizedBox(
            width: 56,
            height: 74,
            child: Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
      // 不再显示文件名: 以前那是相机/相册给的名字, 还有点信息量; 现在页图
      // 是我们自己按页号命名的, 写出来就是一句废话
      title: Text('第 ${i + 1} 页'),
      subtitle: _doc.hasOriginal(i)
          ? Text('已编辑', style: Theme.of(context).textTheme.bodySmall)
          : null,
      onTap: _busy ? null : () => _edit(i),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await _doc.removePage(i);
              if (mounted) setState(() {});
            },
          ),
          ReorderableDragStartListener(
            index: i,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}

/// 起名字/改名字的小对话框, 文档列表那边也用
Future<String?> askName(BuildContext context, String title, String init) async {
  final c = TextEditingController(text: init);
  final s = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text),
            child: const Text('确定')),
      ],
    ),
  );
  c.dispose();
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// 底部那一排动作按钮
class _Act extends StatelessWidget {
  const _Act({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.tonal = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 22),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
    const style = ButtonStyle(
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
    );
    return Expanded(
      child: primary
          ? FilledButton(onPressed: onTap, style: style, child: child)
          : tonal
              ? FilledButton.tonal(onPressed: onTap, style: style, child: child)
              : OutlinedButton(onPressed: onTap, style: style, child: child),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Icon(Icons.document_scanner_outlined,
              size: 72, color: Theme.of(context).colorScheme.outline),
          const Text('还没有页'),
          Text('「扫描」拍纸质件，「相册」「PDF」导入已有文件',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
