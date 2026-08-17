import 'package:flutter/material.dart';

import '../settings.dart';

/// 导出 PDF 前问一下用什么纸张、留多少边、压不压图
///
/// 选完就记住: 一个人扫的东西通常是一类的(全是合同, 或者全是小票), 每次都
/// 重选一遍是纯粹的重复劳动。返回 null 表示用户取消了导出。
Future<PdfOpts?> askPdfOpts(BuildContext context) async {
  final init = await Settings.pdf();
  if (!context.mounted) return null;
  final v = await showModalBottomSheet<PdfOpts>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _Sheet(init: init),
  );
  if (v != null) await Settings.setPdf(v);
  return v;
}

class _Sheet extends StatefulWidget {
  const _Sheet({required this.init});

  final PdfOpts init;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  late PdfOpts _v = widget.init;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text('导出 PDF', style: t.titleLarge),
            const SizedBox(height: 4),
            _group<String>(
              '页面尺寸',
              const {'a4': 'A4', 'letter': 'Letter', 'fit': '贴合原图'},
              _v.size,
              (s) => setState(() => _v = _v.copyWith(size: s)),
            ),
            Text(
              _v.size == 'fit'
                  ? '纸张跟着图的长宽比走，小票、证件不会孤零零躺在一张 A4 中间'
                  : '图按比例缩放居中，横拍的页自动转成横版纸',
              style: t.bodySmall,
            ),
            const SizedBox(height: 4),
            // 挡位用整数点数当键: double 不能做常量 Map 的键, 而且拿浮点数
            // 比相等本来就不该是选中判据
            _group<int>(
              '页边距',
              const {0: '无', 24: '窄', 48: '常规'},
              _v.margin.round(),
              (s) => setState(() => _v = _v.copyWith(margin: s.toDouble())),
            ),
            const SizedBox(height: 4),
            _group<int>(
              '图片质量',
              const {1600: '省空间', 2400: '高', 0: '原图'},
              _v.maxEdge,
              (s) => setState(() => _v = _v.copyWith(maxEdge: s)),
            ),
            Text(
              switch (_v.maxEdge) {
                0 => '不做任何压缩，文件最大',
                <= 1600 => '长边压到 1600 像素，适合传给别人看',
                _ => '长边压到 2400 像素，打印也够清楚',
              },
              style: t.bodySmall,
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _v.searchable,
              onChanged: (s) => setState(() => _v = _v.copyWith(searchable: s)),
              title: const Text('可搜索'),
              subtitle: Text(
                _v.searchable
                    ? '先认一遍字再出 PDF，一页多花一两秒；出来的文件能搜、能选、能复制'
                    : '出的是纯图片 PDF，搜不到里面的字',
                style: t.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(_v),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('导出'),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行标题加一排单选段
  ///
  /// 用 SegmentedButton 而不是下拉框: 每组就三个选项, 摊开来一眼能看全,
  /// 点一下就完事, 而下拉框是"点开-找-点选"三步
  Widget _group<T>(
      String title, Map<T, String> opts, T cur, ValueChanged<T> onPick) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [
              for (final e in opts.entries)
                ButtonSegment(value: e.key, label: Text(e.value)),
            ],
            selected: {cur},
            onSelectionChanged: (s) => onPick(s.first),
          ),
        ),
      ],
    );
  }
}
