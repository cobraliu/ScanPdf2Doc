//! 一组页图 -> docx / xlsx
//!
//! 跟桌面版 `Converter::convert` 是同一条流水线, 差别只在入口: 那边从 PDF 里
//! 渲染出页图, 这边页图本来就在手里(相机刚拍的)。所以这里不碰 pdfium ——
//! 手机上省下 7 MB 库, iOS 上还省掉嵌入并签名 .dylib 的麻烦。

use std::path::{Path, PathBuf};

use crate::frb_generated::StreamSink;
use anyhow::{anyhow, Context, Result};
use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageReader};
use scannedpdf2doc::config::Config;
use scannedpdf2doc::imgutil::Gray;
use scannedpdf2doc::layout::Page;
use scannedpdf2doc::ocr::{Engine, EngineOptions};
use scannedpdf2doc::{docx, layout, ocr, render, xlsx};

/// 要出什么文件
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutFormat {
    Docx,
    Xlsx,
    Both,
}

/// 转换过程中回给 UI 的进度
///
/// 手机上这条链路一页要一两秒, 十几页就是半分钟 —— 没有进度条的话用户会以为
/// 卡死了, 直接切走, 而切走正是最容易被系统杀掉的时机。
#[derive(Debug, Clone)]
pub enum Progress {
    /// 正在加载三个 ONNX 模型
    Loading,
    /// 正在识别第 index 页(从 1 数), 共 total 页
    Page { index: u32, total: u32 },
    /// 正在写出文件
    Writing,
    /// 全部做完, 带上结果。走流的最后一个事件, 不用函数返回值 ——
    /// flutter_rust_bridge 里带 StreamSink 的函数在 Dart 侧就是个 Stream,
    /// 返回值传不回去
    Done { report: ConvertReport },
}

/// 一次转换的结果
#[derive(Debug, Clone)]
pub struct ConvertReport {
    pub docx_path: Option<String>,
    pub xlsx_path: Option<String>,
    /// 成功识别的页数
    pub pages: u32,
    /// 识别到的表格张数(只在出 xlsx 时有意义)
    pub tables: u32,
    /// 失败的页, 每条形如 "第 3 页: ..."。失败不中断, 其余页照出
    pub failed: Vec<String>,
}

/// 把一组页图转成 docx / xlsx
///
/// - `model_dir` 放三个 .onnx 的目录; App 启动时从 bundle 里解出来
/// - `images` 按最终页序排好的图片路径, 顺序即页序
/// - `low_memory` 见 EngineOptions::low_memory(): 峰值省 ~130 MB, 几乎不费时间。
///   手机上没有理由关掉它
#[allow(clippy::too_many_arguments)]
pub fn convert_images(
    model_dir: String,
    images: Vec<String>,
    out_dir: String,
    title: String,
    format: OutFormat,
    long_edge: u32,
    low_memory: bool,
    sink: StreamSink<Progress>,
) -> Result<()> {
    let report = convert_inner(
        &model_dir,
        &images,
        &out_dir,
        &title,
        format,
        long_edge,
        low_memory,
        &mut |p| {
            let _ = sink.add(p);
        },
    )?;
    let _ = sink.add(Progress::Done { report });
    Ok(())
}

/// 给 examples / 集成测试用的直通口子: 按手机上那套默认参数跑一遍, 出 docx
///
/// 单独开一个而不是把 convert_inner 设成 pub, 是因为 convert_inner 的八个
/// 参数里有一半在验证时永远是同一个值, 每次都抄一遍容易抄错。
#[doc(hidden)]
pub fn convert_for_test(
    model_dir: &str,
    images: &[String],
    out_dir: &str,
    title: &str,
) -> Result<ConvertReport> {
    convert_inner(
        model_dir,
        images,
        out_dir,
        title,
        OutFormat::Docx,
        2560,
        true,
        &mut |p| println!("  {p:?}"),
    )
}

