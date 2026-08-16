//! 看一页上各段落的缩进落在哪
//!
//! 嵌套列表还原不出来时, 光看 docx 只知道"全平了", 不知道是没识别出层级还是
//! 识别出来了没写进去。这个小程序把 merge_paras 之后每段的 cx0/rx1 打出来 ——
//! cx0 就是 render.rs 里判缩进级别用的那个数。
//!
//!   SCAN_MODELS=../assets/models cargo run --release --example para_probe -- 页图.jpg

use scannedpdf2doc::config::Config;
use scannedpdf2doc::imgutil::Gray;
use scannedpdf2doc::layout::line::group_lines;
use scannedpdf2doc::layout::noise;
use scannedpdf2doc::layout::para::{mark_bullets, merge_paras};
use scannedpdf2doc::ocr::{self, Engine, EngineOptions};
use std::path::Path;

fn main() {
    let img_path = std::env::args().nth(1).expect("要给一个页图路径");
    let models = std::env::var("SCAN_MODELS").expect("要设 SCAN_MODELS");

    let l8 = image::open(&img_path).unwrap().to_luma8();
    let (w, h) = (l8.width() as usize, l8.height() as usize);
    let src = Gray {
        w,
        h,
        px: l8.into_raw(),
    };
    let long = w.max(h);
    let img = if long > 2560 {
        let k = 2560.0 / long as f64;
        ocr::resize(&src, (w as f64 * k) as usize, (h as f64 * k) as usize)
    } else {
        src
    };

    let mut engine = Engine::load_with(Path::new(&models), EngineOptions::low_memory()).unwrap();
    let items = engine.run(&img).unwrap();
    let cfg = Config {
        footer_y: 1.0,
        ..Config::default()
    };
    let (body, _, _) = noise::drop_noise(&items, img.w as f32, img.h as f32, &cfg);
    let lines = group_lines(body, &cfg);
    let paras = mark_bullets(merge_paras(&lines, &cfg), &cfg);

    println!("页图 {}x{}, {} 段", img.w, img.h, paras.len());
    println!("{:>6} {:>6} {:>6}  {}", "cx0", "rx0", "rx1", "文字");
    for p in &paras {
        let t: String = p.text.chars().take(48).collect();
        println!("{:>6.3} {:>6.3} {:>6.3}  {}", p.cx0, p.rx0, p.rx1, t);
    }

    // 缩进有几档: 把 cx0 按 0.005 归箱, 看聚成几堆
    let mut xs: Vec<f32> = paras.iter().map(|p| p.cx0).collect();
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut groups: Vec<(f32, usize)> = Vec::new();
    for x in xs {
        match groups.last_mut() {
            Some(g) if (x - g.0).abs() < 0.012 => g.1 += 1,
            _ => groups.push((x, 1)),
        }
    }
    println!("\ncx0 聚类: {:?}", groups);
}
