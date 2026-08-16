import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../native.dart';
import 'convert.dart';

/// 主界面: 一摞页 + 底下四个动作
///
/// 页顺序就是 `_pages` 的顺序, 一路传到 Rust 那边当页序用, 中间不再排一次。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<String> _pages = [];
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

  Future<void> _scan() => _guard(() async {
        if (!await Native.scannerAvailable()) {
          _say('这台设备没有系统扫描器（模拟器就没有），用「相册」导入照片测试');
          return;
        }
        final got = await Native.scan();
        if (got.isNotEmpty) setState(() => _pages.addAll(got));
      });

  Future<void> _pick() => _guard(() async {
        final xs = await ImagePicker().pickMultiImage();
        if (xs.isEmpty) return;
        // 不做任何缩放/重编码: 相册里那张原图是什么样, 就照什么样喂给识别
        setState(() => _pages.addAll(xs.map((x) => x.path)));
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
        if (!mounted) return;
        setState(() => _pages.addAll(got));
        _say('导入 ${got.length} 页');
      });

  Future<void> _exportPdf() => _guard(() async {
        final out = await _outPath('pdf');
        await Native.makePdf(_pages, out);
        await _share(out, '已导出 PDF');
      });

  /// 传 List.of 而不是 _pages 本身: 识别是在另一个页面上慢慢跑的, 这边要是
  /// 同时被删了一页, 就会跟 Rust 那边正在读的页序对不上
  void _convert() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ConvertPage(pages: List.of(_pages))),
    );
  }

  /// 输出一律放 Documents/out —— Info.plist 里开了文件共享, 这个目录在
  /// 「文件」App 里直接可见, 不想用分享面板时可以自己拷出去
  Future<String> _outPath(String ext) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/out');
    await dir.create(recursive: true);
    return '${dir.path}/${stamp()}.$ext';
  }

  Future<void> _share(String path, String msg) async {
    _say(msg);
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  @override
  Widget build(BuildContext context) {
    final n = _pages.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(n == 0 ? 'ScanPdf2Doc' : '$n 页'),
        actions: [
          if (n > 0) ...[
            // 导出 PDF 挪到这儿, 底下那排就统一是"把页弄进来"+"转文档"了 ——
            // 一排按钮里混着一个方向相反的动作, 每次都得停下来想一下
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: '导出 PDF',
              onPressed: _busy ? null : _exportPdf,
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(_pages.clear),
              child: const Text('清空'),
            ),
          ],
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
      itemCount: _pages.length,
      // onReorderItem 而不是老的 onReorder: 后者给的 newIndex 是"还没把元素
      // 拿走时"的下标, 往后拖要自己减一, 一直是这个控件最容易写错的地方。
      // 新回调已经替我们调好了, 直接用
      onReorderItem: (a, b) =>
          setState(() => _pages.insert(b, _pages.removeAt(a))),
      itemBuilder: (ctx, i) => _tile(i),
    );
  }

  Widget _tile(int i) {
    final path = _pages[i];
    return ListTile(
      key: ValueKey(path),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        // cacheWidth 是必须的: 不给的话每张缩略图都会把整张四千像素的照片解成
        // 位图放进内存, 二十页就是几百 MB —— 识别还没开始就先把内存吃光了
        child: Image.file(
          File(path),
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
      title: Text('第 ${i + 1} 页'),
      subtitle: Text(path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => _pages.removeAt(i)),
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

/// 文件名用的时间戳, 形如 20260814-1930
String stamp() {
  final t = DateTime.now();
  String p(int v, [int n = 2]) => v.toString().padLeft(n, '0');
  return '${t.year}${p(t.month)}${p(t.day)}-${p(t.hour)}${p(t.minute)}${p(t.second)}';
}
