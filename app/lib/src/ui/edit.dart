import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../doc.dart';
import '../native.dart';
import 'theme.dart';

/// 单页编辑: 转 90° / 拖四个角重裁 / 退回原图
///
/// 拖角这件事在屏幕坐标里做, 提交时归一化成 [0,1] 交给原生 —— 界面按什么尺寸
/// 显示、图本身几千像素, 两边都不用知道对方的事。
class EditPage extends StatefulWidget {
  const EditPage({super.key, required this.doc, required this.index});

  final Doc doc;
  final int index;

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  Doc get _doc => widget.doc;
  int get _i => widget.index;

  /// 四个角, 归一化到 [0,1], 顺序 左上/右上/右下/左下
  ///
  /// 默认就是整张图。VisionKit 已经裁过一遍了, 大多数页进来不用动 —— 默认
  /// 缩进一圈反而逼着每个人都得先拖回去
  List<Offset> _c = const [
    Offset(0, 0),
    Offset(1, 0),
    Offset(1, 1),
    Offset(0, 1),
  ];

  /// 图的像素长宽比, 用来算显示区域。拿不到之前不画角
  double? _aspect;
  bool _busy = false;
  bool _cropping = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  /// 读一遍图的原始尺寸
  ///
  /// 得知道长宽比才能算出图在屏幕上占的那块矩形 —— 角要贴着图的边, 不是贴着
  /// 控件的边。`Image.file` 自己会做等比缩放, 但不告诉我们缩成了多大
  Future<void> _measure() async {
    try {
      final bytes = await File(_doc.pagePath(_i)).readAsBytes();
      final img = await decodeImageFromList(bytes);
      if (mounted) {
        setState(() => _aspect = img.width / img.height);
      }
      img.dispose();
    } catch (_) {
      if (mounted) setState(() => _aspect = 1);
    }
  }

