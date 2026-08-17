# app —— Flutter 端

扫描 → 页面管理 → 导出 PDF / 识别成 Word · Excel。

## 跑起来

模型不在仓库里（32 MB），先放进去：

```sh
./tool/models.sh                       # 默认从 ../../ScannedPdf2doc/models 拿
./tool/models.sh /path/to/models       # 或者自己指目录
```

然后：

```sh
flutter run --release -d <设备>
```

**用 `--release`（或 `--profile`），不要用默认的 debug。** cargokit 把 Flutter 的
debug 直接映射成 cargo 的 debug，未优化的推理一页要几十秒。`rust/Cargo.toml` 里
已经把 `[profile.dev.package."*"]` 提到了 opt-level 3，debug 版勉强能用，但真要
量耗时和内存还是得 release。

## 目录

| 路径 | 是什么 |
|---|---|
| `lib/main.dart` | 入口，`RustLib.init()` 在这里 |
| `lib/src/ui/home.dart` | 主界面：页列表、拖拽排序、删除、四个动作 |
| `lib/src/ui/convert.dart` | 识别界面：选格式、进度、结果与分享 |
| `lib/src/native.dart` | platform channel 的 Dart 侧 |
| `lib/src/models.dart` | 模型：内置的解到 Application Support，语言包按需下载 |
| `lib/src/ui/ocr_lang.dart` | 识别语言：挑语言、下载和删除语言包 |
| `lib/src/rust/` | **codegen 产物**，不要手改 |
| `rust/src/api/convert.rs` | 桥接层：一组页图 → docx/xlsx |
| `ios/Runner/DocScanner.swift` | VisionKit 扫描界面 + 出 PDF |

## 改了 `rust/src/api/` 之后

```sh
flutter_rust_bridge_codegen generate
```

它会连着 `build_runner` 一起跑（`Progress` 是带数据的枚举，Dart 侧要 freezed）。

## 几个决定

**扫描不自己写。** `VNDocumentCameraViewController` 把找页边界、自动抓拍、透视
矫正、连续多页全包了，就是「备忘录」里那个扫描器。自己用 OpenCV 找四边形当然能
做，但做不过它，还要多背一个几 MB 的库。

**图不过 channel，只过路径。** 一页三四 MB，十几页就是几十 MB 的字节在原生和
Dart 之间来回抄，而它们下一步的去处是 Rust —— 传路径就一步到位。

**模型解到 Application Support。** Rust 侧要的是文件路径，而 Flutter 的 asset 在
iOS 上藏在 `App.framework` 里没有稳定路径。代价是磁盘多占 32 MB，换的是 Rust
侧一行平台判断都不用写。放 Application Support 而不是 Documents，是因为它属于
派生数据，不该出现在「文件」App 里；这个目录还会被标上
`isExcludedFromBackup`（`Native.excludeFromBackup`），不然这几十 MB 会去占用户
的 iCloud 空间 —— 而它们全都是能重新弄出来的。

**一个语言包就是一个 rec 模型文件。** 识别认得出哪些字，完全由 rec 那个 `.onnx`
决定：字表是转 ONNX 时写进模型 metadata 的，换个文件就换了一整套字。检测（框在
哪）和方向分类跟语言无关，它们只看笔画怎么分布，不认字。所以「下载韩语包」这件事
在代码里就是多下一个文件、把文件名传给 Rust（`EngineOptions.rec_file`），没有别的。

包从 ModelScope 的 RapidOCR 仓库下，URL 钉死在 `v3.9.2` 这个 tag 上，每个包的
字节数和 sha256 写在 `lib/src/models.dart` 的表里。要加一种语言，就是往那张表里
加一行 —— 但加之前必须确认两件事：

1. **不能用 PP-OCRv3 那批**（`chinese_cht`/`latin`/`cyrillic` 的 v3 版）。它们的
   输入高度是 32，而我们写死的是 48，喂进去直接报维度不符。v4/v5 是 48 或者动态。
2. **字表条数 + 2 要等于模型输出的类数**（`+2` 是首尾的 blank 和空格）。对不上
   说明解析或者模型不对，而这种错不会崩，只会让认出来的每个字都错位。

**内置模型盖不住的只有五种文字。** 实测内置那个 v6 的字表覆盖简繁汉字、日文假名、
拉丁字母（含 ä ö ü ß ñ á é 这些重音）和希腊字母；**一个字都不覆盖**谚文、西里尔、
阿拉伯、泰文、天城文。所以德语西班牙语法语用户不需要下任何东西，韩语用户不下就
什么都认不出来。

**输出放 `Documents/out`。** `Info.plist` 里开了 `UIFileSharingEnabled`，这个目录
在「文件」App 里直接可见，不想用分享面板时可以自己拷出去。

**长边 2560 写死。** 这是识别效果的命门，不做成界面上的开关 —— 随手调低省下来的
那点内存，换的是认错字。

## 还没做

- Android 侧的 platform channel（扫描用 ML Kit Document Scanner，出 PDF 用
  `PdfDocument`）。现在 Android 上 `scannerAvailable()` 回 false，会退到相册导入
- 导入已有 PDF 再识别（要用 `CGPDFDocument` / `PdfRenderer` 拆页）
- 单页重扫、裁剪框微调
