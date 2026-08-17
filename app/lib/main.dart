import 'package:flutter/material.dart';

import 'src/rust/frb_generated.dart';
import 'src/ui/home.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 Rust 侧的动态/静态库并起工作线程。放在 runApp 前, 免得第一次调用
  // 时还要判断初始化好没有
  await RustLib.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ScanPdf2Doc',
      debugShowCheckedModeBanner: false,
      theme: Ui.light(),
      // 跟随系统。iPad 到了晚上会自动切暗色, 一个只有亮色主题的 App 这时候
      // 是一整屏白光 —— 而扫描件本来就是白底的, 亮得更狠
      darkTheme: Ui.dark(),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
