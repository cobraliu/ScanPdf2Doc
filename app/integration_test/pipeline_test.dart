// 在真机 / 模拟器上把 Dart -> Rust -> docx 这条链路整个跑一遍
//
// 单元测试跑不了这个: 识别在 Rust 侧, 得有真的动态库、真的模型文件、真的
// 文件系统。所以做成 integration test，跑法:
//
//   flutter test integration_test/pipeline_test.dart -d <设备>
//
// 页图是当场画出来的, 不用往仓库里塞样张 —— 也顺带把"画什么就该认出什么"
// 这条断言变得可靠: 文字是我们自己写上去的, 不用猜。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scanpdf2doc/src/models.dart';
import 'package:scanpdf2doc/src/native.dart';
import 'package:scanpdf2doc/src/rust/api/convert.dart';
import 'package:scanpdf2doc/src/rust/frb_generated.dart';

/// 画一张 A4 比例的白底黑字页图
Future<String> drawPage(String path, List<String> lines) async {
  const w = 1240.0, h = 1754.0; // A4 @150dpi
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, const Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

  var y = 200.0;
  for (final line in lines) {
    final tp = TextPainter(
      text: TextSpan(
        text: line,
        style: const TextStyle(color: Colors.black, fontSize: 44),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w - 240);
    tp.paint(canvas, Offset(120, y));
    y += tp.height + 40;
  }

  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final bytes = png!.buffer.asUint8List();
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

/// 手搓一份最简矢量 PDF: 一页 A4, 上半页涂黑, 下半页留白
///
/// 不用 makePdf 造: 它出的是"整页一张图", 导入时会走抠原图那条快路, 正好绕开
/// 这里要守的光栅化。矢量页只能自己拼 —— 好在 PDF 本身是文本格式, 拼一份带
/// 正确 xref 的一页文档也就二十行, 比往仓库里塞个样张干净
Future<String> writeVectorPdf(String path) async {
  const w = 595, h = 842;
  final content = '0 0 0 rg 0 ${h ~/ 2} $w ${h - h ~/ 2} re f\n';
  final objs = <String>[
    '<</Type/Catalog/Pages 2 0 R>>',
    '<</Type/Pages/Kids[3 0 R]/Count 1>>',
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 $w $h]/Contents 4 0 R/Resources<<>>>>',
    '<</Length ${content.length}>>\nstream\n$content\nendstream',
  ];
  final buf = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    // 全是 ASCII, StringBuffer 的 length 就是字节偏移 —— xref 要的正是这个
    offsets.add(buf.length);
    buf.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = buf.length;
  buf.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    buf.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  buf.write('trailer\n<</Size ${objs.length + 1}/Root 1 0 R>>\n'
      'startxref\n$xref\n%%EOF\n');
  await File(path).writeAsString(buf.toString(), flush: true);
  return path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => RustLib.init());

  testWidgets('页图 -> Rust -> docx / xlsx', (tester) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/pipeline-test')..createSync(recursive: true);

    const lines = ['合同编号 2026-0814', '甲方：某某科技有限公司', '金额 12345.67 元'];
    final page = await drawPage('${dir.path}/page1.png', lines);
    expect(File(page).lengthSync(), greaterThan(0));

    final modelDir = await Models.ensure();
    for (final f in Directory(modelDir).listSync()) {
      debugPrint('模型: ${f.path} ${File(f.path).lengthSync()}');
    }

    ConvertReport? report;
    final events = <String>[];
    final t0 = DateTime.now();
    await for (final p in convertImages(
      modelDir: modelDir,
      images: [page],
      outDir: '${dir.path}/out',
      title: 'pipeline',
      format: OutFormat.both,
      longEdge: 2560,
      lowMemory: true,
    )) {
      switch (p) {
        case Progress_Loading():
          events.add('loading');
        case Progress_Page(:final index, :final total):
          events.add('page $index/$total');
        case Progress_Writing():
          events.add('writing');
        case Progress_Done(report: final r):
          report = r;
      }
    }

    debugPrint('一页耗时 ${DateTime.now().difference(t0).inMilliseconds} ms');

    // 进度事件得按顺序到齐 —— UI 上那根进度条全靠它
    expect(events, ['loading', 'page 1/1', 'writing']);

    expect(report, isNotNull);
    expect(report!.failed, isEmpty, reason: '这一页不该失败');
    expect(report.pages, 1);
    expect(report.docxPath, isNotNull);
    expect(report.xlsxPath, isNotNull);
    expect(File(report.docxPath!).lengthSync(), greaterThan(2000));
    expect(File(report.xlsxPath!).lengthSync(), greaterThan(2000));

    final text = docxText(report.docxPath!);
    debugPrint('docx 正文: $text');

    // 逐行比对太脆(识别把"："认成":"就挂了), 按字符算命中率:
    // 画上去的字里有多大比例出现在正文中
    final want = lines.join().replaceAll(' ', '');
    final got = text.replaceAll(RegExp(r'\s'), '');
    final hit = want.split('').where(got.contains).length;
    debugPrint('字符命中 $hit/${want.length}');
    expect(hit / want.length, greaterThan(0.8),
        reason: 'docx 正文跟画上去的字对不上, 识别这条路有问题');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('页图 -> 原生 -> pdf', (tester) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/pdf-test')..createSync(recursive: true);
    final page = await drawPage('${dir.path}/page1.png', ['PDF 导出测试']);

    final out = '${dir.path}/out.pdf';
    await Native.makePdf([page], out);
    final bytes = File(out).readAsBytesSync();
    expect(bytes.length, greaterThan(1000));
    // PDF 的魔数
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  }, timeout: const Timeout(Duration(minutes: 2)));

  // 导入 PDF 这条路: 自己出一份 PDF 再读回来, 兜一圈看字还在不在
  //
  // 之所以能这么测, 是因为 makePdf 出的 PDF 正是"整页一张图"那一类 —— 也就是
  // 读回来时会走抠原图那条快路, 恰好是最该被守住的那条
  testWidgets('pdf -> 页图 -> docx', (tester) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/pdfin-test')..createSync(recursive: true);

    const lines = ['发票号码 20260815', '开票单位：某某贸易公司', '合计 8888.00 元'];
    final src = await drawPage('${dir.path}/src.png', lines);
    final pdf = '${dir.path}/in.pdf';
    await Native.makePdf([src], pdf);

    final pages = await Native.pdfPages(pdf);
    expect(pages, hasLength(1), reason: '一页进去就该一页出来');
    expect(File(pages.first).lengthSync(), greaterThan(1000));

    ConvertReport? report;
    await for (final p in convertImages(
      modelDir: await Models.ensure(),
      images: pages,
      outDir: '${dir.path}/out',
      title: 'pdfin',
      format: OutFormat.docx,
      longEdge: 2560,
      lowMemory: true,
    )) {
      if (p case Progress_Done(report: final r)) report = r;
    }

    expect(report, isNotNull);
    expect(report!.failed, isEmpty);
    final got = docxText(report.docxPath!).replaceAll(RegExp(r'\s'), '');
    final want = lines.join().replaceAll(' ', '');
    final hit = want.split('').where(got.contains).length;
    debugPrint('字符命中 $hit/${want.length}, 正文: $got');
    expect(hit / want.length, greaterThan(0.8),
        reason: '从 PDF 读回来的页认不出原来的字, 导入这条路有问题');
  }, timeout: const Timeout(Duration(minutes: 5)));

  // 矢量 PDF 走的是光栅化那条路, 上面那条测不到 —— makePdf 出的页会被抠原图
  // 快路截胡。这里守的是"页有没有铺满画布":
  //
  // getDrawingTransform 只缩不放。目标 rect 给得比页面大时它返回的 a/d 恒为 1,
  // 只把内容居中。曾经把像素尺寸直接传进去, 结果整页按 72dpi 画完摆在中间,
  // 有效分辨率只剩三分之一 —— 长页勉强还能认, 短页(只有顶上两行字那种)直接
  // 一个框都检不出来, 整页在文档里凭空消失
  testWidgets('矢量 pdf -> 页图: 内容铺满整页, 不是缩在中间', (tester) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/vec-test')..createSync(recursive: true);
    final pdf = await writeVectorPdf('${dir.path}/vec.pdf');

    final pages = await Native.pdfPages(pdf);
    expect(pages, hasLength(1));

    final codec = await ui.instantiateImageCodec(
        await File(pages.first).readAsBytes());
    final img = (await codec.getNextFrame()).image;
    // 595x842pt, 长边 2560 反推出 219dpi, 即 3.0417 倍
    expect(img.width, closeTo(1810, 4));
    expect(img.height, closeTo(2561, 4));

    final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    double darkness(int y0, int y1) {
      var dark = 0, n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = 0; x < img.width; x++) {
          final i = (y * img.width + x) * 4;
          // 灰度够用了, 图上只有纯黑和纯白
          if (px.getUint8(i) < 128) dark++;
          n++;
        }
      }
      return dark / n;
    }

    // 上四分之一该全黑、下四分之一该全白。要是缩在中间, 这两处都是白的,
    // 第一条断言就挂 —— 顺带把 y 轴翻转也一起守住了
    expect(darkness(0, img.height ~/ 4), greaterThan(0.9),
        reason: '页顶不是黑的: 要么没铺满(缩在中间), 要么 y 轴翻反了');
    expect(darkness(img.height * 3 ~/ 4, img.height), lessThan(0.1),
        reason: '页底不是白的: 要么没铺满(缩在中间), 要么 y 轴翻反了');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 把 docx 里的正文抠出来
///
/// docx 是个 zip, 正文在 word/document.xml。文字都在 `<w:t>` 里, 拿正则捞就够
/// 了 —— 这里只是要确认"画上去的字认出来了没有", 不需要真去解析 OOXML
///
/// 必须 utf8.decode: fromCharCodes 会把每个字节当一个码位, 中文全成乱码
String docxText(String path) {
  final zip = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final xml = utf8.decode(zip.findFile('word/document.xml')!.content);
  return RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true)
      .allMatches(xml)
      .map((m) => m.group(1)!)
      .join(' ');
}
