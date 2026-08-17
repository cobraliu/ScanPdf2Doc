import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../doc.dart';
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
    final d = await DocStore.create();
    if (!mounted) return;
    await _open(d);
  }

  Future<void> _rename(Doc d) async {
    final s = await askName(context, '重命名', d.name);
    if (s == null) return;
    await d.rename(s);
    await _reload();
  }

  Future<void> _delete(Doc d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个文档？'),
        content: Text('「${d.name}」的 ${d.count} 页会一起删掉，恢复不了。'
            '已经导出的 PDF / Word 不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
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
        ..showSnackBar(SnackBar(content: Text('已删除「${d.name}」')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜文档名',
                  border: InputBorder.none,
                  // 清空和退出搜索是两件事: 以前只有一个 X, 想重打一个词
                  // 就得先退出搜索再点开
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.cancel, size: 20),
                          tooltip: '清空',
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
            tooltip: _searching ? '退出搜索' : '搜索',
            onPressed: () => setState(() {
              _searching = !_searching;
              _q = '';
              _search.clear();
            }),
          ),
        ],
      ),
      body: _body(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
    );
  }

  Widget _body() {
    if (_docs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_docs!.isEmpty) {
      return EmptyHint(
        icon: Icons.folder_open_outlined,
        title: '还没有文档',
        hint: '一个文档就是一摞扫出来的页，\n可以整份导成 PDF 或者 Word',
        actionLabel: '新建文档',
        onAction: _create,
      );
    }
    final xs = _shown;
    if (xs.isEmpty) {
      return EmptyHint(
        icon: Icons.search_off_outlined,
        title: '没有匹配的文档',
        hint: '换个词试试，搜的是文档名',
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
    return ListTile(
      key: ValueKey(d.id),
      leading: PageThumb(path: d.cover),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${d.count} 页 · ${_when(d.updated)}',
        style: t.textTheme.bodySmall
            ?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (v) => v == 'rename' ? _rename(d) : _delete(d),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('重命名'),
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: t.colorScheme.error),
              title: Text('删除', style: TextStyle(color: t.colorScheme.error)),
            ),
          ),
        ],
      ),
      onTap: () => _open(d),
    );
  }

  /// 相对时间, 精确到分就够了 —— 列表里没人关心秒
  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)}';
  }
}
