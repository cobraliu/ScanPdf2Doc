# ScanPdf2Doc

用手机摄像头扫描纸质文件，导出 PDF，再把 PDF 识别重建成可编辑的 Word / Excel。

识别与版面重建的核心不在这个仓库里，是直接复用桌面版
[ScannedPdf2Doc-rust](https://github.com/cobraliu/ScannedPdf2Doc-rust)。
这个仓库负责的是它前面那一段：拍摄、找边、矫正、组页，以及两端的 UI。

## 计划做的功能

1. 摄像头连续扫描，页可以删除、替换、调换顺序
2. 单页拍摄时自动识别页边界 + 自动做透视和角度矫正
3. 扫完导出 PDF
4. 导出的 PDF 走识别重建，出 docx / xlsx

## 技术选型

| 部分 | 选择 | 理由 |
|---|---|---|
| UI | Flutter，两端一套 | 这个 App 的界面逻辑（页列表、拖拽排序、裁剪框）两端完全一样，没有分头写的必要 |
| 识别 / 版面重建 | Rust 核心，经 flutter_rust_bridge 调用 | 桌面版那套逻辑一行不用重写，两端共用同一份 |
| iOS 扫描 | `VNDocumentCameraViewController`（VisionKit） | 系统自带，找边 / 抓拍 / 矫正 / 多页一整套界面都给了，一行 CV 代码不用写 |
| Android 找边 | ML Kit Document Scanner 优先，OpenCV 兜底 | ML Kit 连拍摄 UI 都给了，但依赖 Google Play 服务；国内机型装不上时退回自己用 OpenCV 找四边形 |
| 生成 PDF | 端上原生 API | iOS `UIGraphicsPDFRenderer` / Android `PdfDocument`，都不需要额外库 |

**移动端不带 pdfium。** 扫描流程里页图本来就在手里，用不着 PDF 渲染器；只有"导入
一个已有 PDF"才需要解析，那个用系统的（`CGPDFDocument` / `PdfRenderer`）就够。
省下 7 MB 库，也省掉 iOS 上嵌入并签名 `.dylib` 的麻烦。这一条已经在 spike 里验证过了。

## 现在做到哪了

**一、Rust 核心的真机可行性验证**（见 [`spike/`](spike/)）。

不写 UI，先把最不确定的一环拿掉：ONNX Runtime 的移动端预编译包有可能是裁过算子的
reduced build，缺算子的话整条路都不成立。结果是三个平台（macOS 原生 / iOS Simulator /
Android arm64）全部跑通，识别出的 31 段文字逐字一致，没有静默降级。

峰值内存原本 574–708 MB，对前台 App 偏高；加了 `EngineOptions::low_memory()` 之后
降到 428–569 MB，识别结果逐字不变。详细数据和复现方式在
[`spike/README.md`](spike/README.md)。

**二、iOS App 能跑了**（见 [`app/`](app/)）。

Flutter + flutter_rust_bridge，功能 1、2、3、4 都在：系统扫描界面（自动找边、自动
抓拍、透视矫正、连续多页）、页列表拖拽排序与删除、导出 PDF、识别成 Word / Excel
并分享。

**下一步**：真机上量耗时和热节流；然后补 Android 侧的 platform channel。
