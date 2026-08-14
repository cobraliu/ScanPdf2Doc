//! 移动端可行性验证 —— 不写一行 UI, 只回答三个问题
//!
//! 1. ORT 的 iOS / Android 预编译包里, PP-OCRv6 用到的算子齐不齐?
//!    移动端的 ONNX Runtime 有可能是裁过算子的 reduced build, 真缺了就建不出
//!    session。这一条只能在目标平台上跑一次才知道, 推测没有意义。
//! 2. 一页真实照片识别一次要多久?
//! 3. 峰值内存多高? —— 手机上这条比耗时更容易致命, 超了直接被系统杀掉。
//!
//! 故意绕开 Converter: 它要 pdfium 打开 PDF, 而扫描流程里页图本来就在手里,
//! 根本不需要 PDF 渲染器。这条路子跑通, 等于顺便验证了"移动端不带 pdfium"
//! 这个架构选择 —— 能省下 7 MB 库和 iOS 上嵌入 dylib 的签名麻烦。

use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use scannedpdf2doc::config::Config;
use scannedpdf2doc::imgutil::Gray;
use scannedpdf2doc::{docx, layout, ocr, render};

fn main() {
    if let Err(e) = run() {
        eprintln!("失败: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 {
        eprintln!("用法: spike <模型目录> <照片.jpg> [输出.docx] [--long-edge N]");
        std::process::exit(2);
    }
    let models = PathBuf::from(&a[1]);
    let photo = PathBuf::from(&a[2]);
    let out = a
        .get(3)
        .filter(|s| !s.starts_with("--"))
        .map(PathBuf::from);
    let mut cfg = Config::default();
    if let Some(i) = a.iter().position(|s| s == "--long-edge") {
        cfg.long_edge = a
            .get(i + 1)
            .and_then(|v| v.parse().ok())
            .ok_or_else(|| anyhow!("--long-edge 后面要跟一个数"))?;
    }

    println!("目标平台: {}", std::env::consts::ARCH);
    println!("可用核心: {}", threads());
    println!("长边设定: {} px\n", cfg.long_edge);

    // ---- 1. 建三个 ONNX session ----
    // 这一步过了, 第一个问题就答完了: 算子不齐会在这里报错而不是产生坏结果
    let t = Instant::now();
    let mut engine = ocr::Engine::load(&models).context("加载模型")?;
    let t_load = t.elapsed();
    println!("✓ 三个 session 建成功, 耗时 {:.2}s  (算子齐)", t_load.as_secs_f32());

    // ---- 2. 读照片, 缩到目标长边 ----
    let t = Instant::now();
    let img = to_gray(&photo, cfg.long_edge)?;
    let t_img = t.elapsed();
    println!(
        "✓ 照片 {}x{}, 解码+缩放 {:.2}s",
        img.w,
        img.h,
        t_img.as_secs_f32()
    );

    // ---- 3. 识别 ----
    let t = Instant::now();
    let items = engine.run(&img).context("识别")?;
    let t_ocr = t.elapsed();
    println!("✓ 识别出 {} 段文字, 耗时 {:.2}s", items.len(), t_ocr.as_secs_f32());
    if items.is_empty() {
        return Err(anyhow!(
            "一段文字都没识别出来 —— 算子虽然齐, 但结果不对, 这比报错更需要查"
        ));
    }
    // 打几条出来看: session 建得起来不代表算出来的是对的, 裁过的算子有可能
    // 静默给出垃圾结果, 只有人眼看一眼文字才作数
    println!("  前几条:");
    for it in items.iter().take(5) {
        println!("    [{:.2}] {}", it.s, one_line(&it.t));
    }

    // ---- 4. 版面重建 + 出 docx ----
    let t = Instant::now();
    let page = layout::analyze(&items, &img, &cfg);
    let t_layout = t.elapsed();
    println!(
        "✓ 版面重建 {} 个块 (页眉页脚 {} 行), 耗时 {:.2}s",
        page.blocks.len(),
        page.header.len() + page.footer.len(),
        t_layout.as_secs_f32()
    );

    let t = Instant::now();
    let mut doc = docx::Docx::new(&cfg, img.w > img.h);
    let mut st = render::State::default();
    render::render_page(&mut doc, &page, 1, &cfg, &mut st);
    let bytes = match &out {
        Some(p) => {
            // Docx::save 用的是 create_new(桌面版"绝不覆盖"那条规矩),
            // spike 要反复跑, 先清掉旧的
            let _ = std::fs::remove_file(p);
            doc.save(p).context("写 docx")?;
            std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
        }
        None => {
            let tmp = std::env::temp_dir().join("spike-out.docx");
            let _ = std::fs::remove_file(&tmp);
            doc.save(&tmp).context("写 docx")?;
            let n = std::fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0);
            let _ = std::fs::remove_file(&tmp);
            n
        }
    };
    let t_docx = t.elapsed();
    println!("✓ docx {} KB, 耗时 {:.2}s", bytes / 1024, t_docx.as_secs_f32());

    // ---- 小结 ----
    let total = t_load + t_img + t_ocr + t_layout + t_docx;
    println!("\n---- 单页小结 ----");
    println!("  加载模型   {:>6.2}s   (只付一次, 批量时可忽略)", t_load.as_secs_f32());
    println!("  解码缩放   {:>6.2}s", t_img.as_secs_f32());
    println!("  识别       {:>6.2}s   <- 大头", t_ocr.as_secs_f32());
    println!("  版面重建   {:>6.2}s", t_layout.as_secs_f32());
    println!("  出 docx    {:>6.2}s", t_docx.as_secs_f32());
    println!("  合计       {:>6.2}s", total.as_secs_f32());
    let per_page = t_img + t_ocr + t_layout + t_docx;
    println!(
        "  除去加载模型, 每页 {:.2}s -> 20 页约 {:.0}s, 96 页约 {:.0}s",
        per_page.as_secs_f32(),
        per_page.as_secs_f32() * 20.0,
        per_page.as_secs_f32() * 96.0
    );
    println!("  峰值内存   {:>6.1} MB", peak_rss_mb());
    Ok(())
}

