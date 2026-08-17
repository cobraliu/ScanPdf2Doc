import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../settings.dart';
import 'theme.dart';

/// 每种语言用它自己的写法列出来
///
/// 不翻译成当前界面语言 —— 一个中国人把界面误切到韩语之后, 要找回来靠的是
/// 认出"简体中文"这四个字, 而不是读懂한국어界面里"중국어(간체)"是什么意思。
/// 所有系统的语言列表都是这么做的。
const _langs = <(Locale, String)>[
  (Locale('zh'), '简体中文'),
  (Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'), '繁體中文'),
  (Locale('en'), 'English'),
  (Locale('es'), 'Español'),
  (Locale('de'), 'Deutsch'),
  (Locale('ja'), '日本語'),
  (Locale('ko'), '한국어'),
];

/// 挑界面语言。选完立刻生效 —— Settings.locale 是个 ValueNotifier,
/// MaterialApp 就挂在它上面
Future<void> askLanguage(BuildContext context) async {
  final l = L.of(context);
  final cur = Settings.locale.value;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: Ui.readable),
    // 选中状态和回调都收在 RadioGroup 上, 每个 tile 只留一个 value ——
    // 逐个挂 groupValue/onChanged 那套在 Flutter 3.32 之后已经弃用了
    builder: (ctx) => SafeArea(
      child: RadioGroup<String>(
        groupValue: _key(cur),
        onChanged: (v) {
          Settings.setLocale(
            v == null || v.isEmpty
                ? null
                : _langs.firstWhere((e) => _key(e.$1) == v).$1,
          );
          Navigator.of(ctx).pop();
        },
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: Ui.gapMd),
          children: [
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(Ui.gapMd, 0, Ui.gapMd, Ui.gapSm),
              child: Text(l.settingsLanguage,
                  style: Theme.of(ctx).textTheme.titleLarge),
            ),
            RadioListTile<String>(value: '', title: Text(l.languageSystem)),
            const Divider(height: 1),
            for (final (loc, name) in _langs)
              RadioListTile<String>(value: _key(loc), title: Text(name)),
          ],
        ),
      ),
    ),
  );
}

/// 某个语言自己怎么称呼自己; null(跟随系统)或者认不出来时返回 null
///
/// 给设置页那行副标题用 —— 那行要显示的是"现在是哪种语言", 跟列表里写的
/// 必须是同一个词
String? localeName(Locale? loc) {
  if (loc == null) return null;
  final k = _key(loc);
  for (final (l, name) in _langs) {
    if (_key(l) == k) return name;
  }
  return null;
}

/// 拿字符串当选中判据而不是 Locale 本身
///
/// `Locale('zh')` 和 `Locale.fromSubtags(languageCode: 'zh')` 相等, 但
/// `RadioListTile` 要的是一个能安全比较的值, 而 Locale 的 == 在带不带 script
/// 的两种写法之间容易出意外
String _key(Locale? l) => l?.toLanguageTag() ?? '';
