# spike —— 移动端可行性验证

不写一行 UI，只回答三个"不真机跑一次就只能靠猜"的问题：

1. ONNX Runtime 的 iOS / Android 预编译包里，PP-OCRv6 用到的算子齐不齐？
2. 一页识别一次要多久？
3. 峰值内存多高？

结论：**三个平台全部跑通，识别结果与桌面版逐字一致。** 需要处理的工程问题有两个：
Android 要随包带一个 `libc++_shared.so`；峰值内存偏高，已压掉一截，见下文。

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

## 峰值内存：怎么在不动分辨率的前提下压下来

700 MB 对前台 App 不安全。前提是**不能靠降分辨率换**——那会直接伤识别质量。
所以先量清楚钱花在哪：

拿一张纯白的同尺寸图喂进去，它跑完检测就返回，识别和分类根本轮不上。结果是
**570 MB**。也就是说，**内存几乎全花在检测这一步**，识别和版面重建只在它上面
又加了 140 MB。

### 开关实测（macOS，长边 2560，每档跑 3 次取最小）

| 配置 | 识别耗时 | 峰值内存 | 文字指纹 |
|---|---|---|---|
| 基线 | 0.45 s | 695 MB | 一致 |
| **`--lazy`** | **0.47 s** | **567 MB** | **一致** |
| `--no-arena` | 0.45 s | 638 MB | 一致 |
| `--lazy --no-arena` | 0.48 s | 628 MB | 一致 |
| `--lazy --no-mempattern` | 0.48 s | 567 MB | 一致 |
| `--lazy --threads 2` | 0.81 s | 569 MB | 一致 |
| `--threads 1` | 1.42 s | 690 MB | 一致 |

**只有 `--lazy` 值得开**，省 128 MB，几乎不花时间。它做的事是让三个 session
轮流上场、用完就放——`run()` 本来就是 det → cls → rec 一段段做完的，谁也不需要
跟别人同时在场。

另外三个开关实测都不该开：

- **关 arena 反而更差**（567 → 628 MB）。lazy 下同时只有一个 session，它那个
  内存池本来就是按需长出来的；关掉之后每块单独 malloc，归还不及时，RSS 的
  高水位反倒更高。
- **memory_pattern** 开不开都是 567 MB。
- **线程从 10 降到 2 只省 1 MB，却慢 1.7 倍。** 内存根本不花在线程上——这条
  值得记住，"降线程省内存"是个很容易想当然的错觉。

### 三平台上 `--lazy` 的效果

| 运行环境 | 基线 | `--lazy` | 省下 |
|---|---|---|---|
| macOS (M5) | 709 MB | 569 MB | 140 MB |
| iOS Simulator | 651 MB | 522 MB | 129 MB |
| Android 模拟器 | 574 MB | 428 MB | 146 MB |

三边的文字指纹全部一致。Android 上 lazy 还顺带快了（1.18 → 0.87 s）。

### 还剩一个杠杆：`--det-max-side`（会改结果，默认不开）

剩下的 500 多 MB 全在检测那一次推理上，而它随输入面积走。检测只负责"文字在哪"，
认字是识别模型的事，**裁剪和识别用的自始至终是整页原图**——所以单独给检测的
输入封个长边，并不等于降识别分辨率。

| `--det-max-side` | 检测输入 | 识别耗时 | 峰值内存 |
|---|---|---|---|
| 不封（现状） | 1248×1760 | 0.63 s | 564 MB |
| 1600 | 1120×1600 | 0.45 s | 449 MB |
| 1280 | 896×1280 | 0.40 s | 318 MB |
| 1024 | 736×1024 | 0.36 s | 290 MB |

省得很多，但**它确实会改结果**，而且方向不是单调变坏。这一页上的全部差异：

| 不封顶 | 封顶后 | 谁对 |
|---|---|---|
| `DemoMain Unit` | `Demo Main Unit` | 封顶后**对了**（不封顶漏了空格） |
| `金额（元)` | `金额（元）`（1600） | 封顶后**对了**（不封顶全半角括号不配对） |
| `品名/Item` | `品名 / Item` | 空格差异，无所谓 |
| `注：` | `注:`（仅 1024） | 封顶后**错了**（全角冒号变半角） |

**一页合成件不能作数。** 要不要开、封到多少，必须拿一批真实拍照件测过再定。
代码和量具都已经就位（`--det-max-side` + 文字指纹），缺的只是样本。

### 顺带修掉的一个真问题：输出不可复现

量内存的过程中发现，**同一个二进制、同一份输入，桌面版跑两次会给出两种不同的
docx**（37939 / 38073 字节交替，同一段落一会儿是缩进段、一会儿是项目符号列表）。

不是浮点抖动，也不是多线程——单线程和 ORT 的 `deterministic` 开关都拦不住。
根因在 `src/layout/para.rs` 的 `mark_bullets`：

```rust
let base = cnt.iter().max_by_key(|(_, &n)| n)   // cnt 是 HashMap
```

Rust 的 HashMap 每个进程哈希种子都不一样，遍历顺序跟着变。只按出现次数取最大，
一旦两个缩进值打平，返回哪个纯看运气，而 `base` 直接决定一个段落算不算列表项。
`layout/grid.rs` 的 `groups.into_values()` 和 `xlsx.rs` 的列宽遍历是同类隐患。

三处都已定死顺序。修完连跑 8 次输出完全一致，且与仓库里 committed 的
`examples/sample_scanned.docx` **逐字节相同**。

这个 bug 跟移动端没关系，v0.1.0 就带着——但"同一份输入两种输出"这件事，
放在"可以慢、不能错"的要求下比内存更要紧。

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
- **攒一批实拍件**，用文字指纹判断 `--det-max-side` 能封到多少而不伤识别率。
  这是把峰值从 570 MB 压到 300 MB 量级的唯一途径，也是目前唯一缺样本的一环
- Android 侧考虑把转换放进独立进程（`android:process=":ocr"`）。它不降内存，
  但能让"被系统杀掉"从丢掉整批扫描降级成只丢当前这一页
