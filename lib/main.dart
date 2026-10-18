import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/app_state.dart';
import 'theme.dart';
import 'ui/home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final app = AppState();
  await app.init();

  runApp(
    ChangeNotifierProvider.value(
      value: app,
      child: const ChengTvApp(),
    ),
  );
}

class ChengTvApp extends StatelessWidget {
  const ChengTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '电视',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      // 播放器、分类栏、频道列表都是按固定宽度排的密集布局，
      // 系统字体调到「特大」时放大到近 2 倍会把整行文字截断。
      // 这里把缩放夹在 0.9~1.25，个别仍放不下的条目再由列表内的自适应字号兜底。
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.9,
        maxScaleFactor: 1.25,
        child: child!,
      ),
      home: const HomePage(),
    );
  }
}
