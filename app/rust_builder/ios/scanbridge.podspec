#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint scanbridge.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'scanbridge'
  s.version          = '0.1.0'
  s.summary          = '识别与版面重建核心的 Rust 桥'
  s.description      = <<-DESC
把一组页图交给 scannedpdf2doc 的识别 + 版面重建流水线, 出 docx / xlsx。
                       DESC
  s.homepage         = 'https://github.com/cobraliu/ScanPdf2Doc'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'cobraliu' => 'cobraliu' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # ONNX Runtime 是 C++ 写的, 而 Swift/ObjC 的 App target 默认不链 libc++。
  # cargo 那边知道要 -lc++(ort 的 build script 会发这条指令), 但我们产出的是
  # staticlib, 那条指令传不到 Xcode 这一侧 —— 不显式加上, 链接时会掉出一堆
  # std::__1::basic_streambuf 之类的未定义符号
  s.libraries = 'c++'

  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust scanbridge',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/libscanbridge.a"],
  }
  # cargokit 模板原本是 `-force_load libscanbridge.a`。这里不能那么干:
  #
  # ort 下载的 libonnxruntime.a 是几个静态库 libtool 合出来的, 没去重 —— 里面
  # 有 29 个重名 object, 光 onnx-ml.pb.cc.o 就两份, 而且定义同一批符号。
  # cargo 把它整个塞进 libscanbridge.a, force_load 会把所有成员无差别拉进来,
  # 于是 756 个 duplicate symbol。平时 cargo 自己链二进制没事, 是因为按需
  # 加载只会挑中其中一份。
  #
  # 所以改成普通的 -l + 几个 -u: 只把 frb 那几个入口点钉住(它们只被 Dart 在
  # 运行时 dlsym, 链接期没人引用, 不钉就被丢掉), 剩下的照常按需解析。
  # 本 crate 是 fat LTO + codegen-units=1, 钉住一个就把整块 Rust 代码带进来了,
  # 其余 frb_* 导出跟着一起在。
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # i386 是因为 Flutter.framework 没有那一片; x86_64 是因为 ort 只发
    # aarch64 的 iOS 模拟器预编译包。不排掉的话模拟器构建会去要
    # x86_64-apple-ios 然后直接失败 —— 代价是 Intel Mac 上跑不了模拟器版,
    # 真机不受影响
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'OTHER_LDFLAGS' => '-L${BUILT_PRODUCTS_DIR} -lscanbridge ' \
      '-Wl,-u,_frb_get_rust_content_hash ' \
      '-Wl,-u,_frb_pde_ffi_dispatcher_primary ' \
      '-Wl,-u,_frb_pde_ffi_dispatcher_sync ' \
      '-Wl,-u,_frb_init_frb_dart_api_dl',
  }
end