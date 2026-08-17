import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../doc.dart' show stamp;
import '../models.dart';
import '../rust/api/convert.dart';

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
  late final _title =
      TextEditingController(text: widget.title ?? '扫描件-${stamp()}');
  OutFormat _fmt = OutFormat.docx;

  bool _running = false;
  String _stage = '';
  double? _frac;
  ConvertReport? _done;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _done = null;
      _stage = '准备中';
      _frac = null;
    });
    try {
      final modelDir = await Models.ensure();
      final base = await getApplicationDocumentsDirectory();
      final outDir = '${base.path}/out';

      final s = convertImages(
        modelDir: modelDir,
        images: widget.pages,
        outDir: outDir,
        title: _title.text.trim().isEmpty ? '扫描件' : _title.text.trim(),
        format: _fmt,
        // 长边跟桌面版一个值。这是识别效果的命门, 不做成开关免得被随手调低
        longEdge: 2560,
        // 峰值省 ~130 MB, 几乎不费时间。手机上没有理由关
        lowMemory: true,
      );

      await for (final p in s) {
        if (!mounted) return;
        switch (p) {
          case Progress_Loading():
            setState(() {
              _stage = '加载模型';
              _frac = null;
            });
          case Progress_Page(:final index, :final total):
            setState(() {
              _stage = '识别 $index / $total 页';
              _frac = index / total;
            });
          case Progress_Writing():
            setState(() {
              _stage = '写出文件';
              _frac = 1;
            });
          case Progress_Done(:final report):
            setState(() => _done = report);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _share(String path) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('转成文档'),
        // 跑的时候不让返回: Rust 侧没有中断口子, 界面退了它还在后台算,
        // 不如老老实实等着
        automaticallyImplyLeading: !_running,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${widget.pages.length} 页',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            enabled: !_running,
            decoration: const InputDecoration(
              labelText: '标题',
              helperText: '同时是文件名和 Word 里的大标题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<OutFormat>(
            segments: const [
              ButtonSegment(value: OutFormat.docx, label: Text('Word')),
              ButtonSegment(value: OutFormat.xlsx, label: Text('Excel')),
              ButtonSegment(value: OutFormat.both, label: Text('都要')),
            ],
            selected: {_fmt},
            onSelectionChanged:
                _running ? null : (s) => setState(() => _fmt = s.first),
          ),
          const SizedBox(height: 24),
          if (_running) ...[
            LinearProgressIndicator(value: _frac),
            const SizedBox(height: 8),
            Text(_stage),
            const SizedBox(height: 8),
            Text('第一页要多等一会儿 —— 模型是那时候才真正加载的',
                style: Theme.of(context).textTheme.bodySmall),
          ] else
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.play_arrow),
              label: Text(_done == null ? '开始识别' : '再来一次'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(_error!),
            ),
          ],
          if (_done != null) ...[
            const SizedBox(height: 16),
            _result(_done!),
          ],
        ],
      ),
    );
  }

  Widget _result(ConvertReport r) {
    final files = [
      if (r.docxPath != null) r.docxPath!,
      if (r.xlsxPath != null) r.xlsxPath!,
    ];
    return _Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('完成：${r.pages} 页'
              '${r.tables > 0 ? '，表格 ${r.tables} 张' : ''}'),
          if (r.failed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('有 ${r.failed.length} 页没认出来（其余页照常导出）：',
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
          Text('文件也在「文件」App → 我的 iPad → ScanPdf2Doc → out 里',
              style: Theme.of(context).textTheme.bodySmall),
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
