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
            makePdf(images: images, out: out, result)
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

    // MARK: - 出 PDF

    private func makePdf(images: [String], out: String, _ result: @escaping FlutterResult) {
        // 渲染十几页要好几秒, 放主线程会卡住界面
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.renderPdf(images: images, out: out)
                DispatchQueue.main.async { result(out) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "pdf", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func renderPdf(images: [String], out: String) throws {
        let a4 = CGSize(width: 595.276, height: 841.89)
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4))
        try renderer.writePDF(to: url) { ctx in
            for path in images {
                // 一页一个池子: 不放的话所有页的解码位图会攒到整个闭包结束才释放,
                // 二十页就是几百 MB, 前台 App 到不了那么高就被 jetsam 收走了
                autoreleasepool {
                    guard let img = UIImage(contentsOfFile: path) else { return }
                    // 横拍的图塞进竖 A4 会缩成窄窄一条, 纸张跟着图的方向走
                    let landscape = img.size.width > img.size.height
                    let page = landscape ? CGSize(width: a4.height, height: a4.width) : a4
                    let bounds = CGRect(origin: .zero, size: page)
                    ctx.beginPage(withBounds: bounds, pageInfo: [:])
                    img.draw(in: Self.fit(img.size, into: bounds))
                }
            }
        }
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
    init(_ msg: String) { self.msg = msg }
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