  Future<void> _guard(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// turns: 顺时针转几个 90°。1 = 右转, 3 = 左转
  Future<void> _rotate(int turns) => _guard(() async {
        final src = _doc.pagePath(_i);
        await HapticFeedback.selectionClick();
        await _doc.replacePage(_i, (out) => Native.rotatePage(src, out, turns));
        await _measure();
        if (mounted) setState(() {});
      });

  Future<void> _applyCrop() => _guard(() async {
        final src = _doc.pagePath(_i);
        final v = [for (final p in _c) ...[p.dx, p.dy]];
        await _doc.replacePage(_i, (out) => Native.cropPage(src, out, v));
        _resetCorners();
        await _measure();
        if (mounted) setState(() => _cropping = false);
      });

  Future<void> _restore() => _guard(() async {
        await _doc.resetPage(_i);
        _resetCorners();
        await _measure();
        if (mounted) setState(() => _cropping = false);
      });

  void _resetCorners() {
    _c = const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)];
  }

  @override
  Widget build(BuildContext context) {
    // 整页强制暗色: 判断一张扫描件裁得正不正, 要看的是纸的边缘在哪, 周围
    // 一圈亮色会把眼睛往外拽 —— 系统相册、相机的编辑界面都是黑底, 是同一个
    // 道理。但工具栏和按钮得跟着变, 否则亮色主题的白 AppBar 压在黑画布上,
    // 分割线和图标的对比度全乱
    return Theme(
      data: Ui.dark(),
      child: Builder(builder: (ctx) {
        final t = Theme.of(ctx);
        return Scaffold(
          backgroundColor: t.colorScheme.surfaceContainerLowest,
          appBar: AppBar(
            title: Text('第 ${_i + 1} 页'),
            actions: [
              if (_doc.hasOriginal(_i) && !_cropping)
                TextButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('还原'),
                ),
            ],
          ),
          body: Column(
            children: [
              // 高度固定占着, 不然进度条一出一进整个画布会跳 3 点
              SizedBox(
                height: 3,
                child: _busy ? const LinearProgressIndicator(minHeight: 3) : null,
              ),
              Expanded(child: _canvas()),
              _bar(),
            ],
          ),
        );
      }),
    );
  }

  Widget _canvas() {
    return LayoutBuilder(builder: (ctx, box) {
      final a = _aspect;
      if (a == null) {
        return const Center(child: CircularProgressIndicator());
      }
      // 图按等比缩放贴进这块区域, 留一圈边距好让贴边的角也能拖得动
      const pad = 28.0;
      final w = box.maxWidth - pad * 2;
      final h = box.maxHeight - pad * 2;
      final rw = math.min(w, h * a);
      final rh = rw / a;
      final rect = Rect.fromLTWH(
          pad + (w - rw) / 2, pad + (h - rh) / 2, rw, rh);

      return Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: Image.file(
              File(_doc.pagePath(_i)),
              fit: BoxFit.fill,
              // 屏幕上就这么大, 没必要把四千像素整张解进内存
              cacheWidth: 1600,
              errorBuilder: (_, _, _) =>
                  const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
          if (_cropping) ...[
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _QuadPainter(_c,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
            for (var k = 0; k < 4; k++) _handle(k, rect),
          ],
        ],
      );
    });
  }

  /// 一个可拖的角
  ///
  /// 触摸区做到 44 点见方(苹果的最小可点尺寸), 但只画中间那个小圈 —— 角常常
  /// 就在图的边缘上, 手指盖住的正是要对齐的地方
  Widget _handle(int k, Rect rect) {
    const size = 44.0;
    final p = Offset(rect.left + _c[k].dx * rect.width,
        rect.top + _c[k].dy * rect.height);
    return Positioned(
      left: p.dx - size / 2,
      top: p.dy - size / 2,
      width: size,
      height: size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) {
          setState(() {
            final n = Offset(
              ((_c[k].dx * rect.width + d.delta.dx) / rect.width).clamp(0.0, 1.0),
              ((_c[k].dy * rect.height + d.delta.dy) / rect.height).clamp(0.0, 1.0),
            );
            _c = [..._c]..[k] = n;
          });
        },
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: _cropping
            ? Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _resetCorners();
                                _cropping = false;
                              }),
                      child: const Text('取消'),
                    ),
                  ),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy || !_quadOk ? null : _applyCrop,
                      child: const Text('应用裁切'),
                    ),
                  ),
                ],
              )
            : Row(
                spacing: Ui.gapSm,
                children: [
                  // 补一个左转。以前只有右转, 拍反了的一页要连点三下, 每一下
                  // 都是一次读图-转-写盘, 三次就是三秒多
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _rotate(3),
                      icon: const Icon(Icons.rotate_90_degrees_ccw_outlined),
                      label: const Text('左转'),
                    ),
                  ),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _rotate(1),
                      icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                      label: const Text('右转'),
                    ),
                  ),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _busy ? null : () => setState(() => _cropping = true),
                      icon: const Icon(Icons.crop),
                      label: const Text('裁切'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// 四个角围出来的东西还算个四边形吗
  ///
  /// 拖成一条线或者拧成蝴蝶结时, CIPerspectiveCorrection 会返回一张空图或者
  /// 一张几万像素宽的怪图。按"每条边都够长"挡住, 比事后收拾好
  bool get _quadOk {
    for (var k = 0; k < 4; k++) {
      if ((_c[k] - _c[(k + 1) % 4]).distance < 0.08) return false;
    }
    return true;
  }
}

/// 把四个角连起来, 外面压一层暗色 —— 让人一眼看出留下的是哪块
class _QuadPainter extends CustomPainter {
  _QuadPainter(this.c, {required this.color});

  final List<Offset> c;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [
      for (final p in c) Offset(p.dx * size.width, p.dy * size.height)
    ];
    final quad = Path()..addPolygon(pts, true);

    // 整块盖暗, 再把选中的四边形挖掉
    final mask = Path.combine(
      ui.PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      quad,
    );
    canvas.drawPath(mask, Paint()..color = Colors.black54);
    canvas.drawPath(
      quad,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_QuadPainter old) => old.c != c;
}
