import 'dart:io';

import 'package:flutter/material.dart';

import '../doc.dart';
import 'pages.dart';

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

  @override
  void initState() {
    super.initState();
    _reload();
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
    await d.destroy();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜文档名',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _q = v),
              )
            : const Text('ScanPdf2Doc'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _q = '';
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
    if (_docs!.isEmpty) return const _Empty();
    final xs = _shown;
    if (xs.isEmpty) return const Center(child: Text('没有匹配的文档'));
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        // 底下给 FAB 留出地方, 不然最后一条永远被压着
        padding: const EdgeInsets.only(top: 8, bottom: 88),
        itemCount: xs.length,
        itemBuilder: (ctx, i) => _tile(xs[i]),
      ),
    );
  }

  Widget _tile(Doc d) {
    return ListTile(
      key: ValueKey(d.id),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 48,
          height: 62,
          child: d.cover == null
              ? Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.description_outlined, size: 20),
                )
              // cacheWidth 同页列表那边: 不给的话每张封面都会把整张四千像素的
              // 照片解成位图放进内存
              : Image.file(
                  File(d.cover!),
                  fit: BoxFit.cover,
                  cacheWidth: 140,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                ),
        ),
      ),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${d.count} 页 · ${_when(d.updated)}'),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'rename' ? _rename(d) : _delete(d),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
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

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Icon(Icons.folder_open_outlined,
              size: 72, color: Theme.of(context).colorScheme.outline),
          const Text('还没有文档'),
          Text('点右下角「新建」开始扫描',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
