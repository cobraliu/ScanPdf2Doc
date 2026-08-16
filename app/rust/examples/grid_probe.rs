//! 看一张真实页图上的表格被怎么切的
//!
//! 表格出问题时, 光看 docx 是猜不出原因的 —— 要知道横竖线各找到了几条、
//! 落在哪。这个小程序就是干这个的:
//!
//!   SCAN_MODELS=../assets/models cargo run --release --example grid_probe -- 页图.jpg

use scannedpdf2doc::config::Config;
use scannedpdf2doc::imgutil::Gray;
use scannedpdf2doc::layout::{grid, noise};
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
    println!("页图 {}x{}", img.w, img.h);
    // 把流水线真正看到的那张灰度图落盘。缩放方式会明显改变细框线的对比度,
    // 拿原图在别处分析会得出不一样的结论
    if let Ok(dump) = std::env::var("SCAN_DUMP") {
        image::GrayImage::from_raw(img.w as u32, img.h as u32, img.px.clone())
            .unwrap()
            .save(&dump)
            .unwrap();
        println!("已导出缩放后的灰度图 -> {dump}");
    }

    let mut engine = Engine::load_with(Path::new(&models), EngineOptions::low_memory()).unwrap();
    let items = engine.run(&img).unwrap();
    let cfg = Config {
        footer_y: 1.0,
        ..Config::default()
    };
    let (body, _, _) = noise::drop_noise(&items, img.w as f32, img.h as f32, &cfg);
    println!("正文 item {} 个", body.len());

    let mut grids = grid::find_grids(&img, &body);
    // find_grids 只切格子, 格子里的字是 fill_grid 灌的; 不调这步 rows() 全是空串
    for g in &mut grids {
        grid::fill_grid(g, &body);
    }
    println!("找到 {} 张表", grids.len());
    for (i, g) in grids.iter().enumerate() {
        let ints = |v: &Vec<f32>| v.iter().map(|x| *x as i32).collect::<Vec<_>>();
        println!("表 {i}: {} 行 x {} 列", g.nrows(), g.ncols());
        println!("  竖线 x = {:?}", ints(&g.xs));
        println!("  横线 y = {:?}", ints(&g.ys));
        for row in g.rows() {
            println!("  | {}", row.join(" | "));
        }
    }
}