/// 真正干活的那个, 进度用回调而不是 StreamSink
///
/// 分出来是为了能在电脑上直接测: StreamSink 是 flutter_rust_bridge 生成的,
/// 只有 Dart 那侧跑起来才造得出。整条流水线不该因此只能靠往手机上装来验。
#[allow(clippy::too_many_arguments)]
fn convert_inner(
    model_dir: &str,
    images: &[String],
    out_dir: &str,
    title: &str,
    format: OutFormat,
    long_edge: u32,
    low_memory: bool,
    on: &mut dyn FnMut(Progress),
) -> Result<ConvertReport> {
    if images.is_empty() {
        return Err(anyhow!("一页都没有"));
    }
    let out_dir = PathBuf::from(out_dir);
    std::fs::create_dir_all(&out_dir).with_context(|| format!("建目录 {}", out_dir.display()))?;

    // 这里原先把 footer_y 顶到 1.0, 为的是关掉"位置靠下就算页脚"那条:
    // VisionKit 贴着纸边裁, 实测一份合同的最后一行落在 0.938..0.957(置信度
    // 0.99), 正好被那条线整行吃掉。核心现在改成了"位置对 + 内容像"两个都要,
    // 那个先验没了, 这个绕行也就不用了 —— 再顶到 1.0 反而连页码都滤不掉。
    let cfg = Config {
        long_edge,
        ..Config::default()
    };

    on(Progress::Loading);
    let opts = if low_memory {
        EngineOptions::low_memory()
    } else {
        EngineOptions::default()
    };
    let mut engine = Engine::load_with(Path::new(model_dir), opts).context("加载模型")?;

    // 先读第一页定纸张方向 —— docx 的页面设置是整篇一个值, 得在建文档前就知道
    let total = images.len();
    let first = load_gray(Path::new(&images[0]), cfg.long_edge)?;
    let landscape = first.w > first.h;

    let mut doc = matches!(format, OutFormat::Docx | OutFormat::Both).then(|| {
        let mut d = docx::Docx::new(&cfg, landscape);
        d.para(
            title,
            &docx::Fmt::new(16.0).bold(true),
            0,
            docx::Align::Center,
            false,
        );
        d
    });
    let mut book =
        matches!(format, OutFormat::Xlsx | OutFormat::Both).then(|| xlsx::Book::new(title));
    let mut st = render::State::default();
    let mut failed = Vec::new();
    let mut ok_pages = 0u32;

    // 第一趟: 识别 + 攒缩进档位; 排版留到第二趟。缩进的零点要看全文最靠左的
    // 那一档, 边识别边排就只能拿前几页的数据当全文用, 同一个横坐标在前后两页
    // 会落到不同的缩进级(详见 render::scan_indents)。
    let mut laid: Vec<Result<Page, String>> = Vec::with_capacity(total);
    for (i, path) in images.iter().enumerate() {
        let no = i + 1;
        on(Progress::Page {
            index: no as u32,
            total: total as u32,
        });
        // 第一页刚才已经读过了, 别再解一次
        let page = if i == 0 {
            one_page(&mut engine, &first, &cfg)
        } else {
            load_gray(Path::new(path), cfg.long_edge).and_then(|g| one_page(&mut engine, &g, &cfg))
        };
        match page {
            Ok(p) => {
                ok_pages += 1;
                render::scan_indents(&mut st, &p, &cfg);
                // xlsx 不吃缩进, 顺手就写了
                if let Some(b) = book.as_mut() {
                    b.add_page(&p, no);
                }
                laid.push(Ok(p));
            }
            Err(e) => {
                // 一页坏掉不该毁掉整批 —— 用户扫了二十页, 第七页糊了,
                // 该拿到另外十九页, 而不是一个错误弹窗
                let msg = format!("{e:#}");
                failed.push(format!("第 {no} 页: {msg}"));
                if let Some(b) = book.as_mut() {
                    b.page_failed(no, &msg);
                }
                laid.push(Err(msg));
            }
        }
    }

    // 第二趟: 零点定下来了, 再排版
    if let Some(d) = doc.as_mut() {
        for (i, r) in laid.iter().enumerate() {
            let no = i + 1;
            match r {
                Ok(p) => {
                    if cfg.page_marker {
                        render::page_marker(d, p, no, &mut st);
                    }
                    render::render_page(d, p, no, &cfg, &mut st);
                }
                Err(msg) => render::page_failed(d, no, msg, &mut st),
            }
        }
    }

    on(Progress::Writing);
    let mut report = ConvertReport {
        docx_path: None,
        xlsx_path: None,
        pages: ok_pages,
        tables: 0,
        failed,
    };
    if let Some(d) = doc {
        let p = vacant(&out_dir, title, "docx");
        d.save(&p)?;
        report.docx_path = Some(p.to_string_lossy().into_owned());
    }
    if let Some(b) = book {
        let p = vacant(&out_dir, title, "xlsx");
        report.tables = b.save(&p)? as u32;
        report.xlsx_path = Some(p.to_string_lossy().into_owned());
    }
    Ok(report)
}

/// 识别 + 版面重建一页
fn one_page(engine: &mut Engine, img: &Gray, cfg: &Config) -> Result<Page> {
    let items = engine.run(img).context("识别")?;
    Ok(layout::analyze(&items, img, cfg))
}

