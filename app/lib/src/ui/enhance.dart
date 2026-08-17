import 'package:flutter/material.dart';

import 'theme.dart';

/// 几种增强方式
///
/// 只留四个。扫描类 App 的滤镜列表动辄十几个, 但真正决定一页好不好看的只有
/// 两件事: 底色摊没摊平、字够不够黑 —— 剩下的都是这两件事上的刻度。四个之内
/// 可以横着一排全摆出来, 不用滑, 也不用记哪个是哪个。
enum Enhance {
  auto('auto', '自动', Icons.auto_awesome_outlined, '摊平底色、去掉阴影，颜色留着。多数情况选它'),
  light('light', '增亮', Icons.wb_sunny_outlined, '只提一点亮度，最接近原样'),
  gray('gray', '灰度', Icons.gradient_outlined, '去掉颜色，印章和照片的层次还在'),
  bw('bw', '黑白', Icons.contrast, '字最黑纸最白，纯文字件用这个，PDF 也最小');

  const Enhance(this.id, this.label, this.icon, this.hint);

  /// 传给原生那侧的名字
  final String id;
  final String label;
  final IconData icon;
  final String hint;
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
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: Ui.gapMd),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Ui.gapMd, 0, Ui.gapMd, Ui.gapSm),
              child: Text('增强这 $pages 页', style: t.titleLarge),
            ),
            for (final e in Enhance.values)
              ListTile(
                leading: Icon(e.icon),
                title: Text(e.label),
                subtitle: Text(e.hint, style: t.bodySmall),
                onTap: () => Navigator.of(ctx).pop(e),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Ui.gapMd, Ui.gapSm, Ui.gapMd, 0),
              child: Text(
                '每一页原来的样子都留着，进这一页点「还原」就能退回去',
                style: t.bodySmall,
              ),
            ),
          ],
        ),
      );
    },
  );
}
