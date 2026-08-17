import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一个文档在磁盘上就是一个目录
///
/// ```
/// Application Support/docs/
///   20260817-193012/
///     meta.json     名字、页序、下一个页号
///     p001.jpg      页图
///     p002.jpg
/// ```
///
/// 不上 SQLite: 这个 App 的量级是几十上百个文档, 每个几十页, 按名字过滤在内存
/// 里做就够了。一个 JSON 换来的是零依赖、出问题能直接打开看、以及不用维护
/// schema 迁移 —— 后两样在只有一个人维护的项目上比查询性能值钱。
///
/// 放 Application Support 而不是 Documents: Info.plist 开了文件共享,
/// Documents 里的东西会出现在「文件」App 里。导出的成品该露出来(在
/// `Documents/out`), 中间的页图不该 —— 一个 20 页的文档在那儿就是 20 个
/// p0xx.jpg。Application Support 会被 iCloud 备份带走, 对用户数据这是对的。
class Doc {
  Doc({
    required this.id,
    required this.name,
    required this.created,
    required this.updated,
    required this.pages,
    required this.origins,
    required this.nextSeq,
    required this.dir,
  });

  /// 目录名, 建的时候的时间戳
  final String id;
  String name;
  final DateTime created;
  DateTime updated;

  /// 页图文件名(不含路径), 顺序即页序
  final List<String> pages;

  /// 编辑过的页 -> 它那张没动过的原图
  ///
  /// 裁切是不可逆的: 裁窄了再裁一次只会更窄, 没有回头路。所以第一次编辑时把
  /// 当时那张留在磁盘上不删, 「还原」就有的可退。原图不进 pages, 界面上看不见,
  /// 代价是一页多占一份空间 —— 比让用户一次误操作丢掉一页划算。
  final Map<String, String> origins;

  /// 下一页用几号
  ///
  /// 必须存下来单调递增, 不能拿"目录里现有的最大号 + 1"顶替: 删掉第 3 页再加
  /// 一页, 那样会又生成一个 p003.jpg, 而 Flutter 的 `Image.file` 是按路径缓存
  /// 的 —— 缩略图会显示已经删掉的那一页。
  int nextSeq;

  /// 这个文档的目录
  final Directory dir;

  String pagePath(int i) => '${dir.path}/${pages[i]}';

  int get count => pages.length;

  /// 首页图, 列表里当封面用; 空文档返回 null
  String? get cover => pages.isEmpty ? null : pagePath(0);

  Map<String, dynamic> _toJson() => {
        'id': id,
        'name': name,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'pages': pages,
        'origins': origins,
        'nextSeq': nextSeq,
      };

  /// 写回 meta.json
  ///
  /// 先写临时文件再 rename: rename 在同一个卷上是原子的, 直接覆写的话, 万一
  /// 写到一半被系统杀掉(扫描时内存压力大, 这不是假想), 留下的是个残缺 JSON,
  /// 整个文档就打不开了。
  Future<void> save() async {
    updated = DateTime.now();
    final f = File('${dir.path}/meta.json');
    final t = File('${dir.path}/meta.json.tmp');
    await t.writeAsString(jsonEncode(_toJson()), flush: true);
    await t.rename(f.path);
  }

  /// 把外面的图收进这个文档, 返回新增的页数
  ///
  /// 一定要搬进来: 扫描器和 PDF 展开出来的图都落在 temporaryDirectory,
  /// 系统内存紧张时随时会清 —— 存路径进 meta.json 的话, 用户下次打开看到的
  /// 是一列破图图标。
  Future<int> addPages(Iterable<String> srcs) async {
    var n = 0;
    for (final src in srcs) {
      final f = File(src);
      if (!await f.exists()) continue;
      // 相册来的可能是 png/heic, 别一律改叫 .jpg —— 后面解码是看内容不看
      // 后缀, 但文件名对不上内容在排查问题时很误导人
      final ext = src.contains('.') ? src.split('.').last.toLowerCase() : 'jpg';
      final name = 'p${nextSeq.toString().padLeft(3, '0')}.$ext';
      nextSeq++;
      await _move(f, '${dir.path}/$name');
      pages.add(name);
      n++;
    }
    if (n > 0) await save();
    return n;
  }

  /// 这一页编辑过、还留着原图吗
  bool hasOriginal(int i) => origins.containsKey(pages[i]);

