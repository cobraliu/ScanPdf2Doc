import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'theme.dart';

/// 几种增强方式
///
/// 只留四个。扫描类 App 的滤镜列表动辄十几个, 但真正决定一页好不好看的只有
/// 两件事: 底色摊没摊平、字够不够黑 —— 剩下的都是这两件事上的刻度。四个之内
/// 可以横着一排全摆出来, 不用滑, 也不用记哪个是哪个。
enum Enhance {
  auto('auto', Icons.auto_awesome_outlined),
  light('light', Icons.wb_sunny_outlined),
  gray('gray', Icons.gradient_outlined),
  bw('bw', Icons.contrast);

  const Enhance(this.id, this.icon);

  /// 传给原生那侧的名字。故意跟界面上那个词分开 —— 界面上是「黑白」还是
  /// "Schwarzweiß" 跟原生无关, 而这个值是要跨语言稳定的
  final String id;
  final IconData icon;

  String label(L l) => switch (this) {
        Enhance.auto => l.enhanceAuto,
        Enhance.light => l.enhanceLight,
        Enhance.gray => l.enhanceGray,
        Enhance.bw => l.enhanceBw,
      };

  String hint(L l) => switch (this) {
        Enhance.auto => l.enhanceAutoHint,
        Enhance.light => l.enhanceLightHint,
        Enhance.gray => l.enhanceGrayHint,
        Enhance.bw => l.enhanceBwHint,
      };
}

/// 问一句整批用哪种增强; 返回 null 表示取消
///
/// 这里用一张一张摊开的列表而不是编辑页里那排小按钮: 单页可以点错了再点一个
/// 试试, 一次盖掉二十页就不该靠试 —— 每一项后面跟着一句话说清它干什么。
Future<Enhance?> askEnhance(BuildContext context, int pages) {
  return showModalBottomSheet<Enhance>(
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
              padding: const EdgeInsets.fromLTRB(
                  Ui.gapMd, 0, Ui.gapMd, Ui.gapSm),
              child: Text(l.enhanceSheetTitle(pages), style: t.titleLarge),
            ),
            for (final e in Enhance.values)
              ListTile(
                leading: Icon(e.icon),
                title: Text(e.label(l)),
                subtitle: Text(e.hint(l), style: t.bodySmall),
                onTap: () => Navigator.of(ctx).pop(e),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Ui.gapMd, Ui.gapSm, Ui.gapMd, 0),
              child: Text(l.enhanceSheetNote, style: t.bodySmall),
            ),
          ],
        ),
      );
    },
  );
}
