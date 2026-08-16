//! Flutter 与识别核心之间的桥
//!
//! 只做一件事: 把一组页图交给 scannedpdf2doc 的识别 + 版面重建流水线, 出
//! docx / xlsx。扫描、找边、矫正、出 PDF 都在 Dart 和各平台原生那边做, 这里
//! 不掺和 —— 相机和文件系统那些活儿, 系统 API 干得比我们好。

pub mod api;
mod frb_generated;