  /// 换掉第 i 页
  ///
  /// `produce` 收到一个还没人用过的路径, 把新图写进去。名字是新分配的而不是
  /// 覆写原路径 —— Flutter 的 `Image.file` 按路径缓存, 原地覆写之后界面上还是
  /// 那张老图, 而且没有干净的办法让它知道文件变了。换个名字这个问题就不存在。
  Future<void> replacePage(int i, Future<void> Function(String out) produce) async {
    final old = pages[i];
    final name = 'p${nextSeq.toString().padLeft(3, '0')}.jpg';
    final path = '${dir.path}/$name';
    try {
      await produce(path);
    } catch (_) {
      // 写了一半就失败的话, 别把半张图留在目录里
      await _quietDelete(File(path));
      rethrow;
    }
    nextSeq++;
    // 第一次编辑时把当时那张认作原图; 之后再编辑, 原图一直是最早那张
    final orig = origins[old] ?? old;
    origins.remove(old);
    origins[name] = orig;
    pages[i] = name;
    // 被顶替掉的中间产物删掉, 但原图得留着
    if (old != orig) await _quietDelete(File('${dir.path}/$old'));
    await save();
  }

  /// 退回没编辑过的那张; 本来就没编辑过返回 false
  Future<bool> resetPage(int i) async {
    final cur = pages[i];
    final orig = origins.remove(cur);
    if (orig == null) return false;
    pages[i] = orig;
    await _quietDelete(File('${dir.path}/$cur'));
    await save();
    return true;
  }

  /// 删一页, 连文件一起 —— 留着的原图也一并清掉
  Future<void> removePage(int i) async {
    final name = pages.removeAt(i);
    final orig = origins.remove(name);
    await _quietDelete(File('${dir.path}/$name'));
    if (orig != null && orig != name) {
      await _quietDelete(File('${dir.path}/$orig'));
    }
    await save();
  }

  Future<void> reorder(int from, int to) async {
    pages.insert(to, pages.removeAt(from));
    await save();
  }

  Future<void> rename(String s) async {
    name = s;
    await save();
  }

  /// 整个删掉
  Future<void> destroy() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// 磁盘上那一摞文档
class DocStore {
  static Directory? _root;

  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/docs');
    await d.create(recursive: true);
    _root = d;
    return d;
  }

  /// 全部文档, 最近改过的排前面
  ///
  /// 读不动的目录直接跳过而不是抛错: 一个坏了的 meta.json 不该让整个列表打不开
  static Future<List<Doc>> list() async {
    final r = await root();
    final out = <Doc>[];
    await for (final e in r.list()) {
      if (e is! Directory) continue;
      final d = await _read(e);
      if (d != null) out.add(d);
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  static Future<Doc?> _read(Directory dir) async {
    try {
      final f = File('${dir.path}/meta.json');
      if (!await f.exists()) return null;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final pages = (m['pages'] as List).cast<String>();
      return Doc(
        id: m['id'] as String,
        name: m['name'] as String,
        created: DateTime.parse(m['created'] as String),
        updated: DateTime.parse(m['updated'] as String),
        pages: pages,
        origins: (m['origins'] as Map?)?.cast<String, String>() ?? {},
        // 老数据没有这个字段时退回"页数 + 1", 不是 0 —— 从 0 起会立刻撞名
        nextSeq: m['nextSeq'] as int? ?? pages.length + 1,
        dir: dir,
      );
    } catch (_) {
      return null;
    }
  }

  /// 新建一个空文档
  static Future<Doc> create({String? name}) async {
    final r = await root();
    // 同一秒内连点两次「新建」会撞 id, 撞了就往后顺一位
    var id = stamp();
    var dir = Directory('${r.path}/$id');
    for (var i = 1; await dir.exists(); i++) {
      id = '${stamp()}-$i';
      dir = Directory('${r.path}/$id');
    }
    await dir.create(recursive: true);
    final now = DateTime.now();
    final d = Doc(
      id: id,
      // 兜底就是 id(一串时间戳), 不带任何一种语言的词。这一层拿不到 L,
      // 而两个调用点都是传好名字进来的 —— 这条路实际走不到
      name: name ?? id,
      created: now,
      updated: now,
      pages: [],
      origins: {},
      nextSeq: 1,
      dir: dir,
    );
    await d.save();
    return d;
  }

  /// 删掉建了却一页都没加的空文档
  ///
  /// 用户点「新建」进去又直接返回是很常见的操作, 不收拾的话列表里会攒一堆
  /// 0 页的壳
  static Future<void> dropIfEmpty(Doc d) async {
    if (d.pages.isEmpty) await d.destroy();
  }
}

/// 尽量用 rename 搬, 跨卷了再退回复制
///
/// 页图动辄几 MB, 二十页就是几十 MB。源头(temporaryDirectory)和目的地
/// (Application Support)在 iOS 上是同一个卷, rename 是改个目录项的事,
/// 复制则要把这几十 MB 真读一遍写一遍。
Future<void> _move(File src, String dst) async {
  try {
    await src.rename(dst);
  } on FileSystemException {
    await src.copy(dst);
    await _quietDelete(src);
  }
}

/// 删不掉就算了 —— 清理失败不值得让上层的操作整个失败
Future<void> _quietDelete(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

/// 文件名/文档 id 用的时间戳, 形如 20260817-193012
String stamp() {
  final t = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${p(t.month)}${p(t.day)}-${p(t.hour)}${p(t.minute)}${p(t.second)}';
}