/// 读图 -> 摆正 -> 灰度 -> 缩到长边 long_edge
///
/// 用核心自己的 resize 而不是 image crate 的: 识别效果跟重采样方式有关,
/// 这里要跟桌面版走同一条路, 否则同一份扫描件两端出来的结果对不上。
///
/// EXIF 方向必须自己应用。iOS 这边竖着拍一页, VisionKit 交出来的 JPEG 像素
/// 常常是横着存的, 靠 EXIF Orientation 标记让阅读器转回来 —— Swift 那侧画
/// PDF 用的是 UIImage, 它认这个标记, 所以导出的 PDF 是正的; image crate 不认,
/// 拿到的就是一张躺倒的页。躺倒之后每行字会被识别器逐框转正(所以字是对的),
/// 但行与行在图里从右往左排, 出来的正文整篇倒序 —— 这个坑很难从结果反推。
pub(crate) fn load_gray(p: &Path, long_edge: u32) -> Result<Gray> {
    let mut dec = ImageReader::open(p)
        .with_context(|| format!("打开 {}", p.display()))?
        .with_guessed_format()
        .with_context(|| format!("认格式 {}", p.display()))?
        .into_decoder()
        .with_context(|| format!("解码 {}", p.display()))?;
    // 没有 EXIF 的图(我们自己渲染的 PNG、桌面版 pdfium 出的页)走这条, 当不用转
    let orient = dec.orientation().unwrap_or(Orientation::NoTransforms);
    let im = DynamicImage::from_decoder(dec).with_context(|| format!("解码 {}", p.display()))?;

    // 先转灰度再摆正, 顺序不能反: 旋转要另开一块等大的缓冲, 在 8 位灰度上转
    // 比在三通道上转少搬三分之二 —— 一张三千万像素的页图, 这是 22 MB 和 7 MB 之差
    let luma = im.to_luma8();
    drop(im);
    let mut d = DynamicImage::ImageLuma8(luma);
    d.apply_orientation(orient);
    let l8 = d.into_luma8();

    let (w, h) = (l8.width() as usize, l8.height() as usize);
    let src = Gray {
        w,
        h,
        px: l8.into_raw(),
    };
    let long = w.max(h);
    if long <= long_edge as usize || long == 0 {
        return Ok(src);
    }
    let k = long_edge as f64 / long as f64;
    let nw = ((w as f64 * k) as usize).max(1);
    let nh = ((h as f64 * k) as usize).max(1);
    Ok(ocr::resize(&src, nw, nh))
}

