import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../settings.dart';
import 'theme.dart';

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
    // iPad 上不限宽的话, 三组按钮会被拉到 1180 点宽, 每一组之间空出一大片
    constraints: const BoxConstraints(maxWidth: Ui.readable),
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
    final l = L.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(l.exportTitle, style: t.titleLarge),
            const SizedBox(height: 4),
            // A4 和 Letter 不翻译: 这两个是纸张规格的国际写法, 每种语言的
            // 界面上都是这么印的
            _group<String>(
              l.exportSize,
              {'a4': 'A4', 'letter': 'Letter', 'fit': l.exportSizeFit},
              _v.size,
              (s) => setState(() => _v = _v.copyWith(size: s)),
            ),
            Text(
              _v.size == 'fit' ? l.exportSizeFitNote : l.exportSizeFixedNote,
              style: t.bodySmall,
            ),
            const SizedBox(height: 4),
            // 挡位用整数点数当键: double 不能做常量 Map 的键, 而且拿浮点数
            // 比相等本来就不该是选中判据
            _group<int>(
              l.exportMargin,
              {
                0: l.exportMarginNone,
                24: l.exportMarginNarrow,
                48: l.exportMarginNormal,
              },
              _v.margin.round(),
              (s) => setState(() => _v = _v.copyWith(margin: s.toDouble())),
            ),
            const SizedBox(height: 4),
            _group<int>(
              l.exportQuality,
              {
                1600: l.exportQualitySmall,
                2400: l.exportQualityHigh,
                0: l.exportQualityOriginal,
              },
              _v.maxEdge,
              (s) => setState(() => _v = _v.copyWith(maxEdge: s)),
            ),
            Text(
              switch (_v.maxEdge) {
                0 => l.exportQualityOriginalNote,
                <= 1600 => l.exportQuality1600Note,
                _ => l.exportQuality2400Note,
              },
              style: t.bodySmall,
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _v.searchable,
              onChanged: (s) => setState(() => _v = _v.copyWith(searchable: s)),
              title: Text(l.exportSearchable),
              subtitle: Text(
                _v.searchable
                    ? l.exportSearchableOn
                    : l.exportSearchableOff,
                style: t.bodySmall,
              ),
            ),
            const SizedBox(height: Ui.gapSm),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(_v),
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 52),
                  textStyle: t.titleMedium),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(l.pagesActExport),
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
            // M3 默认给的是 40 点高, 差着苹果那条 44 的线。三组按钮竖着排,
            // 手指要在它们之间来回点, 差这 4 点很容易点到隔壁那一组
            style: SegmentedButton.styleFrom(minimumSize: const Size(0, Ui.tap)),
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
