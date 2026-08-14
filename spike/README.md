# spike —— 移动端可行性验证

不写一行 UI，只回答三个"不真机跑一次就只能靠猜"的问题：

1. ONNX Runtime 的 iOS / Android 预编译包里，PP-OCRv6 用到的算子齐不齐？
2. 一页识别一次要多久？
3. 峰值内存多高？

结论：**三个平台全部跑通，识别结果与桌面版逐字一致。** 唯一需要处理的工程问题是
Android 要随包带一个 `libc++_shared.so`。

## 实测结果

同一张图（1240×1755 的合同页），同一批模型，长边 2560：

| 运行环境 | 核心数 | 建 session | 识别 | 版面重建 | 峰值内存 | 识别出的文字段 |
|---|---|---|---|---|---|---|
| macOS (M5, 原生) | 10 | 0.08 s | 0.47 s | 0.01 s | 708 MB | 31 |
| iOS Simulator (iPhone 17 Pro) | 10 | 0.16 s | 0.76 s | 0.01 s | 651 MB | 31 |
| Android 模拟器 (arm64-v8a, API 35) | 4 | 0.11 s | 1.11 s | 0.01 s | 574 MB | 31 |

三边识别出的文字**完全相同**（`EXAMPLE CORP` / `SAMPLE DOCUMENT` / `四、供货清单/ LIST OF SUPPLY` …），
置信度也一致 —— 说明移动端的 ORT 包不是裁过算子的 reduced build，没有静默降级。

**这些耗时不是手机的耗时。** 模拟器跑在 Mac 的 CPU 上，Android 模拟器用的是
arm64 原生镜像，两者都不受手机的散热和调度限制。真机数字必须插上设备再测一遍，
这里的数据只用来回答"算子齐不齐"和"内存量级"。

### 内存随长边的变化（macOS 实测，`/usr/bin/time -l` 交叉验证过）

| `--long-edge` | 实际尺寸 | 识别耗时 | 峰值内存 | 文字段 |
|---|---|---|---|---|
| 2560 | 1240×1755 | 0.47 s | 708 MB | 31 |
| 2000 | 1240×1755 | 0.45 s | 709 MB | 31 |
| 1600 | 1130×1600 | 0.42 s | 585 MB | 31 |
| 1280 | 904×1280 | 0.36 s | 449 MB | 31 |
| 1024 | 723×1023 | 0.34 s | 377 MB | 31 |

2560 和 2000 没差别，是因为识别引擎内部本来就把检测输入压到最长边 2000
（`MAX_SIDE`），再往上调只是白白多占解码内存。

**峰值内存是这套方案在手机上最需要盯的一项。** 700 MB 对前台 App 来说不安全，
低端机和 Android 后台回收会直接杀进程。降长边能线性地换下来，但上面这张表用的是
一页很干净的合成件，文字密度低；真实拍照件降到多少还能保住识别率，得拿实拍样张
单独测一轮。

## 怎么跑

只需要额外准备三个 `.onnx` 模型（下载方式见
[桌面版仓库](https://github.com/cobraliu/ScannedPdf2Doc-rust) 的 README）。
样张 `testdata/sample_page.png` 已经在仓库里 —— 是一页脱敏的合成合同，
上面的实测数据全部出自它。

```bash
M=path/to/models

# 本机
cargo run --release -- $M testdata/sample_page.png out.docx [--long-edge N]

# iOS 模拟器 (需要 Xcode; 换设备用 SIM_DEVICE=... 覆盖)
./run-ios-sim.sh $M testdata/sample_page.png

# Android 模拟器 / 真机 (需要 adb 能看到设备, 以及一份 NDK)
./run-android.sh $M testdata/sample_page.png
```

两个脚本都自带交叉编译：会先 `rustup target add`，再按目标平台构建，
最后把二进制推过去执行。Android 那个还会顺手把 `libc++_shared.so` 一并推上去。

## 这个 spike 顺带验证了什么

**移动端不需要 pdfium。** 整条流水线走的是 `Engine::run(&Gray)` →
`layout::analyze` → `docx`，压根没碰 `Converter`（那个才要 PDF 渲染器）。
扫描流程里页图本来就在手里，用不着解析 PDF —— 省下 7 MB 库，也省掉 iOS 上
嵌入并签名 `.dylib` 的麻烦。只有"导入一个已有 PDF 来转换"才需要渲染器，
那个可以直接用系统的（iOS `CGPDFDocument` / Android `PdfRenderer`）。

## 已知的工程问题

1. **Android 必须随包带 `libc++_shared.so`**（NDK sysroot 里那个，8.8 MB）。
   不带的话进程起不来，报 `CANNOT LINK EXECUTABLE ... library "libc++_shared.so" not found`。
   正式打包时 Gradle 的 `externalNativeBuild` 会自动带上，这里手工推是因为
   spike 直接跑的裸可执行文件。
2. **二进制 19–21 MB**（strip 过，含静态链进去的 ONNX Runtime），加 32 MB 模型，
   单 ABI 约 52 MB。Android 要按 ABI 分包（App Bundle 自动做）。
3. **`pdfium-render` 目前仍被编进去**，虽然运行时一次都不加载。上游把它改成
   可选特性之后能再瘦一圈。

## 下一步

- 插真机测一遍，拿到真实耗时和热节流下的表现
- 用实拍照片（不是渲染出来的干净页）测长边降到多少还能保住识别率
- 把 `long_edge` 定下来之后，再决定要不要为手机单独调一套默认参数