/// 读图 -> 灰度 -> 缩到长边 long_edge
///
/// 用核心自己的 resize 而不是 image crate 的: 识别效果跟重采样方式有关,
/// 这里要跟桌面版走同一条路, 否则量出来的耗时和识别率都不可比。
fn to_gray(p: &Path, long_edge: u32) -> Result<Gray> {
    let im = image::open(p).with_context(|| format!("打开 {}", p.display()))?;
    let l8 = im.to_luma8();
    let (w, h) = (l8.width() as usize, l8.height() as usize);
    let src = Gray { w, h, px: l8.into_raw() };
    let long = w.max(h);
    if long <= long_edge as usize || long == 0 {
        return Ok(src);
    }
    let k = long_edge as f64 / long as f64;
    let (nw, nh) = (((w as f64 * k) as usize).max(1), ((h as f64 * k) as usize).max(1));
    Ok(ocr::resize(&src, nw, nh))
}

fn threads() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0)
}

fn one_line(s: &str) -> String {
    let t: String = s.chars().take(40).collect();
    t.replace(['\n', '\r'], " ")
}

/// 进程峰值常驻内存
///
/// ru_maxrss 的单位两家不一样: Apple 给字节, Linux/Android 给 KB。
/// 这个坑不写清楚, 量出来的数会差 1024 倍。
fn peak_rss_mb() -> f64 {
    unsafe {
        let mut u: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut u) != 0 {
            return f64::NAN;
        }
        let v = u.ru_maxrss as f64;
        if cfg!(target_vendor = "apple") {
            v / 1_048_576.0
        } else {
            v / 1024.0
        }
    }
}
