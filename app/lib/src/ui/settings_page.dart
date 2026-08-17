import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../models.dart';
import '../settings.dart';
import 'language.dart';
import 'ocr_lang.dart';
import 'theme.dart';

/// 设置
///
/// 眼下只有两行, 单开一页看着空 —— 但这两行都是"语言", 一个是界面说什么话,
/// 一个是纸上印的是什么字。它们只有并排摆着的时候, 那句"这是两回事"才不用
/// 解释。原先界面语言挂在首页工具栏上, 那个位置再塞第二个就得靠图标去猜谁是谁。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: Readable(
        child: ListView(
          children: [
            ValueListenableBuilder<Locale?>(
              valueListenable: Settings.locale,
              builder: (ctx, cur, _) => ListTile(
                leading: const Icon(Icons.translate),
                title: Text(l.settingsLanguage),
                subtitle: Text(localeName(cur) ?? l.languageSystem),
                onTap: () => askLanguage(ctx),
              ),
            ),
            ValueListenableBuilder<String>(
              valueListenable: Settings.ocrLang,
              builder: (ctx, cur, _) => ListTile(
                leading: const Icon(Icons.spellcheck),
                title: Text(l.settingsOcrLang),
                subtitle: Text(Models.byCode(cur).name(l)),
                onTap: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                    builder: (_) => const OcrLangPage())),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
