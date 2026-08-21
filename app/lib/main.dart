import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'src/rust/frb_generated.dart';
import 'src/settings.dart';
import 'src/ui/home.dart';
import 'src/ui/theme.dart';
import 'src/ui/window_controls.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 Rust 侧的动态/静态库并起工作线程。放在 runApp 前, 免得第一次调用
  // 时还要判断初始化好没有
  await RustLib.init();
  // 语言也在这儿读: 晚一步的话第一帧会按系统语言画出来, 然后当着用户的面
  // 闪一下换成他选的那种
  await Settings.load();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale?>(
      valueListenable: Settings.locale,
      builder: (_, locale, _) => MaterialApp(
        title: 'ScanPdf2Doc',
        debugShowCheckedModeBanner: false,
        theme: Ui.light(),
        // 跟随系统。iPad 到了晚上会自动切暗色, 一个只有亮色主题的 App 这时候
        // 是一整屏白光 —— 而扫描件本来就是白底的, 亮得更狠
        darkTheme: Ui.dark(),
        themeMode: ThemeMode.system,
        // null 就是跟着系统走, Flutter 自己会在 supportedLocales 里挑最近的
        locale: locale,
        localizationsDelegates: const [
          L.delegate,
          // 这三个管系统控件自带的字: 长按选中弹出的"拷贝/粘贴"、日期选择器、
          // 朗读时的控件名。少了它们, App 自己的字翻好了, 这些还是英文
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L.supportedLocales,
        // 挂在 builder 上而不是套在 home 外面: 这一层要盖住 Navigator, 后面
        // push 出来的页(页列表、单页编辑…)才找得到它
        builder: (_, child) => WindowControls(child: child!),
        home: const HomePage(),
      ),
    );
  }
}
