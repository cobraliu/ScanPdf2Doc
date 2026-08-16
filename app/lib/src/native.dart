import 'package:flutter/services.dart';

/// 原生那一侧: 系统扫描界面、出 PDF、读 PDF
///
/// 只有这几件事走 platform channel。它们都强依赖系统 API(VisionKit、
/// UIGraphicsPDFRenderer、CGPDFDocument), Dart 里没有等价物, 硬找第三方包
/// 反而是退步。
class Native {
  static const _ch = MethodChannel('scanpdf2doc/native');

  /// 系统扫描器能不能用。模拟器上是 false —— 没摄像头
  static Future<bool> scannerAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('scannerAvailable') ?? false;
    } on MissingPluginException {
      // Android 侧还没接, 先当成没有, 让 UI 退回相册导入
      return false;
    }
  }

  /// 拉起系统扫描界面, 返回落盘后的页图路径, 顺序即拍摄顺序
  ///
  /// 用户点取消时返回空 list, 不抛异常 —— 取消是正常操作, 不该弹错误框
  static Future<List<String>> scan() async {
    final r = await _ch.invokeListMethod<String>('scan');
    return r ?? const [];
  }

  /// 让用户从「文件」里挑 PDF, 返回复制进沙盒后的路径
  ///
  /// 跟 scan() 一样, 取消时返回空 list 而不是抛异常
  static Future<List<String>> pickPdf() async {
    final r = await _ch.invokeListMethod<String>('pickPdf');
    return r ?? const [];
  }

  /// 把一个 PDF 逐页渲染成页图, 返回页图路径, 顺序即页序
  ///
  /// longEdge 要跟识别时用的一致: 渲得再细, 识别前也会缩回 2560, 只是白白
  /// 多花内存和时间
  static Future<List<String>> pdfPages(String pdf, {int longEdge = 2560}) async {
    final r = await _ch.invokeListMethod<String>('pdfPages', {
      'pdf': pdf,
      'longEdge': longEdge,
    });
    return r ?? const [];
  }

  /// 把一组页图拼成 PDF, 返回 out
  static Future<String> makePdf(List<String> images, String out) async {
    final r = await _ch.invokeMethod<String>('makePdf', {
      'images': images,
      'out': out,
    });
    return r ?? out;
  }
}
