import CoreImage
import Flutter
import ImageIO
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// 扫描、出 PDF、读 PDF, 三件事都交给系统
///
/// 找页边界、自动抓拍、透视矫正全归 `VNDocumentCameraViewController` —— 就是
/// "备忘录"里那个扫描器。自己用 OpenCV 找四边形当然能做, 但做不过它, 还要多背
/// 一个几 MB 的库。出 PDF 同理, `UIGraphicsPDFRenderer` 是系统自带的。
///
/// 导入已有 PDF 时的逐页渲染也放在这边, 用 CoreGraphics。Rust 那侧本来可以链
/// pdfium(桌面版就是), 但那是 7 MB 的库, iOS 上还得把 .dylib 嵌进 App 再单独
/// 签名; 而 `CGPDFDocument` 是系统自带的, 一行库都不用背。
///
/// 这个类只负责把页图落到磁盘, 然后把路径交给 Dart。图本身不过 platform
/// channel —— 一页三四 MB, 十几页就是几十 MB 的字节在 Dart 和原生之间来回抄,
/// 而它们下一步的去处是 Rust, 传路径就一步到位。
class DocScanner: NSObject {
    static let channel = "scanpdf2doc/native"

    private var pending: FlutterResult?
    /// 通道得留着, 不然它跟着这次 init 的临时对象一起没了
    private var channel: FlutterMethodChannel?

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let ch = FlutterMethodChannel(name: Self.channel, binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }
            self.handle(call, result)
        }
        channel = ch
    }

    /// 要往哪个控制器上盖扫描界面
    ///
    /// 现用现找, 不存: UIScene 生命周期下窗口归 SceneDelegate, App 启动时
    /// 根本还没有; iPad 上还可能开着好几个窗口, 存下来的那个未必是用户正看着的。
    /// 一路往上找到最顶层已呈现的控制器, 否则会撞上 "presenting from a view
    /// controller which is already presenting"
    private var host: UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.rootViewController
        var top = root
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "scannerAvailable":
            result(VNDocumentCameraViewController.isSupported)
        case "scan":
            scan(result)
        case "makePdf":
            guard let a = call.arguments as? [String: Any],
                  let images = a["images"] as? [String],
                  let out = a["out"] as? String
            else {
                result(FlutterError(code: "args", message: "makePdf 参数不对", details: nil))
                return
            }
            offload(result) {
                try Self.renderPdf(
                    images: images,
                    out: out,
                    size: a["pageSize"] as? String ?? "a4",
                    margin: CGFloat(a["marginPt"] as? Double ?? 0),
                    maxEdge: a["maxLongEdge"] as? Int ?? 0,
                    texts: a["texts"] as? [Any])
                return out
            }
        case "rotatePage":
            guard let a = call.arguments as? [String: Any],
                  let path = a["path"] as? String,
                  let out = a["out"] as? String,
                  let turns = a["turns"] as? Int
            else {
                result(FlutterError(code: "args", message: "rotatePage 参数不对", details: nil))
                return
            }
            offload(result) { try Self.rotate(path: path, out: out, turns: turns) }
        case "cropPage":
            guard let a = call.arguments as? [String: Any],
                  let path = a["path"] as? String,
                  let out = a["out"] as? String,
                  let c = a["corners"] as? [Double], c.count == 8
            else {
                result(FlutterError(code: "args", message: "cropPage 参数不对", details: nil))
                return
            }
            offload(result) { try Self.crop(path: path, out: out, corners: c) }
        case "enhancePage":
            guard let a = call.arguments as? [String: Any],
                  let path = a["path"] as? String,
                  let out = a["out"] as? String,
                  let mode = a["mode"] as? String
            else {
                result(FlutterError(code: "args", message: "enhancePage 参数不对", details: nil))
                return
            }
            offload(result) { try Self.enhance(path: path, out: out, mode: mode) }
        case "pickPdf":
            pickPdf(result)
        case "pdfPages":
            guard let a = call.arguments as? [String: Any],
                  let pdf = a["pdf"] as? String
            else {
                result(FlutterError(code: "args", message: "pdfPages 参数不对", details: nil))
                return
            }
            pdfPages(pdf: pdf, longEdge: CGFloat(a["longEdge"] as? Int ?? 2560), result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 扫描

    private func scan(_ result: @escaping FlutterResult) {
        guard VNDocumentCameraViewController.isSupported else {
            result(FlutterError(code: "unsupported", message: "这台设备不支持系统扫描", details: nil))
            return
        }
        guard let host = host else {
            result(FlutterError(code: "nohost", message: "界面还没准备好", details: nil))
            return
        }
        // 上一次还没回调完就再点一次: 直接拒掉, 而不是把 pending 覆盖掉 ——
        // 覆盖会让前一个 FlutterResult 永远不回, Dart 那边的 await 就吊死了
        guard pending == nil else {
            result(FlutterError(code: "busy", message: "扫描界面已经开着了", details: nil))
            return
        }
        pending = result
        let vc = VNDocumentCameraViewController()
        vc.delegate = self
        host.present(vc, animated: true)
    }

    private func finish(_ value: Any?) {
        guard let p = pending else { return }
        pending = nil
        p(value)
    }

    /// 页图的落脚处, 每批一个子目录, 便于整批清理
    private func workDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("scans", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970 * 1000)), isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 把一件重活挪到后台线程, 干完回主线程交差
    ///
    /// 图像那几件事都是几千万像素的活, 放主线程界面会整个卡住。写一遍这个
    /// 壳子, 后面每加一件都少抄一遍 DispatchQueue 的样板。
    private func offload(_ result: @escaping FlutterResult, _ body: @escaping () throws -> Any) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let v = try body()
                DispatchQueue.main.async { result(v) }
            } catch {
                let code = (error as? Err)?.code ?? "img"
                DispatchQueue.main.async {
                    result(FlutterError(code: code, message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - 页编辑

    /// 顺时针转 90° × turns, 写到 out
    ///
    /// JPEG 走无损路子: 只改 EXIF 的 Orientation 标记, 压缩数据一个字节不动。
    /// 三条下游全都认这个标记 —— Skia(缩略图)、UIImage(出 PDF)、Rust 那侧
    /// 自己应用(见 api/convert.rs 的 load_gray)。重新编码一遍才是不必要的:
    /// 一张 4000×3000 的扫描图转一下就掉一次质量, 转四次回到原位, 已经糊了。
    private static func rotate(path: String, out: String, turns: Int) throws -> String {
        let t = ((turns % 4) + 4) % 4
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        if t == 0 {
            try data.write(to: URL(fileURLWithPath: out), options: .atomic)
            return out
        }

        // EXIF 的 1/6/3/8 就是 0°/90°/180°/270° 顺时针, 按这个圈往前挪 t 格。
        // 2/4/5/7 是带镜像的, 极少见, 碰上了退回重画 —— 在圈上接着转会转错
        let ring: [Int] = [1, 6, 3, 8]
        if data.count > 3, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
            var cur = 1
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let o = props[kCGImagePropertyOrientation] as? Int {
                cur = o
            }
            if let i = ring.firstIndex(of: cur),
               let tagged = withOrientation(data, UInt8(ring[(i + t) % 4])) {
                try tagged.write(to: URL(fileURLWithPath: out), options: .atomic)
                return out
            }
        }

        // 非 JPEG(相册里的 png/heic)或带镜像的方向: 老老实实把像素转过来
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        else { throw Err("这张图打不开") }
        // CIImage 的 .right/.left 是按数学正方向说的, 跟"顺时针"正好反着
        let steps: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        try write(ci.oriented(steps[t]), to: out)
        return out
    }

    /// 按四个角做透视矫正, 写到 out
    ///
    /// corners 是归一化到 [0,1] 的八个数, 顺序 左上/右上/右下/左下, 原点在
    /// 左上角 —— 也就是 Flutter 那侧屏幕坐标的习惯。
    private static func crop(path: String, out: String, corners c: [Double]) throws -> String {
        // applyOrientationProperty: 让 EXIF 的方向先生效。不然用户在界面上照着
        // 摆正后的图拖的四个角, 到这儿会落在一张躺倒的图上
        guard let ci = CIImage(contentsOf: URL(fileURLWithPath: path),
                               options: [.applyOrientationProperty: true])
        else { throw Err("这张图打不开") }
        let e = ci.extent
        guard e.width > 0, e.height > 0 else { throw Err("这张图是空的") }

        // Core Image 的原点在左下, 界面那侧在左上, y 要翻过来
        func pt(_ i: Int) -> CIVector {
            CIVector(x: e.minX + CGFloat(c[i * 2]) * e.width,
                     y: e.minY + CGFloat(1 - c[i * 2 + 1]) * e.height)
        }
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else {
            throw Err("系统不支持透视矫正")
        }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(pt(0), forKey: "inputTopLeft")
        f.setValue(pt(1), forKey: "inputTopRight")
        f.setValue(pt(2), forKey: "inputBottomRight")
        f.setValue(pt(3), forKey: "inputBottomLeft")
        guard let o = f.outputImage, o.extent.width >= 1, o.extent.height >= 1 else {
            throw Err("这四个角框不出一块区域")
        }
        try write(o, to: out)
        return out
    }

    /// 增强一页, 写到 out
    ///
    /// - `auto`  文档增强: 摊平底色、去掉阴影, 颜色留着
    /// - `light` 只提一点亮度和对比度, 最接近原样
    /// - `gray`  去色
    /// - `bw`    去色 + 硬对比, 字黑纸白
    ///
    /// 没做真正的二值化(逐像素卡一个阈值)。`CIColorThreshold` 要 iOS 17, 而且
    /// 卡出来的字边缘是硬锯齿, 缩进 PDF 里比现在更糊 —— 拉高对比度留一条很窄
    /// 的过渡带, 看着一样是黑白, 小字反而清楚。
    ///
    /// bw 那组数字(对比度 2.4)是估的, 得在真机上对着一张拍歪的合同看一眼再定。
    /// CIColorControls 是在 CIContext 的线性工作空间里算的, 中点 0.5 线性 ≈
    /// sRGB 的 0.72 —— 也就是说阈值偏暗, 全靠前面那步文档增强先把纸压白。
    private static func enhance(path: String, out: String, mode: String) throws -> String {
        guard let ci = CIImage(contentsOf: URL(fileURLWithPath: path),
                               options: [.applyOrientationProperty: true])
        else { throw Err("这张图打不开") }
        var img = ci

        // auto 和 bw 都先过一遍文档增强。手机拍的纸十有八九一半亮一半暗,
        // 不先把底色摊平, 后面不管提亮还是加对比, 暗的那半边都会糊成一片
        if mode == "auto" || mode == "bw" {
            // 用字符串查而不是 CIFilter.documentEnhancer(): 这个滤镜要 iOS 16,
            // 而部署目标是 15。查不到就是 nil, 不用 #available 分叉。
            //
            // 强度用默认的 1.0, 不去 setValue("inputAmount"): CIFilter 的 KVC
            // 撞上不认识的键是抛 NSUnknownKeyException —— Swift 接不住,
            // 直接闪退。为一个本来就等于默认值的参数冒这个险不值
            if let f = CIFilter(name: "CIDocumentEnhancer") {
                f.setValue(img, forKey: kCIInputImageKey)
                if let o = f.outputImage { img = o }
            }
        }

        var s = 1.0, b = 0.0, c = 1.0
        switch mode {
        case "auto":
            break  // 文档增强自己就够了, 再补一道调色是过头
        case "light":
            (s, b, c) = (1.05, 0.10, 1.10)
        case "gray":
            (s, b, c) = (0.00, 0.00, 1.05)
        case "bw":
            (s, b, c) = (0.00, 0.08, 2.40)
        default:
            throw Err("不认识的增强方式: \(mode)")
        }
        if s != 1.0 || b != 0.0 || c != 1.0 {
            guard let f = CIFilter(name: "CIColorControls") else { throw Err("系统不支持调色") }
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(s, forKey: kCIInputSaturationKey)
            f.setValue(b, forKey: kCIInputBrightnessKey)
            f.setValue(c, forKey: kCIInputContrastKey)
            guard let o = f.outputImage else { throw Err("调色没出图") }
            img = o
        }

        // 一个滤镜都没跑到还照抄一份出去, 是骗人: 那一页会被标成"已编辑"、
        // 「还原」按钮也亮起来, 而画面一点没变。iOS 15 上的 auto 就是这种情况
        if img === ci {
            throw Err("这台设备的系统太老, 用不了自动增强(要 iOS 16)", code: "os_too_old")
        }
        try write(img, to: out)
        return out
    }

    /// 把一张 CIImage 存成 JPEG
    ///
    /// 0.95 跟扫描落盘那边同一个值 —— 识别前还要缩到长边 2560, 压缩噪声叠上
    /// 重采样最容易糊掉小字
    private static func write(_ img: CIImage, to out: String) throws {
        let ctx = CIContext()
        let space = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // extent 的原点未必在 (0,0) —— 透视矫正出来的图就不在。不搬回原点,
        // jpegRepresentation 拿到的是一张偏移出画布的空图
        let shifted = img.transformed(
            by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        guard let data = ctx.jpegRepresentation(
            of: shifted, colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
        else { throw Err("这张图存不下来") }
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    }

    // MARK: - 出 PDF

    /// - size: `a4` / `letter` / `fit`(纸张跟着图的长宽比走)
    /// - margin: 页边距, 点
    /// - maxEdge: 图的长边压到多少像素; 0 = 用原图
    /// - texts: 每页一组文字框, 用来铺不可见文字层; nil 或某页缺席就只有图
    ///
    /// texts 收 `[Any]?` 而不是写死 `[[[String: Any]]]?`: platform channel 那边
    /// 过来的是 NSArray 套 NSArray 套 NSDictionary, 一次性往三层嵌套的 Swift
    /// 类型上强转, 中间任何一格不合就整批变 nil —— 结果是文字层悄悄没了,
    /// 还查不出是哪一页坏的。摊开成一层一层转, 坏的那个框跳过就是了。
    private static func renderPdf(
        images: [String], out: String, size: String, margin: CGFloat, maxEdge: Int,
        texts: [Any]?
    ) throws {
        let base: CGSize = size == "letter"
            ? CGSize(width: 612, height: 792)          // US Letter
            : CGSize(width: 595.276, height: 841.89)   // A4
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: base))
        try renderer.writePDF(to: url) { ctx in
            for (i, path) in images.enumerated() {
                // 一页一个池子: 不放的话所有页的解码位图会攒到整个闭包结束才释放,
                // 二十页就是几百 MB, 前台 App 到不了那么高就被 jetsam 收走了
                autoreleasepool {
                    guard let img = Self.load(path, maxEdge: maxEdge) else { return }
                    let bounds = CGRect(origin: .zero, size: Self.pageSize(base, size, img.size))
                    ctx.beginPage(withBounds: bounds, pageInfo: [:])
                    let dst = Self.fit(img.size, into: bounds.insetBy(dx: margin, dy: margin))
                    img.draw(in: dst)
                    // 文字层压在图上面: 顺序在 PDF 里只影响绘制先后, 而它是
                    // 不可见的, 谁在上面都一样 —— 但阅读器提取文字时是按内容流
                    // 的顺序走的, 放在后面才跟"先看图再读字"的直觉一致
                    if let all = texts, i < all.count,
                       let boxes = all[i] as? [[String: Any]], !boxes.isEmpty {
                        Self.drawTextLayer(boxes, in: dst, page: bounds.size, ctx.cgContext)
                    }
                }
            }
        }
    }

    /// 往页面上铺一层看不见但选得中、搜得到的文字
    ///
    /// 每个框画一行, 横向拉伸到跟框一样宽 —— 识别给的是这一行字在纸上的位置,
    /// 而系统字体的字宽跟原件里那套字体对不上。不拉伸的话, 选中一行时高亮框
    /// 会比字短一截或者拖出去一大截, 复制出来的内容倒是对的, 但看着像坏了。
    ///
    /// 走 CoreText 而不是 `NSAttributedString.draw`: 要的是 PDF 里那个
    /// "写了但不显示"的渲染模式(Tr 3), UIKit 那层没有口子设它。
    private static func drawTextLayer(
        _ boxes: [[String: Any]], in dst: CGRect, page: CGSize, _ c: CGContext
    ) {
        guard !boxes.isEmpty, dst.width > 0, dst.height > 0 else { return }
        c.saveGState()
        // PDF 上下文是 y 往下的, CoreText 按 y 往上摆字。整个坐标系翻一次, 比
        // 给每一行单独配一个翻转的 text matrix 干净, 也不会把字写成镜像 ——
        // 镜像的字肉眼看不见(它本来就不显示), 但复制出来的位置全是错的
        c.translateBy(x: 0, y: page.height)
        c.scaleBy(x: 1, y: -1)
        c.setTextDrawingMode(.invisible)
        // 翻转之后图所占的那块; 归一化坐标都相对它算
        let box = CGRect(x: dst.minX, y: page.height - dst.maxY,
                         width: dst.width, height: dst.height)

        for b in boxes {
            guard let t = b["t"] as? String, !t.isEmpty,
                  let x0 = b["x0"] as? Double, let y0 = b["y0"] as? Double,
                  let x1 = b["x1"] as? Double, let y1 = b["y1"] as? Double
            else { continue }
            let w = CGFloat(x1 - x0) * box.width
            let h = CGFloat(y1 - y0) * box.height
            // 小于半个点的框画了也选不中, 白白撑大文件
            guard w > 0.5, h > 0.5 else { continue }

            // 归一化的 y 是从纸的上边往下量的, 翻转后要倒过来
            let x = box.minX + CGFloat(x0) * box.width
            let y = box.minY + CGFloat(1 - y1) * box.height

            // 系统字体, 中文靠 CoreText 自己回退到苹方 —— 用到的字会以子集
            // 形式嵌进 PDF, 换台机器打开也搜得到
            let font = UIFont.systemFont(ofSize: max(1, h * 0.8))
            // 只设渲染模式, 不去动前景色。"画透明色"看着也能藏住字, 但那是让
            // 绘制系统去画一个全透明的东西, 它有理由整个跳过, 跳过就等于没有
            // 文字层 —— 而 Tr 3 是 PDF 规范里专门为这件事留的口子
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: t, attributes: [.font: font]))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let lw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            guard lw > 0 else { continue }
            // 拉伸倍数封在 [0.1, 10]: 识别偶尔会给出一个又扁又长的噪声框,
            // 照着它拉出去的字会横跨整页, 把别处的选中范围搅乱
            c.textMatrix = CGAffineTransform(scaleX: min(max(w / lw, 0.1), 10), y: 1)
            // 基线摆在框里居中的位置
            c.textPosition = CGPoint(x: x, y: y + (h - ascent - descent) / 2 + descent)
            CTLineDraw(line, c)
        }
        c.restoreGState()
    }

    /// 这一页用多大的纸
    private static func pageSize(_ base: CGSize, _ kind: String, _ img: CGSize) -> CGSize {
        // 贴合原图: 纸张照图的长宽比裁, 图正好铺满(页边距设了才留白)。小票和
        // 证件按 A4 出来是一张纸中间一小块, 这个模式就是为它们准备的。
        //
        // 长边仍按 A4/Letter 的长边定 —— 直接拿像素当点的话, 一张 4000 像素的
        // 扫描图会出一张 141 cm 长的纸, 打印机和阅读器都会当它是海报
        if kind == "fit", img.width > 0, img.height > 0 {
            let k = max(base.width, base.height) / max(img.width, img.height)
            return CGSize(width: img.width * k, height: img.height * k)
        }
        // 横拍的图塞进竖版会缩成窄窄一条, 纸张跟着图的方向走
        return img.width > img.height
            ? CGSize(width: base.height, height: base.width)
            : base
    }

    /// 读一页图, 需要的话顺便压到长边 maxEdge
    ///
    /// 压缩走 CGImageSource 的缩略图口子而不是"先整张解码再重画": 它是从原图
    /// 数据直接解出目标尺寸的, 一张 4000×3000 的图省掉的是 48 MB 的中间位图。
    /// 二十页连着来的时候, 这个差别就是能不能活着走完
    private static func load(_ path: String, maxEdge: Int) -> UIImage? {
        guard maxEdge > 0 else { return UIImage(contentsOfFile: path) }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return UIImage(contentsOfFile: path) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            // 让它顺手把 EXIF 方向应用掉 —— 出来的 CGImage 已经是正的,
            // 后面 UIImage(cgImage:) 按 .up 用就对了
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return UIImage(contentsOfFile: path) }
        return UIImage(cgImage: cg)
    }

    // MARK: - 导入 PDF

    private func pickPdf(_ result: @escaping FlutterResult) {
        guard let host = host else {
            result(FlutterError(code: "nohost", message: "界面还没准备好", details: nil))
            return
        }
        guard pending == nil else {
            result(FlutterError(code: "busy", message: "选择器已经开着了", details: nil))
            return
        }
        pending = result
        // asCopy: true —— 让系统把文件复制进我们的沙盒。用 false 就得自己管
        // startAccessingSecurityScopedResource 的配对调用, 而且 iCloud 上
        // 还没下载下来的文件拿到的只是个占位符; asCopy 会先替我们下完再给
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        vc.allowsMultipleSelection = true
        vc.delegate = self
        host.present(vc, animated: true)
    }

    private func pdfPages(pdf: String, longEdge: CGFloat, _ result: @escaping FlutterResult) {
        // 一份几十页的 PDF 渲下来要好几秒, 放主线程会卡住界面
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let paths = try self.renderPages(pdf: pdf, longEdge: longEdge)
                DispatchQueue.main.async { result(paths) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "pdf", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func renderPages(pdf: String, longEdge: CGFloat) throws -> [String] {
        guard let doc = CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL) else {
            throw Err("这个文件打不开，可能不是 PDF")
        }
        // 只设了权限口令(允许打开、限制打印)的 PDF, CGPDFDocument 已经用空口令
        // 自己开好了; 到这儿还锁着就是真要口令, 而我们没有问口令的界面
        guard !doc.isEncrypted || doc.isUnlocked else {
            throw Err("这个 PDF 有密码，先解密再导入")
        }
        guard doc.numberOfPages > 0 else { throw Err("这个 PDF 里一页都没有") }

        let dir = try workDir()
        var out: [String] = []
        for i in 1...doc.numberOfPages {
            // 一页一个池子: 不放的话所有页的位图会攒到循环结束才释放,
            // 几十页就是几百 MB, 前台 App 到不了那么高就被 jetsam 收走了
            try autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let p = dir.appendingPathComponent(String(format: "%03d.jpg", i))
                // 扫描件 PDF 里那张原图能直接抠出来的话就别重画一遍, 见下面
                if Self.copyEmbeddedScan(page, to: p) {
                    out.append(p.path)
                    return
                }
                guard let img = Self.rasterize(page, longEdge: longEdge),
                      let data = img.jpegData(compressionQuality: 0.95)
                else { return }
                try data.write(to: p, options: .atomic)
                out.append(p.path)
            }
        }
        guard !out.isEmpty else { throw Err("这个 PDF 的页都渲染不出来") }
        return out
    }

    /// 整页就是一张扫描图的话, 把那张原图原样抠出来; 抠不了返回 false 走光栅化
    ///
    /// 扫描件 PDF 里嵌的就是扫描仪/相机出的那张 JPEG。重新光栅化等于把它降到
    /// 219 dpi 再存一遍, 而这个 App 恰恰吃这点分辨率 —— 实测那份带表格的样张,
    /// 光栅化后表格从 10 行塌成 9 行(有条横线被重采样吃掉了), 抠原图则跟直接
    /// 拿相机拍的结果一模一样。
    ///
    /// 判定条件故意收得很紧: 整页只有一个图 XObject、长宽比跟页面对得上。
    /// 拿不准就退回光栅化 —— 光栅化永远是对的, 只是可能糊一点。
    private static func copyEmbeddedScan(_ page: CGPDFPage, to url: URL) -> Bool {
        let ss = imageXObjects(page)
        guard ss.count == 1, let sd = CGPDFStreamGetDictionary(ss[0]) else { return false }
        var w = 0, h = 0
        guard CGPDFDictionaryGetInteger(sd, "Width", &w),
              CGPDFDictionaryGetInteger(sd, "Height", &h),
              max(w, h) > 600  // 太小的多半是页眉里的 logo, 不是整页扫描
        else { return false }

        let boxKind: CGPDFBox = page.getBoxRect(.cropBox).isEmpty ? .mediaBox : .cropBox
        let box = page.getBoxRect(boxKind)
        guard box.width > 0, box.height > 0 else { return false }

        // 只有 DCTDecode(也就是 JPEG)能原样搬走 —— 拿到的字节就是一个完整的
        // JPEG 文件。Flate 那些 CGPDFStreamCopyData 会解成裸样本, 还得自己配
        // 色彩空间重新编码, 不如直接退回光栅化
        var fmt: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(ss[0], &fmt) as Data?, fmt == .jpegEncoded else {
            return false
        }

        // 嵌进 PDF 的这张 JPEG 自己可能带着 Orientation。PDF 阅读器不看它 ——
        // 画的时候是用 CTM 把图摆正的, 而 CTM 我们没解析。但造这个 PDF 的
        // CoreGraphics 当时用的就是 EXIF 摆正后的样子, 所以拿它当"这张图该
        // 怎么摆"来用是对的; 摆完对不上页面长宽比的, 下面那道关会拦掉
        var e = 1
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = props[kCGImagePropertyOrientation] as? Int {
            e = o
        }
        // 只认没镜像的四种, 2/4/5/7 极少见, 碰上了退回光栅化更稳
        let cw = [1: 0, 6: 90, 3: 180, 8: 270]
        guard let base = cw[e] else { return false }
        let swapped = base == 90 || base == 270
        let ra = Double(swapped ? h : w) / Double(swapped ? w : h)
        // 比的是没转过的页面框: 图是画在 /Rotate 生效之前的页面坐标里的
        let rb = Double(box.width / box.height)
        guard abs(ra - rb) / rb < 0.05 else { return false }

        // 图自己的方向, 再叠上页面的 /Rotate。/Rotate 的定义就是"显示时顺时针
        // 转多少度", 跟 EXIF 的 1/6/3/8 正好一一对应
        let rot = Int(((page.rotationAngle % 360) + 360) % 360)
        guard let exif = [0: 1, 90: 6, 180: 3, 270: 8][(base + rot) % 360],
              let tagged = withOrientation(data, UInt8(exif)),
              (try? tagged.write(to: url, options: .atomic)) != nil
        else { return false }
        return true
    }

    /// 一页里所有 /Subtype /Image 的 XObject
    ///
    /// Resources 是从父节点继承下来的时候这儿会找不到, 返回空 —— 那就退回
    /// 光栅化, 不值得为这种 PDF 再爬一遍页树
    private static func imageXObjects(_ page: CGPDFPage) -> [CGPDFStreamRef] {
        guard let d = page.dictionary else { return [] }
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(d, "Resources", &res), let res else { return [] }
        var xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return [] }
        let bag = StreamBag()
        CGPDFDictionaryApplyFunction(xo, { _, obj, info in
            let bag = Unmanaged<StreamBag>.fromOpaque(info!).takeUnretainedValue()
            var s: CGPDFStreamRef?
            guard withUnsafeMutablePointer(to: &s, {
                CGPDFObjectGetValue(obj, .stream, UnsafeMutableRawPointer($0))
            }), let s, let sd = CGPDFStreamGetDictionary(s) else { return }
            var sub: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(sd, "Subtype", &sub), let sub,
                  String(cString: sub) == "Image" else { return }
            bag.v.append(s)
        }, Unmanaged.passUnretained(bag).toOpaque())
        return bag.v
    }

    /// 往 JPEG 里塞一个只有 Orientation 一项的 EXIF 块
    ///
    /// 不用 CGImageDestination 顺手写, 是因为它会把图重新编码一遍 —— 实测一张
    /// 1.45 MB 的扫描图出来只剩 1.18 MB, 而抠原图的全部意义就是不想让它再掉一
    /// 次质量。自己拼这 34 字节, 压缩数据一个字节都不动。
    private static func withOrientation(_ jpeg: Data, _ n: UInt8) -> Data? {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        out += [0xFF, 0xE1, 0x00, 0x22]                             // APP1, 段长 34
        out += [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]                 // "Exif\0\0"
        out += [0x49, 0x49, 0x2A, 0x00, 0x08, 0, 0, 0]              // 小端 TIFF 头, IFD0 在 +8
        out += [0x01, 0x00]                                         // IFD0 只有一项
        out += [0x12, 0x01, 0x03, 0x00, 0x01, 0, 0, 0, n, 0, 0, 0]  // 0x0112 SHORT x1 = n
        out += [0x00, 0, 0, 0]                                      // 没有下一个 IFD
        // 原图自己带了 EXIF 的话得扔掉 —— 留着两个 APP1, 谁说了算全看解码器心情
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {  // 到 SOS 就没有段结构了
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { break }
            let isExif = b[i + 1] == 0xE1 && len >= 8
                && Array(b[(i + 4)..<(i + 8)]) == [0x45, 0x78, 0x69, 0x66]
            if !isExif { out += b[i..<(i + 2 + len)] }
            i += 2 + len
        }
        out += b[i...]
        return Data(out)
    }

    /// 把一页 PDF 渲成位图
    private static func rasterize(_ page: CGPDFPage, longEdge: CGFloat) -> UIImage? {
        // 没写 CropBox 的页, getBoxRect(.cropBox) 会退回 MediaBox; 真拿到空的
        // 就是这页坏了。选定哪个 box 之后画的时候得用同一个, 不然会错位
        let boxKind: CGPDFBox = page.getBoxRect(.cropBox).isEmpty ? .mediaBox : .cropBox
        let box = page.getBoxRect(boxKind)
        guard box.width > 0, box.height > 0 else { return nil }

        // 页面自带 /Rotate 90 或 270 时, 纸张的长短边是反过来的
        let rot = ((page.rotationAngle % 360) + 360) % 360
        let swap = rot == 90 || rot == 270
        let ptW = swap ? box.height : box.width
        let ptH = swap ? box.width : box.height

        // dpi 跟桌面版同一个算法(见 core 的 pdf.rs): 按本页尺寸倒推, 让长边落在
        // longEdge 附近, 再夹到 150~300。固定 dpi 会把 A3 图纸渲成八千像素、
        // A5 单据只有一千, 后面那些按像素定的阈值就没法通用了
        let dpi = min(max((longEdge / max(ptW, ptH) * 72).rounded(), 150), 300)
        let k = dpi / 72
        let px = CGSize(width: (ptW * k).rounded(), height: (ptH * k).rounded())

        let fmt = UIGraphicsImageRendererFormat.default()
        // 不跟屏幕的 @2x/@3x 走 —— 上面算出来的就是最终像素数, 再乘一遍
        // iPad 上会变成两倍大, 白白多花四倍内存
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: px, format: fmt).image { ctx in
            let c = ctx.cgContext
            // PDF 页面本身是透明的, 不先铺白底, 出来是一片全黑
            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: px))
            // PDF 的 y 轴朝上, UIKit 朝下
            c.translateBy(x: 0, y: px.height)
            c.scaleBy(x: 1, y: -1)
            // 放大必须自己做: getDrawingTransform 只缩不放 —— 目标 rect 给得比
            // 页面大时它返回的 a/d 恒为 1, 只把内容居中(实测 595x841pt 的页要
            // 1810x2558px, 拿到的是 a=d=1, tx=607.5 ty=858.5)。原来把像素尺寸
            // 直接传进去, 等于整页按 72dpi 画完摆在画布中间, 有效分辨率只有
            // 三分之一, 正文只占画布约一成面积 —— 短页会因此一个字都检不出来。
            c.scaleBy(x: px.width / ptW, y: px.height / ptH)
            // 缩放归我们, 它只负责 box 的原点偏移和页面自带的 /Rotate ——
            // 这个矩阵自己拼, 在旋转页上十有八九会摆错。所以 rect 传"点"尺寸,
            // 让它做一个 1:1 的映射
            c.concatenate(page.getDrawingTransform(
                boxKind,
                rect: CGRect(x: 0, y: 0, width: ptW, height: ptH),
                rotate: 0,
                preserveAspectRatio: true))
            c.drawPDFPage(page)
        }
    }

    /// 等比缩放并居中
    private static func fit(_ size: CGSize, into box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let k = min(box.width / size.width, box.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: box.minX + (box.width - w) / 2,
                      y: box.minY + (box.height - h) / 2,
                      width: w, height: h)
    }
}

