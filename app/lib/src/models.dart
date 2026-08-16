import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 三个 ONNX 模型的落地
///
/// Rust 侧要的是一个目录路径, 而 Flutter 的 asset 在 iOS 上藏在
/// App.framework 里, 没有稳定可用的文件路径 —— 所以首次启动时抄一份到
/// Application Support。代价是磁盘上多占 32 MB, 换的是 Rust 侧一行平台判断
/// 都不用写。
///
/// Application Support 而不是 Documents: 这是派生数据, 不该出现在"文件"App
/// 里让用户看见, 也不该被 iCloud 备份带走。
class Models {
  static const _files = [
    'PP-OCRv6_det_small.onnx',
    'PP-OCRv6_rec_small.onnx',
    'ch_ppocr_mobile_v2.0_cls_mobile.onnx',
  ];

  static String? _dir;

  /// 返回模型目录, 首次调用会解包。多次调用只解一次
  static Future<String> ensure() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/models');
    await dir.create(recursive: true);

    for (final name in _files) {
      final f = File('${dir.path}/$name');
      final data = await rootBundle.load('assets/models/$name');
      // 按字节数判等而不是只看存在: 换了一版模型重装上来, 大小对不上就重写。
      // 算哈希更严谨, 但为此每次启动读 32 MB 不值
      if (await f.exists() && await f.length() == data.lengthInBytes) continue;
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    _dir = dir.path;
    return dir.path;
  }
}
