import 'package:flutter/material.dart';

import 'src/rust/frb_generated.dart';
import 'src/ui/home.dart';

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
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F6FED),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
