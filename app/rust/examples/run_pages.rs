//! 在电脑上跑一遍手机端那条完整流水线, 出 docx
//!
//! 跟 grid_probe 的区别: 那个只看表格切成什么样, 这个是端到端的成品 ——
//! 页脚裁剪、表格填充、段落合并都按真实顺序走一遍。
//!
//!   SCAN_MODELS=../assets/models cargo run --release --example run_pages -- 出目录 页图...

fn main() {
    let mut a = std::env::args().skip(1);
    let out = a.next().expect("要给出目录");
    let pages: Vec<String> = a.collect();
    assert!(!pages.is_empty(), "至少给一张页图");
    let models = std::env::var("SCAN_MODELS").expect("要设 SCAN_MODELS");

    let r = scanbridge::api::convert::convert_for_test(&models, &pages, &out, "扫描件")
        .expect("转换失败");
    println!("{r:?}");
}
