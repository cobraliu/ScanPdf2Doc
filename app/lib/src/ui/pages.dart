import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../doc.dart';
import '../models.dart';
import '../native.dart';
import '../rust/api/textlayer.dart';
import 'convert.dart';
import 'edit.dart';
import 'enhance.dart';
import 'errors.dart';
import 'export_sheet.dart';
import 'text.dart';
import 'theme.dart';
import 'window_controls.dart';

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

  /// 多选模式下选中的页; null = 不在多选模式
  ///
  /// 存文件名而不是下标: 中途删掉一页、或者拖动过顺序, 下标就全错位了。文件名
  /// 在一个文档里唯一且不复用(见 `Doc.nextSeq`), 拿它当键是稳的。
  Set<String>? _sel;

  bool get _selecting => _sel != null;

  /// 选中页的下标, 升序
  List<int> get _selIdx {
    final s = _sel;
    if (s == null) return const [];
    return [
      for (var i = 0; i < _doc.count; i++)
        if (s.contains(_doc.pages[i])) i,
    ];
  }

  List<int> get _allIdx => [for (var i = 0; i < _doc.count; i++) i];

  void _startSelect([int? i]) {
    HapticFeedback.selectionClick();
    setState(() => _sel = {if (i != null) _doc.pages[i]});
  }

  void _endSelect() {
    if (mounted) setState(() => _sel = null);
  }

  void _toggle(int i) {
    final s = _sel;
    if (s == null) return;
    final k = _doc.pages[i];
    setState(() {
      if (!s.remove(k)) s.add(k);
    });
  }

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
      if (mounted) _say(humanError(L.of(context), e));
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

  Future<void> _scan() {
    // 先把这句话取出来。取在 _guard 里面的话, 是在 await 之后再碰 context ——
    // 那时候这个页面可能已经被推走了
    final noScanner = L.of(context).pagesNoScanner;
    return _guard(() async {
      if (!await Native.scannerAvailable()) {
        _say(noScanner);
        return;
      }
      await _add(await Native.scan());
    });
  }

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
  Future<void> _importPdf() {
    final l = L.of(context);
    return _guard(() async {
        final pdfs = await Native.pickPdf();
        if (pdfs.isEmpty) return;
        final got = <String>[];
        for (final (i, pdf) in pdfs.indexed) {
          _progress(pdfs.length == 1
              ? l.pagesExpandingPdf
              : l.pagesExpandingPdfN(i + 1, pdfs.length));
          got.addAll(await Native.pdfPages(pdf));
        }
        await _add(got);
        if (mounted) _say(l.pagesImported(got.length));
    });
  }

  /// 先问选项再导。面板在 _guard 外面弹 —— 用户在那儿犹豫的十几秒里, 顶上
  /// 不该一直转着进度条, 底下四个按钮也不该是灰的
  ///
  /// only 给的是页下标; 不给就是整份
  Future<void> _exportPdf({List<int>? only}) async {
    if (_busy) return;
    final idx = only ?? _allIdx;
    if (idx.isEmpty) return;
    final opts = await askPdfOpts(context);
    if (opts == null || !mounted) return;
    final l = L.of(context);
    await _guard(() async {
      final paths = [for (final i in idx) _doc.pagePath(i)];
      final texts = opts.searchable ? await _textLayer(l, paths) : null;
      _progress(l.pagesMakingPdf);
      // 挑着导的另起一个文件名: 沿用整份那个名字的话, 上一次导的完整版会被
      // 这三页悄悄顶掉, 而「文件」App 里看上去还是同一个文件
      final out = await _outPath('pdf',
          suffix: only == null ? '' : l.pagesExportSuffix(idx.length));
      await Native.makePdf(paths, out, opts: opts, texts: texts);
      await HapticFeedback.lightImpact();
      if (only != null) _endSelect();
      // 先弹分享面板再提示。反过来的话, SnackBar 刚冒头就被面板盖住 ——
      // 等于没提示。面板关掉之后这句话才有人看得见
      await SharePlus.instance.share(ShareParams(files: [XFile(out)]));
      _say(l.pagesExported(opts.summary(l)));
    });
  }

  /// 批量增强
  ///
  /// 一页失败不往下传: 二十页里有一张是相册来的怪格式, 不该让另外十九页
  /// 白等一遍。最后统一报数。
  Future<void> _enhanceMany(List<int> idx) async {
    if (_busy || idx.isEmpty) return;
    final e = await askEnhance(context, idx.length);
    if (e == null || !mounted) return;
    final l = L.of(context);
    await _guard(() async {
      var bad = 0;
      for (final (n, i) in idx.indexed) {
        _progress(l.pagesEnhancing(n + 1, idx.length));
        final old = _doc.pages[i];
        final src = _doc.pagePath(i);
        try {
          await _doc.replacePage(i, (out) => Native.enhancePage(src, out, e.id));
          // 换过之后这一页是个新文件名, 选中集合得跟着换, 否则界面上它会
          // 突然变成没选中
          if (_sel?.remove(old) ?? false) _sel!.add(_doc.pages[i]);
        } catch (_) {
          bad++;
        }
      }
      await HapticFeedback.lightImpact();
      _endSelect();
      _say(bad == 0
          ? l.pagesEnhanceDone(idx.length, e.label(l))
          : l.pagesEnhancePartial(idx.length - bad, bad));
    });
  }

  Future<void> _deleteMany(List<int> idx) async {
    if (_busy || idx.isEmpty) return;
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.pagesDeleteManyTitle(idx.length)),
        content: Text(l.pagesDeleteManyBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await HapticFeedback.mediumImpact();
    await _guard(() async {
      // 从后往前删。从前往后的话, 删掉第 2 页之后第 5 页就变成第 4 页了,
      // 手上这份下标立刻全错
      for (final i in idx.reversed) {
        await _doc.removePage(i);
      }
      _endSelect();
      _say(l.pagesDeletedMany(idx.length));
    });
  }

  /// 把选中的页搬到另一个文档 —— 一次扫进来两份东西时用来拆开
  Future<void> _moveMany(List<int> idx) async {
    if (_busy || idx.isEmpty) return;
    final pick = await _pickTarget(idx.length);
    if (pick == null || !mounted) return;
    final l = L.of(context);
    await _guard(() async {
      final paths = [for (final i in idx) _doc.pagePath(i)];
      final target = pick is Doc
          ? pick
          : await DocStore.create(name: l.pagesSplitName(_doc.name));
      try {
        _progress(l.pagesMoving(idx.length));
        await target.addPages(paths);
      } catch (e) {
        // 刚为这次移动建的空文档, 没搬成就别留在列表里
        if (pick is! Doc) await DocStore.dropIfEmpty(target);
        rethrow;
      }
      // 按"文件还在不在"回头核一遍, 而不是假定 idx 里每一页都搬成了。
      // addPages 是一页一页 rename 过去的, 半路失败时照单全删会把还留在
      // 这边的页也删掉 —— 那就真丢了
      final moved = <int>[];
      for (final i in idx) {
        if (!await File(_doc.pagePath(i)).exists()) moved.add(i);
      }
      for (final i in moved.reversed) {
        await _doc.removePage(i);
      }
      await HapticFeedback.lightImpact();
      _endSelect();
      _say(moved.length == idx.length
          ? l.pagesMovedAll(moved.length, target.name)
          : l.pagesMovedSome(moved.length, idx.length - moved.length));
    });
  }

  /// 挑一个目标文档: 返回 Doc = 选了现成的, 返回 `'new'` = 要新建, null = 取消
  ///
  /// 不在面板里当场建文档 —— 建完用户又滑掉面板的话, 列表里就留下一个空壳,
  /// 而这条路上没有 `dropIfEmpty` 会来收拾它
  Future<Object?> _pickTarget(int n) async {
    final all = await DocStore.list();
    final others = [
      for (final d in all)
        if (d.id != _doc.id) d,
    ];
    if (!mounted) return null;
    return showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: Ui.readable),
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        final l = L.of(ctx);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: Ui.gapMd),
            children: [
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(Ui.gapMd, 0, Ui.gapMd, Ui.gapSm),
                child: Text(l.pagesMoveTitle(n), style: t.titleLarge),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(l.commonNewDoc),
                subtitle: Text(
                    l.pagesMoveNewName(l.pagesSplitName(_doc.name)),
                    style: t.bodySmall),
                onTap: () => Navigator.of(ctx).pop('new'),
              ),
              if (others.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Ui.gapMd),
                  child: Text(l.pagesNoOtherDocs, style: t.bodySmall),
                ),
              for (final d in others)
                ListTile(
                  leading: PageThumb(path: d.cover),
                  title:
                      Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(l.commonPages(d.count), style: t.bodySmall),
                  onTap: () => Navigator.of(ctx).pop(d),
                ),
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(Ui.gapMd, Ui.gapSm, Ui.gapMd, 0),
                child: Text(l.pagesMoveNote, style: t.bodySmall),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 只把字提出来。传快照而不是 doc, 理由同 [_convert]
  void _extract({List<int>? only}) {
    final idx = only ?? _allIdx;
    if (idx.isEmpty) return;
    final paths = [for (final i in idx) _doc.pagePath(i)];
    if (only != null) _endSelect();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TextPage(pages: paths, title: _doc.name),
    ));
  }

  /// 认一遍字, 转成原生那边要的形状
  ///
  /// 这里不复用「转文档」那条流水线: 那条走完了版面重建, 段落会被合并、页眉
  /// 页脚会被丢掉, 而文字层要的是每一行字连同它在纸上的位置, 一行都不能少。
  ///
  /// 某页认不出来就留空 —— 那一页退化成纯图片, 其余页照样能搜, 比整个导出
  /// 失败强
  Future<List<List<Map<String, Object>>>> _textLayer(
      L l, List<String> paths) async {
    final pack = Models.current.name(l);
    final ocr = await Models.prepare(
      onDownload: (p) =>
          _progress(l.ocrDownloadingPack(pack, (p * 100).round())),
    );
    var out = <List<Map<String, Object>>>[];
    await for (final p in ocrImages(
      modelDir: ocr.dir,
      images: paths,
      // 跟「转文档」同一个值: 识别效果对这个数很敏感, 两条路给出的文字
      // 不一致会很难解释
      longEdge: 2560,
      lowMemory: true,
      recFile: ocr.recFile,
    )) {
      switch (p) {
        case OcrProgress_Loading():
          _progress(l.convertLoading);
        case OcrProgress_Page(:final index, :final total):
          _progress(l.convertPageOf(index, total));
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
  Future<String> _outPath(String ext, {String suffix = ''}) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/out');
    await dir.create(recursive: true);
    return '${dir.path}/${_safeName(_doc.name)}$suffix.$ext';
  }

  /// 文档名是用户随手起的, 直接当文件名会撞上路径分隔符
  // 兜底用时间戳而不是某种语言的"扫描件": 名字被过滤成空是极少数情况, 而
  // 让文件名跟着界面语言变, 在「文件」App 里反倒不好找回来
  static String _safeName(String s) {
    final t = s.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    return t.isEmpty ? stamp() : t;
  }

  Future<void> _edit(int i) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditPage(doc: _doc, index: i),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _renameDoc() async {
    final s = await askName(context, L.of(context).commonRename, _doc.name);
    if (s == null) return;
    await _doc.rename(s);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final n = _doc.count;
    // 多选着的时候按返回, 该是退出多选而不是退出这个文档 —— 后者会让人以为
    // 刚才勾的那几页出了什么事
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _endSelect();
      },
      child: _scaffold(l, n),
    );
  }

  Widget _scaffold(L l, int n) {
    return Scaffold(
      appBar: SysBar(_selecting ? _selectBar(l) : _titleBar(l, n)),
      body: Stack(
        children: [
          n == 0
              ? EmptyHint(
                  icon: Icons.document_scanner_outlined,
                  title: l.pagesEmptyTitle,
                  hint: l.pagesEmptyHint,
                  actionLabel: l.pagesEmptyAction,
                  onAction: _busy ? null : _scan,
                )
              : _list(l),
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
          child: _selecting ? _selectActions(l) : _mainActions(l, n),
        ),
      ),
    );
  }

  PreferredSizeWidget _titleBar(L l, int n) {
    return AppBar(
      title: GestureDetector(
        onTap: _busy ? null : _renameDoc,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(_doc.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            const Icon(Icons.edit_outlined, size: 16),
          ],
        ),
      ),
      actions: [
        if (n > 0) ...[
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: l.pagesExportPdf,
            onPressed: _busy ? null : _exportPdf,
          ),
          PopupMenuButton<String>(
            tooltip: l.commonMore,
            enabled: !_busy,
            onSelected: (v) {
              switch (v) {
                case 'text':
                  _extract();
                case 'enhance':
                  _enhanceMany(_allIdx);
                case 'select':
                  _startSelect();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'text',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.text_fields_outlined),
                  title: Text(l.pagesExtractText),
                ),
              ),
              PopupMenuItem(
                value: 'enhance',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: Text(l.pagesEnhanceAll),
                ),
              ),
              const PopupMenuDivider(),
              // 长按也能进多选, 但只有长按的话没人找得到 —— 菜单里这一条是
              // 那个手势的说明书
              PopupMenuItem(
                value: 'select',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.checklist),
                  title: Text(l.pagesSelect),
                  subtitle: Text(l.pagesSelectHint),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  PreferredSizeWidget _selectBar(L l) {
    final k = _sel!.length;
    final all = k > 0 && k == _doc.count;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: l.pagesSelectExit,
        onPressed: _busy ? null : _endSelect,
      ),
      title: Text(k == 0 ? l.pagesSelect : l.pagesSelected(k)),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _sel = all ? <String>{} : {..._doc.pages}),
          child: Text(all ? l.pagesSelectNone : l.pagesSelectAll),
        ),
      ],
    );
  }

  /// 四个等宽按钮, 图标在上文字在下。窄屏上图标和文字并排会把"转文档"挤成
  /// 三行, 竖着排就不会
  Widget _mainActions(L l, int n) {
    return Row(
      spacing: 8,
      children: [
        _Act(
          icon: Icons.document_scanner_outlined,
          label: l.pagesActScan,
          primary: true,
          onTap: _busy ? null : _scan,
        ),
        _Act(
          icon: Icons.photo_library_outlined,
          label: l.pagesActPhotos,
          onTap: _busy ? null : _pick,
        ),
        _Act(
          icon: Icons.file_open_outlined,
          label: 'PDF',
          onTap: _busy ? null : _importPdf,
        ),
        _Act(
          icon: Icons.text_snippet_outlined,
          label: l.pagesActConvert,
          tonal: true,
          onTap: _busy || n == 0 ? null : _convert,
        ),
      ],
    );
  }

  /// 多选时底下这一排 —— 位置跟平时那排对齐, 手不用重新找
  Widget _selectActions(L l) {
    final idx = _selIdx;
    final on = !_busy && idx.isNotEmpty;
    return Row(
      spacing: 8,
      children: [
        _Act(
          icon: Icons.auto_awesome_outlined,
          label: l.pagesActEnhance,
          onTap: on ? () => _enhanceMany(idx) : null,
        ),
        _Act(
          icon: Icons.drive_file_move_outlined,
          label: l.pagesActMove,
          onTap: on ? () => _moveMany(idx) : null,
        ),
        _Act(
          icon: Icons.picture_as_pdf_outlined,
          label: l.pagesActExport,
          tonal: true,
          onTap: on ? () => _exportPdf(only: idx) : null,
        ),
        _Act(
          icon: Icons.delete_outline,
          label: l.commonDelete,
          danger: true,
          onTap: on ? () => _deleteMany(idx) : null,
        ),
      ],
    );
  }

  Widget _list(L l) {
    return Readable(
      child: ReorderableListView.builder(
        padding: const EdgeInsets.only(top: Ui.gapSm, bottom: Ui.gapLg),
        itemCount: _doc.count,
        // 关掉默认手柄。默认那套在手机上是"长按整行就开始拖", 而长按现在
        // 要用来进多选 —— 两个手势抢同一下。每行右边本来就有自己的拖拽
        // 手柄(见 _tile), 拖这件事没有丢
        buildDefaultDragHandles: false,
        // onReorderItem 而不是老的 onReorder: 后者给的 newIndex 是"还没把元素
        // 拿走时"的下标, 往后拖要自己减一, 一直是这个控件最容易写错的地方。
        // 新回调已经替我们调好了, 直接用
        onReorderItem: (a, b) async {
          await HapticFeedback.selectionClick();
          await _doc.reorder(a, b);
          if (mounted) setState(() {});
        },
        itemBuilder: (ctx, i) => _tile(l, i),
      ),
    );
  }

  /// 把第 i 页挪到 to
  ///
  /// 拖拽之外的第二条路。只能拖的话, 手不稳的人、开着旁白的人就没有办法排序
  /// 了 —— 而"每个拖拽都要有非拖拽的替代"是条硬规矩(WCAG 2.2 的
  /// dragging-alternative)。菜单里的「上移/下移」就是那条替代路。
  Future<void> _movePage(int i, int to) async {
    if (to < 0 || to >= _doc.count) return;
    await HapticFeedback.selectionClick();
    await _doc.reorder(i, to);
    if (mounted) setState(() {});
  }

  /// 删一页要先问一句
  ///
  /// 以前这里是点一下直接删。页图删掉就没了(连带那张留着做「还原」的原图),
  /// 而删除按钮就贴在拖拽手柄边上 —— 想拖着换个顺序, 手指偏一点就少一页,
  /// 而且没有任何提示。
  Future<void> _removePage(int i) async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.pagesDeleteOneTitle(i + 1)),
        content: Text(l.pagesDeleteOneBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await HapticFeedback.mediumImpact();
    await _doc.removePage(i);
    if (mounted) setState(() {});
  }

  Widget _tile(L l, int i) {
    final t = Theme.of(context);
    // 页文件名不会重复(见 Doc.nextSeq), 拿它当 key 和图片缓存键都是稳的
    final key = ValueKey(_doc.pages[i]);
    final edited = _doc.hasOriginal(i)
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_fix_high_outlined,
                  size: 14, color: t.colorScheme.onSurfaceVariant),
              const SizedBox(width: Ui.gapXs),
              Text(l.pagesEdited,
                  style: t.textTheme.bodySmall
                      ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          )
        : null;

    if (_selecting) {
      final on = _sel!.contains(_doc.pages[i]);
      return ListTile(
        key: key,
        leading: PageThumb(path: _doc.pagePath(i)),
        title: Text(l.commonPageN(i + 1)),
        subtitle: edited,
        selected: on,
        // 整行都能点。多选时只有右边那个小方块能点, 是二十页里点二十次的
        // 精细活 —— 勾选框留着当状态指示, 点哪儿都算
        onTap: _busy ? null : () => _toggle(i),
        trailing: Checkbox(
          value: on,
          onChanged: _busy ? null : (_) => _toggle(i),
        ),
      );
    }

    return ListTile(
      key: key,
      leading: PageThumb(path: _doc.pagePath(i)),
      // 不再显示文件名: 以前那是相机/相册给的名字, 还有点信息量; 现在页图
      // 是我们自己按页号命名的, 写出来就是一句废话
      title: Text(l.commonPageN(i + 1)),
      subtitle: edited,
      onTap: _busy ? null : () => _edit(i),
      onLongPress: _busy ? null : () => _startSelect(i),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 删除从"直接一个按钮"收进菜单。它原先就贴着拖拽手柄, 两个 40 点
          // 出头的命中区并排, 想拖着换顺序结果删掉一页是很容易发生的事
          PopupMenuButton<String>(
            tooltip: l.pagesTileMenu,
            enabled: !_busy,
            onSelected: (v) {
              switch (v) {
                case 'up':
                  _movePage(i, i - 1);
                case 'down':
                  _movePage(i, i + 1);
                case 'delete':
                  _removePage(i);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'up',
                enabled: i > 0,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.arrow_upward),
                  title: Text(l.pagesMoveUp),
                ),
              ),
              PopupMenuItem(
                value: 'down',
                enabled: i < _doc.count - 1,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.arrow_downward),
                  title: Text(l.pagesMoveDown),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.delete_outline, color: t.colorScheme.error),
                  title: Text(l.commonDelete,
                      style: TextStyle(color: t.colorScheme.error)),
                ),
              ),
            ],
          ),
          // 手柄的命中区撑到 44×44: 原先是 24 的图标加 8 的内边距 = 40
          ReorderableDragStartListener(
            index: i,
            child: Tooltip(
              message: l.pagesDragHint,
              child: SizedBox(
                width: Ui.tap,
                height: Ui.tap,
                child: Icon(Icons.drag_handle, color: t.colorScheme.outline),
              ),
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
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L.of(ctx).commonCancel)),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text),
            child: Text(L.of(ctx).commonOk)),
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
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool tonal;

  /// 破坏性动作, 描边和字都走 error 色
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 22),
        const SizedBox(height: 2),
        // 底栏四等分, 而德语的「Verschieben」是 11 个字母 —— 窄屏上放不下,
        // 又是一个词, 没有空格可以换行。只剩两条路: 截成「Verschie…」,
        // 或者整体缩一点。缩比截好, 截掉之后那个按钮就认不出是干什么的了。
        // scaleDown 只在真放不下时才动手, 中文英文这边一点变化都没有
        FittedBox(
          fit: BoxFit.scaleDown,
          child:
              Text(label, maxLines: 1, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
    const pad = EdgeInsets.symmetric(vertical: 8);
    const style = ButtonStyle(padding: WidgetStatePropertyAll(pad));
    // 只染色, 不做成实心红。底下四个按钮里有一个是大红块的话, 眼睛会先落到
    // 它身上 —— 而"删除"恰恰是最不该被先看到的那个
    final err = Theme.of(context).colorScheme.error;
    return Expanded(
      child: danger
          ? OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(padding: pad, foregroundColor: err),
              child: child,
            )
          : primary
              ? FilledButton(onPressed: onTap, style: style, child: child)
              : tonal
                  ? FilledButton.tonal(
                      onPressed: onTap, style: style, child: child)
                  : OutlinedButton(onPressed: onTap, style: style, child: child),
    );
  }
}

