import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../doc.dart';
import 'settings_page.dart';
import 'pages.dart';
import 'theme.dart';

/// 文档列表 —— App 的首页
///
/// 列表每次进来都从磁盘重读一遍(`DocStore.list()`), 不在内存里留一份镜像。
/// 文档的增删改都发生在下一层, 让两边同步的成本比重读一遍几十个 meta.json
/// 高得多, 而后者在这个量级上根本量不出来。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Doc>? _docs;
  String _q = '';
  bool _searching = false;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final xs = await DocStore.list();
    if (mounted) setState(() => _docs = xs);
  }

  List<Doc> get _shown {
    final xs = _docs ?? const <Doc>[];
    if (_q.isEmpty) return xs;
    final q = _q.toLowerCase();
    return xs.where((d) => d.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _open(Doc d) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DocPage(doc: d)));
    // 进去转了一圈可能一页都没加, 那就别在列表里留个空壳
    await DocStore.dropIfEmpty(d);
    await _reload();
  }

  Future<void> _create() async {
    // 名字在这儿起而不是让 DocStore 兜底: 那一层没有 BuildContext, 拿不到
    // 当前语言, 只能写死一个中文名 —— 而这个名字是要落盘的, 一旦存下来就
    // 跟着这份文档一辈子
    final d = await DocStore.create(name: L.of(context).commonDefaultDocName(stamp()));
    if (!mounted) return;
    await _open(d);
  }

  Future<void> _rename(Doc d) async {
    final s = await askName(context, L.of(context).commonRename, d.name);
    if (s == null) return;
    await d.rename(s);
    await _reload();
  }

  Future<void> _delete(Doc d) async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.homeDeleteTitle),
        content: Text(l.homeDeleteBody(d.name, d.count)),
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
    // 删掉之后列表会少一行, 手上给一下回馈 —— 破坏性操作只有视觉变化的话,
    // 用户会不确定"我刚才那一下到底点中没有"
    await HapticFeedback.mediumImpact();
    await d.destroy();
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.homeDeleted(d.name))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: l.homeSearchHint,
                  border: InputBorder.none,
                  // 清空和退出搜索是两件事: 以前只有一个 X, 想重打一个词
                  // 就得先退出搜索再点开
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.cancel, size: 20),
                          tooltip: l.commonClear,
                          onPressed: () {
                            _search.clear();
                            setState(() => _q = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _q = v),
              )
            : const Text('ScanPdf2Doc'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? l.homeSearchClose : l.homeSearchOpen,
            onPressed: () => setState(() {
              _searching = !_searching;
              _q = '';
              _search.clear();
            }),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l.settingsTitle,
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: _body(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(l.homeNew),
      ),
    );
  }

  Widget _body() {
    final l = L.of(context);
    if (_docs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_docs!.isEmpty) {
      return EmptyHint(
        icon: Icons.folder_open_outlined,
        title: l.homeEmptyTitle,
        hint: l.homeEmptyHint,
        actionLabel: l.commonNewDoc,
        onAction: _create,
      );
    }
    final xs = _shown;
    if (xs.isEmpty) {
      return EmptyHint(
        icon: Icons.search_off_outlined,
        title: l.homeNoMatchTitle,
        hint: l.homeNoMatchHint,
      );
    }
    return Readable(
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView.separated(
          // 底下给 FAB 留出地方, 不然最后一条永远被它压着
          padding: const EdgeInsets.only(top: Ui.gapSm, bottom: 96),
          itemCount: xs.length,
          // 分隔线在暗色下也要看得见, 所以走主题的 divider 而不是自己配灰度
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: Ui.gapMd + Ui.thumbW + Ui.gapMd),
          itemBuilder: (ctx, i) => _tile(xs[i]),
        ),
      ),
    );
  }

  Widget _tile(Doc d) {
    final t = Theme.of(context);
    final l = L.of(context);
    return ListTile(
      key: ValueKey(d.id),
      leading: PageThumb(path: d.cover),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        l.homeSubtitle(l.commonPages(d.count), _when(l, d.updated)),
        style: t.textTheme.bodySmall
            ?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: l.commonMore,
        onSelected: (v) => v == 'rename' ? _rename(d) : _delete(d),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'rename',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(l.commonRename),
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: t.colorScheme.error),
              title: Text(l.commonDelete,
                  style: TextStyle(color: t.colorScheme.error)),
            ),
          ),
        ],
      ),
      onTap: () => _open(d),
    );
  }

  /// 相对时间, 精确到分就够了 —— 列表里没人关心秒
  ///
  /// 30 天以上退回绝对日期。"384 天前"没人能换算成日子, 而这个 App 里
  /// 隔了一年再翻出来的合同, 要的恰恰就是那个日子
  static String _when(L l, DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return l.timeJustNow;
    if (d.inHours < 1) return l.timeMinutesAgo(d.inMinutes);
    if (d.inDays < 1) return l.timeHoursAgo(d.inHours);
    if (d.inDays < 30) return l.timeDaysAgo(d.inDays);
    // 超过一个月就摆日期, 按当前语言的排法: 德语是 17.08.2026, 日语是
    // 2026/08/17。原先那个 2026-08-17 是 ISO 写法 —— 只有写代码的人觉得
    // 它理所当然。日期数据由 GlobalMaterialLocalizations 在挂载时初始化好
    return DateFormat.yMd(l.localeName).format(t);
  }
}
