import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chengtv/ui/widgets/auto_fit_text.dart';

Widget _wrap(Widget child, {double scale = 1.0}) {
  return MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topLeft, child: child),
    ),
  );
}

double _fontSizeOf(WidgetTester tester) {
  final text = tester.widget<Text>(find.byType(Text));
  return text.style!.fontSize!;
}

void main() {
  testWidgets('宽度够时保持设计字号', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 400,
          height: 40,
          child: AutoFitText(
            '央视高清',
            maxSize: 16,
            minSize: 12,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
    expect(_fontSizeOf(tester), 16.0);
  });

  testWidgets('宽度不足时自动缩小字号并完整显示', (tester) async {
    // 4 个字按 16 号需要约 64dp，这里只给 40dp
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 40,
          height: 40,
          child: AutoFitText(
            '央视高清',
            maxSize: 16,
            minSize: 8,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
    final size = _fontSizeOf(tester);
    expect(size, lessThan(16.0));
    expect(size, greaterThanOrEqualTo(8.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统字体放大时同样会收缩', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 80,
          height: 60,
          child: AutoFitText(
            '央视高清',
            maxSize: 16,
            minSize: 8,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        scale: 2.0,
      ),
    );
    final size = _fontSizeOf(tester);
    // 2 倍缩放后 16 号实际占 32 号宽度，必然放不下，应当缩下来
    expect(size, lessThan(16.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('缩到最小仍放不下时省略而不是溢出', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 30,
          height: 40,
          child: AutoFitText(
            'CCTV-13 新闻高清频道',
            maxSize: 16,
            minSize: 10,
            style: const TextStyle(),
          ),
        ),
      ),
    );
    expect(_fontSizeOf(tester), 10.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导航区禁用系统字体倍率后，特大字体也保持设计字号', (tester) async {
    // 模拟「系统字体调到 2 倍」的设备上左侧分类栏的处理：
    // 外层 withNoTextScaling 把倍率抵消掉，文字回到 16 号，宽度足够完整显示
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 108,
          height: 44,
          child: MediaQuery.withNoTextScaling(
            child: AutoFitText(
              '央视高清',
              maxSize: 16,
              minSize: 12,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        scale: 2.0,
      ),
    );
    expect(_fontSizeOf(tester), 16.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('允许两行时优先换行，不急着缩到最小', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 76,
          height: 60,
          child: AutoFitText(
            'CCTV-13 新闻',
            maxSize: 13.5,
            minSize: 10.5,
            maxLines: 2,
            style: const TextStyle(),
          ),
        ),
      ),
    );
    final size = _fontSizeOf(tester);
    // 单行放不下，但折成两行能放下，所以字号应该比最小值大
    expect(size, greaterThan(10.5));
    expect(size, lessThanOrEqualTo(13.5));
    expect(tester.takeException(), isNull);
  });
}