/// CGPDFDictionaryApplyFunction 的回调是个 C 函数指针, 捕获不了外面的变量,
/// 只能靠 info 递一个引用类型进去装结果
private final class StreamBag {
    var v: [CGPDFStreamRef] = []
}

/// 只是为了把中文话原样带到 Dart —— 随手 throw 个 NSError 的话,
/// localizedDescription 会变成 "The operation couldn't be completed"
private struct Err: LocalizedError {
    let msg: String

    /// 传给 Flutter 那侧的错误码
    ///
    /// 这些 msg 是诊断, 一直是中文, 不跟着界面语言走 —— 翻译它们要在 Swift
    /// 里再搭一套 l10n, 而用户看到它们的概率很低。真正会被正常撞上的那几条
    /// 另给一个码, Dart 那边按码挑一句本地化的话说。
    let code: String

    init(_ msg: String, code: String = "img") {
        self.msg = msg
        self.code = code
    }

    var errorDescription: String? { msg }
}

extension DocScanner: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // 选择器自己会关掉, 不用再 dismiss
        finish(urls.map { $0.path })
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 跟扫描那边一致: 取消不是错误, 回空数组
        finish([String]())
    }
}

extension DocScanner: VNDocumentCameraViewControllerDelegate {
    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
    ) {
        controller.dismiss(animated: true)
        do {
            let dir = try workDir()
            var paths: [String] = []
            for i in 0..<scan.pageCount {
                try autoreleasepool {
                    let img = scan.imageOfPage(at: i)
                    // 0.95 而不是常见的 0.8: 后面识别前还要缩到长边 2560, 压缩
                    // 噪声叠上重采样容易糊掉小字。文件只是临时的, 大点无所谓
                    guard let data = img.jpegData(compressionQuality: 0.95) else { return }
                    let p = dir.appendingPathComponent(String(format: "%03d.jpg", i + 1))
                    try data.write(to: p, options: .atomic)
                    paths.append(p.path)
                }
            }
            finish(paths)
        } catch {
            finish(FlutterError(code: "save", message: error.localizedDescription, details: nil))
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
        // 取消不是错误, 回空数组 —— Dart 那边照着"没新增页"处理就行
        finish([String]())
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFailWithError error: Error
    ) {
        controller.dismiss(animated: true)
        finish(FlutterError(code: "scan", message: error.localizedDescription, details: nil))
    }
}
