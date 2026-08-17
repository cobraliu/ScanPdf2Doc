import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../doc.dart' show stamp;
import '../models.dart';
import '../rust/api/convert.dart';
import 'errors.dart';
import 'theme.dart';

/// 跑到哪一步了
///
/// 存这个而不是存一句拼好的话: 那句话要在 build 里翻, 存成文本的话界面语言
/// 换了它还是旧的那种语言
enum _Stage { prep, loading, page, writing }

/// 识别页: 选格式 -> 跑 Rust -> 出文件
///
/// 整个过程是一条 Stream。Rust 那边每开始一页就 add 一个事件, 最后一个事件
/// 带着结果 —— 所以这个界面从头到尾只有一个订阅, 不用另外poll状态。
class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key, required this.pages, this.title});

  final List<String> pages;

  /// 文档名, 默认拿它当标题 —— 用户已经在上一层起过名了, 不该再问一遍
  final String? title;

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  final _title = TextEditingController();
  OutFormat _fmt = OutFormat.docx;

  bool _running = false;
  _Stage? _stage;
  int _at = 0, _of = 0;
  double? _frac;
  ConvertReport? _done;
  Object? _error;

  /// 默认标题得等到能拿到 L 才填得出来, 而 L 要走 InheritedWidget ——
  /// 字段初始化和 initState 都还够不着, 只能在这儿补
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_title.text.isEmpty) {
      _title.text = widget.title ?? L.of(context).commonDefaultDocName(stamp());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final fallback = L.of(context).commonDefaultDocName(stamp());
    setState(() {
      _running = true;
      _error = null;
      _done = null;
      _stage = _Stage.prep;
      _frac = null;
    });
    try {
      final ocr = await Models.setup();
      final base = await getApplicationDocumentsDirectory();
      final outDir = '${base.path}/out';

      final s = convertImages(
        modelDir: ocr.dir,
        images: widget.pages,
        outDir: outDir,
        title: _title.text.trim().isEmpty ? fallback : _title.text.trim(),
        format: _fmt,
        // 长边跟桌面版一个值。这是识别效果的命门, 不做成开关免得被随手调低
        longEdge: 2560,
        // 峰值省 ~130 MB, 几乎不费时间。手机上没有理由关
        lowMemory: true,
        // 认哪种语言的字。null 就是内置那个中英混排的
        recFile: ocr.recFile,
      );

      await for (final p in s) {
        if (!mounted) return;
        switch (p) {
          case Progress_Loading():
            setState(() {
              _stage = _Stage.loading;
              _frac = null;
            });
          case Progress_Page(:final index, :final total):
            setState(() {
              _stage = _Stage.page;
              _at = index;
              _of = total;
              _frac = index / total;
            });
          case Progress_Writing():
            setState(() {
              _stage = _Stage.writing;
              _frac = 1;
            });
          case Progress_Done(:final report):
            setState(() => _done = report);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _share(String path) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.convertTitle),
        // 跑的时候不让返回: Rust 侧没有中断口子, 界面退了它还在后台算,
        // 不如老老实实等着
        automaticallyImplyLeading: !_running,
      ),
      body: Readable(
          child: ListView(
        padding: const EdgeInsets.all(Ui.gapMd),
        children: [
          Text(l.commonPages(widget.pages.length),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            enabled: !_running,
            decoration: InputDecoration(
              labelText: l.convertTitleField,
              helperText: l.convertTitleHelp,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // Word 和 Excel 不翻译: 是产品名, 各语言界面上都写这两个词
          SegmentedButton<OutFormat>(
            segments: [
              const ButtonSegment(value: OutFormat.docx, label: Text('Word')),
              const ButtonSegment(value: OutFormat.xlsx, label: Text('Excel')),
              ButtonSegment(value: OutFormat.both, label: Text(l.convertBoth)),
            ],
            selected: {_fmt},
            onSelectionChanged:
                _running ? null : (s) => setState(() => _fmt = s.first),
          ),
          const SizedBox(height: 24),
          if (_running) ...[
            LinearProgressIndicator(value: _frac),
            const SizedBox(height: 8),
            Text(_stageText(l)),
            const SizedBox(height: 8),
            Text(l.ocrFirstPageNote,
                style: Theme.of(context).textTheme.bodySmall),
          ] else
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.play_arrow),
              label: Text(_done == null ? l.convertStart : l.convertAgain),
            ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(humanError(l, _error!)),
            ),
          ],
          if (_done != null) ...[
            const SizedBox(height: 16),
            _result(_done!),
          ],
        ],
      )),
    );
  }

  String _stageText(L l) => switch (_stage) {
        _Stage.prep => l.convertPreparing,
        _Stage.loading => l.convertLoading,
        _Stage.page => l.convertPageOf(_at, _of),
        _Stage.writing => l.convertWriting,
        null => '',
      };

  Widget _result(ConvertReport r) {
    final l = L.of(context);
    final files = [
      if (r.docxPath != null) r.docxPath!,
      if (r.xlsxPath != null) r.xlsxPath!,
    ];
    return _Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 表格那半句自带前导的逗号, 直接接在后面 —— 各语言的标点不一样,
          // 拼接符号交给译文自己带
          Text('${l.convertDone(r.pages)}'
              '${r.tables > 0 ? l.convertDoneTables(r.tables) : ''}'),
          if (r.failed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(l.convertFailed(r.failed.length),
                style: Theme.of(context).textTheme.bodySmall),
            for (final f in r.failed)
              Text('· $f', style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          for (final f in files)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(f.split('/').last),
              subtitle: Text(_size(f)),
              trailing: IconButton(
                icon: const Icon(Icons.ios_share),
                onPressed: () => _share(f),
              ),
            ),
          Text(l.convertWhere, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  static String _size(String p) {
    try {
      final n = File(p).lengthSync();
      return n < 1024 * 1024
          ? '${(n / 1024).toStringAsFixed(0)} KB'
          : '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}
