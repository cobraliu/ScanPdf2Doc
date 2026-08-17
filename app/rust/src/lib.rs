//! Flutter 与识别核心之间的桥
//!
//! 把一组页图交给 scannedpdf2doc 的识别流水线, 出两样东西之一: 走完版面重建
//! 的 docx / xlsx([`api::convert`]), 或者只到识别为止的逐行文字框
//! ([`api::textlayer`], 给可搜索 PDF 用)。
//!
//! 扫描、找边、矫正、出 PDF 都在 Dart 和各平台原生那边做, 这里不掺和 ——
//! 相机和文件系统那些活儿, 系统 API 干得比我们好。

pub mod api;
mod frb_generated;
