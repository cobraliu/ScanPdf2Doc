import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../models.dart';
import '../settings.dart';
import 'theme.dart';

/// 挑识别语言, 顺带管语言包的下载和删除
///
/// 跟界面语言分开两页, 因为它们是两件不相干的事: 界面说什么话, 跟纸上印的是
/// 什么字没有关系 —— 一个韩国用户可能把界面设成韩语, 却整天在扫中文合同。
///
/// 排版照抄系统里"离线翻译语言"那一类页面: 没下的那行右边挂个下载按钮,
/// 下好的能点着选, 选中的在左边打勾。这是这类"边下边选"的列表已经定型的样子,
/// 没有理由另发明一种。
class OcrLangPage extends StatefulWidget {
  const OcrLangPage({super.key});

  @override
  State<OcrLangPage> createState() => _OcrLangPageState();
}

class _OcrLangPageState extends State<OcrLangPage> {
  /// 已经下好的语言 code
  final _have = <String>{};

  /// 正在下的那个 code -> 进度 0..1
  String? _busy;
  double _frac = 0;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    // 页面退了就别再往一个已经销毁的 State 里 setState。下载本身也跟着断 ——
    // 后台接着下完再存起来听着更好, 但那要一个真正的后台任务, 不是一个
    // 挂在页面上的订阅能保证的; 半吊子的"后台"只会下到一半被系统掐掉
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    final have = <String>{};
    for (final lang in Models.langs) {
      if (await Models.installed(lang)) have.add(lang.code);
    }
    if (!mounted) return;
    setState(() => _have..clear()..addAll(have));
  }

  void _pick(OcrLang lang) {
    Settings.setOcrLang(lang.code);
    setState(() {});
  }

  Future<void> _get(OcrLang lang) async {
    if (_busy != null) return;
    final l = L.of(context);
    setState(() {
      _busy = lang.code;
      _frac = 0;
    });
    final done = Completer<Object?>();
    _sub = Models.download(lang).listen(
      (p) => setState(() => _frac = p),
      onError: done.complete,
      onDone: () => done.complete(null),
      cancelOnError: true,
    );
    final err = await done.future;
    if (!mounted) return;
    setState(() => _busy = null);
    if (err != null) {
      // 这里不套 humanError: 那个的作用是给一句没头没尾的原生报错加个
      // "出错了"的帽子, 而 ocrLangFailed 自己已经是"下载失败: ..."了 ——
      // 套上去就成了"下载失败: 出错了: ..."
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.ocrLangFailed('$err'))));
      return;
    }
    // 下完直接选上 —— 会去点"下载韩语"的人, 要的就是接下来按韩语认。
    // 让他下完再回来点一下那一行, 是白白多要一步
    _have.add(lang.code);
    _pick(lang);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.ocrLangSwitched(lang.name(l)))));
  }

  Future<void> _drop(OcrLang lang) async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.ocrLangDeleteTitle(lang.name(l))),
        content: Text(l.ocrLangDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.commonDelete)),
        ],
      ),
    );
    if (ok != true) return;
    await Models.remove(lang);
    if (!mounted) return;
    setState(() => _have.remove(lang.code));
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsOcrLang)),
      body: Readable(
        child: ValueListenableBuilder<String>(
          valueListenable: Settings.ocrLang,
          builder: (_, cur, _) => ListView(
            padding: const EdgeInsets.only(bottom: Ui.gapLg),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Ui.gapMd, Ui.gapMd, Ui.gapMd, Ui.gapSm),
                child: Text(l.ocrLangIntro,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              for (final lang in Models.langs) _tile(l, lang, cur),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(L l, OcrLang lang, String cur) {
    final t = Theme.of(context);
    final have = _have.contains(lang.code);
    final busy = _busy == lang.code;
    final sel = cur == lang.code;

    return ListTile(
      // 勾放在左边而不是右边: 右边那一列要留给下载和删除, 两种东西挤在
      // 同一列会让"这一行现在是什么状态"看不出来
      leading: SizedBox(
        width: 24,
        child: sel ? Icon(Icons.check, color: t.colorScheme.primary) : null,
      ),
      title: Text(lang.name(l)),
      subtitle: Text(have ? lang.note(l) : '${lang.note(l)} · ${lang.size}'),
      trailing: switch ((busy, have, lang.builtin)) {
        (true, _, _) => SizedBox(
            width: 24,
            height: 24,
            // 有确切进度就画确切的。下载能算出百分比却给个转圈, 是把已经
            // 知道的信息藏起来
            child: CircularProgressIndicator(value: _frac, strokeWidth: 2.5),
          ),
        (_, false, _) => IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: l.ocrLangDownload,
            onPressed: _busy == null ? () => _get(lang) : null,
          ),
        (_, true, false) => IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l.commonDelete,
            onPressed: () => _drop(lang),
          ),
        // 内置那个删不掉, 右边就空着
        _ => const SizedBox(width: 24),
      },
      onTap: busy
          ? null
          : have
              ? () => _pick(lang)
              : (_busy == null ? () => _get(lang) : null),
    );
  }
}
