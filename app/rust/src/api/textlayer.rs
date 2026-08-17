//! 一组页图 -> 每页的文字框, 给"可搜索 PDF"用
//!
//! 跟 [`crate::api::convert`] 共用同一个识别引擎, 但到识别为止就停了 —— 版面
//! 重建那一步是为了还原 Word 的段落和表格, 而文字层要的恰恰相反: 每一行字
//! 贴在它当初被识别出来的那个位置上, 不合并、不重排、不删页眉页脚。合并过的
//! 段落文本没法还原成一行一行的坐标, 所以两条路只能分开走。
//!
//! 出 PDF 的活儿在 Swift 那侧(`DocScanner.renderPdf`): 往 PDF 里写不可见文字
//! 要嵌中文字体子集, CoreGraphics 自带这个能力, 在 Rust 里自己搓一遍 CID 字体
//! 是几千行的事。

use std::path::Path;

use crate::api::convert::load_gray;
use crate::frb_generated::StreamSink;
use anyhow::{anyhow, Context, Result};
use scannedpdf2doc::config::Config;
use scannedpdf2doc::ocr::{Engine, EngineOptions};

/// 一行识别出来的字, 坐标归一化到 [0,1], 原点在页面左上角
///
/// 归一化而不是给像素: 识别是在缩到长边 2560 的灰度图上做的, 而 PDF 那边画的
/// 是原图, 两边尺寸对不上。归一化之后, 谁也不用知道对方缩放了多少。
#[derive(Debug, Clone)]
pub struct TextBox {
    pub text: String,
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
}

/// 一页的识别结果
#[derive(Debug, Clone)]
pub struct PageText {
    pub boxes: Vec<TextBox>,
    /// 这一页为什么没认出来; 有值时 boxes 是空的
    ///
    /// 一页坏掉不该毁掉整批: 剩下的页照样有文字层, 这一页退化成纯图片
    pub error: Option<String>,
}

/// 识别进度, 跟 [`crate::api::convert::Progress`] 一个形状
#[derive(Debug, Clone)]
pub enum OcrProgress {
    /// 正在加载三个 ONNX 模型
    Loading,
    /// 正在识别第 index 页(从 1 数), 共 total 页
    Page { index: u32, total: u32 },
    /// 全部做完, 带上每页的文字框。页序跟传进来的 images 一致
    Done { pages: Vec<PageText> },
}

/// 逐页识别, 只出文字和坐标
///
/// `rec_file` 见 [`crate::api::convert::convert_images`]
pub fn ocr_images(
    model_dir: String,
    images: Vec<String>,
    long_edge: u32,
    low_memory: bool,
    rec_file: Option<String>,
    sink: StreamSink<OcrProgress>,
) -> Result<()> {
    let pages = ocr_inner(
        &model_dir,
        &images,
        long_edge,
        low_memory,
        rec_file,
        &mut |p| {
            let _ = sink.add(p);
        },
    )?;
    let _ = sink.add(OcrProgress::Done { pages });
    Ok(())
}

/// 真正干活的那个, 进度走回调 —— 理由同 convert_inner: StreamSink 造不出来,
/// 整条链路不该因此只能靠往手机上装来验
fn ocr_inner(
    model_dir: &str,
    images: &[String],
    long_edge: u32,
    low_memory: bool,
    rec_file: Option<String>,
    on: &mut dyn FnMut(OcrProgress),
) -> Result<Vec<PageText>> {
    if images.is_empty() {
        return Err(anyhow!("一页都没有"));
    }
    let cfg = Config {
        long_edge,
        ..Config::default()
    };

    on(OcrProgress::Loading);
    let opts = EngineOptions {
        rec_file,
        ..if low_memory {
            EngineOptions::low_memory()
        } else {
            EngineOptions::default()
        }
    };
    let mut engine = Engine::load_with(Path::new(model_dir), opts).context("加载模型")?;

    let total = images.len();
    let mut out = Vec::with_capacity(total);
    for (i, path) in images.iter().enumerate() {
        on(OcrProgress::Page {
            index: (i + 1) as u32,
            total: total as u32,
        });
        out.push(match one_page(&mut engine, Path::new(path), &cfg) {
            Ok(boxes) => PageText { boxes, error: None },
            Err(e) => PageText {
                boxes: Vec::new(),
                error: Some(format!("{e:#}")),
            },
        });
    }
    Ok(out)
}

fn one_page(engine: &mut Engine, path: &Path, cfg: &Config) -> Result<Vec<TextBox>> {
    let g = load_gray(path, cfg.long_edge)?;
    let (w, h) = (g.w as f32, g.h as f32);
    if w <= 0.0 || h <= 0.0 {
        return Err(anyhow!("图是空的"));
    }
    let items = engine.run(&g).context("识别")?;
    Ok(items
        .into_iter()
        // 空串塞进文字层只会让选中范围里多出一段选不中的空洞
        .filter(|it| !it.t.trim().is_empty())
        .map(|it| TextBox {
            text: it.t,
            x0: (it.x0 / w).clamp(0.0, 1.0),
            y0: (it.y0 / h).clamp(0.0, 1.0),
            x1: (it.x1 / w).clamp(0.0, 1.0),
            y1: (it.y1 / h).clamp(0.0, 1.0),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_is_an_error() {
        let e = ocr_inner("/nonexistent", &[], 2560, true, &mut |_| {}).unwrap_err();
        assert!(e.to_string().contains("一页都没有"));
    }

    /// 拿真实样张跑一遍, 把每页的框打出来
    ///
    /// 默认跳过, 理由同 convert.rs 里的 real_page ——
    ///
    ///   SCAN_MODELS=../assets/models SCAN_PAGES=/path/a.jpg \
    ///     cargo test --release real_text -- --ignored --nocapture
    #[test]
    #[ignore = "要真实样张和模型"]
    fn real_text() {
        let (Ok(models), Ok(pages)) = (std::env::var("SCAN_MODELS"), std::env::var("SCAN_PAGES"))
        else {
            panic!("要设 SCAN_MODELS 和 SCAN_PAGES");
        };
        let images: Vec<String> = pages.split(',').map(str::to_owned).collect();
        let r = ocr_inner(&models, &images, 2560, true, &mut |p| println!("进度: {p:?}")).unwrap();
        for (i, p) in r.iter().enumerate() {
            println!("第 {} 页: {} 框 {:?}", i + 1, p.boxes.len(), p.error);
            for b in p.boxes.iter().take(5) {
                println!(
                    "  ({:.3},{:.3})-({:.3},{:.3}) {}",
                    b.x0, b.y0, b.x1, b.y1, b.text
                );
            }
        }
    }
}