/// 挑一个没被占用的文件名
///
/// docx::save / xlsx::save 内部用的是 create_new, 存在就报错 —— 桌面版
/// "绝不覆盖"那条规矩在手机上同样成立, 用户转了两遍不该把上一份冲掉。
fn vacant(dir: &Path, stem: &str, ext: &str) -> PathBuf {
    let first = dir.join(format!("{stem}.{ext}"));
    if !first.exists() {
        return first;
    }
    for n in 2..1000 {
        let p = dir.join(format!("{stem}-{n}.{ext}"));
        if !p.exists() {
            return p;
        }
    }
    dir.join(format!("{stem}-{}.{ext}", std::process::id()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageFormat, Luma};

    /// 造一张带 EXIF Orientation 的 JPEG
    ///
    /// image crate 只会读 EXIF 不会写, 所以自己往 SOI 后面插一段 APP1。
    /// 与其在仓库里塞一个二进制样张, 不如把这三十来字节摊开写清楚 ——
    /// 这个 bug 的要害就在这个标记上, 让它在代码里看得见。
    fn jpeg_with_orientation(w: u32, h: u32, exif: u8) -> Vec<u8> {
        let mut img = image::GrayImage::from_pixel(w, h, Luma([255u8]));
        img.put_pixel(0, 0, Luma([0])); // 左上角点个黑记号, 用来看转到哪去了
        let mut plain = Vec::new();
        image::DynamicImage::ImageLuma8(img)
            .write_to(&mut std::io::Cursor::new(&mut plain), ImageFormat::Jpeg)
            .unwrap();

        #[rustfmt::skip]
        let tiff: [u8; 26] = [
            b'M', b'M', 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // 大端, IFD0 在偏移 8
            0x00, 0x01,                                     // IFD0 有 1 条
            0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // tag=Orientation, type=SHORT, count=1
            0x00, exif, 0x00, 0x00,                         // 值(SHORT 占前两字节, 后两字节补齐)
            0x00, 0x00, 0x00, 0x00,                         // 没有下一个 IFD
        ];
        let mut app1 = vec![0xFF, 0xE1];
        app1.extend(((tiff.len() + 8) as u16).to_be_bytes()); // 长度含自身 2 字节 + "Exif\0\0"
        app1.extend(b"Exif\x00\x00");
        app1.extend(tiff);

        let mut out = plain[..2].to_vec(); // SOI
        out.extend(app1);
        out.extend(&plain[2..]);
        out
    }

    fn write_tmp(name: &str, bytes: &[u8]) -> PathBuf {
        let p = std::env::temp_dir().join(format!("scanbridge-{}-{name}", std::process::id()));
        std::fs::write(&p, bytes).unwrap();
        p
    }

    /// 这是 iPad 上"整篇文字倒序"那个 bug 的回归测试
    #[test]
    fn exif_orientation_is_applied() {
        // 8 = 逆时针转 90° 才是正的, 正是 VisionKit 竖拍一页给出来的那个值
        let p = write_tmp("o8.jpg", &jpeg_with_orientation(40, 20, 8));
        let g = load_gray(&p, 1000).unwrap();
        assert_eq!((g.w, g.h), (20, 40), "宽高该换过来, 说明方向根本没被应用");
        // 左上角那个黑点逆时针转 90° 之后应该跑到左下角
        assert!(g.px[(g.h - 1) * g.w] < 128, "黑记号没转到左下角");
        assert!(g.px[0] > 128, "左上角该是白的");
        std::fs::remove_file(&p).ok();
    }

    /// 没有 EXIF 的图不能被动到 —— 桌面版 pdfium 出的页图就是这种
    #[test]
    fn no_exif_means_no_rotation() {
        let mut plain = Vec::new();
        let mut img = image::GrayImage::from_pixel(40, 20, Luma([255u8]));
        img.put_pixel(0, 0, Luma([0]));
        image::DynamicImage::ImageLuma8(img)
            .write_to(&mut std::io::Cursor::new(&mut plain), ImageFormat::Jpeg)
            .unwrap();
        let p = write_tmp("noexif.jpg", &plain);
        let g = load_gray(&p, 1000).unwrap();
        assert_eq!((g.w, g.h), (40, 20));
        assert!(g.px[0] < 128, "黑记号该还在左上角");
        std::fs::remove_file(&p).ok();
    }

    /// 拿真实样张跑整条流水线, 把 docx 正文打出来
    ///
    /// 默认跳过: 真扫描件里都是合同、人名、电话, 不进仓库(见根 .gitignore)。
    /// 本地这么跑 ——
    ///
    ///   SCAN_MODELS=../assets/models SCAN_PAGES=/path/a.jpg,/path/b.jpg \
    ///     cargo test --release real_page -- --ignored --nocapture
    #[test]
    #[ignore = "要真实样张和模型, 见函数上的说明"]
    fn real_page() {
        let (Ok(models), Ok(pages)) = (std::env::var("SCAN_MODELS"), std::env::var("SCAN_PAGES"))
        else {
            panic!("要设 SCAN_MODELS 和 SCAN_PAGES");
        };
        let images: Vec<String> = pages.split(',').map(str::to_owned).collect();
        // 先把识别出的框按归一化纵坐标打一遍。版面那些阈值(页脚线、页眉线)
        // 都是按页高的比例定的, 出问题时要先看到真实的比例才谈得上调
        let mut engine =
            Engine::load_with(Path::new(&models), EngineOptions::low_memory()).unwrap();
        for p in &images {
            let g = load_gray(Path::new(p), 2560).unwrap();
            println!("{p}: 摆正并缩放后 {}x{}", g.w, g.h);
            for it in engine.run(&g).unwrap() {
                let (ry0, ry1) = (it.y0 / g.h as f32, it.y1 / g.h as f32);
                let head: String = it.t.chars().take(24).collect();
                println!("  y {ry0:.3}..{ry1:.3} 置信 {:.2}  {head}", it.s);
            }
        }
        let out = std::env::temp_dir().join(format!("scanbridge-real-{}", std::process::id()));
        let t0 = std::time::Instant::now();
        let r = convert_inner(
            &models,
            &images,
            out.to_str().unwrap(),
            "real",
            OutFormat::Docx,
            2560,
            true,
            &mut |p| println!("进度: {p:?}"),
        )
        .unwrap();
        println!("耗时 {:?}, 失败页 {:?}", t0.elapsed(), r.failed);
        println!("docx: {}", r.docx_path.as_deref().unwrap_or("-"));
    }
}
