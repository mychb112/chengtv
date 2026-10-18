import 'package:flutter/material.dart';

/// 按可用宽度自动收字号的文本。
///
/// 设计字号放得下就原样显示（大多数设备走这一支，只测一次）；
/// 放不下才二分缩到能放下的最大字号，最小字号仍放不下才换行/省略。
///
/// 用途：播放器里的分类栏、频道列表都是固定宽度布局，
/// 系统字体被调到「特大」时整行会被截成「央视…」，
/// 这里让文字自己退让，而不是全局把字号调小、正常设备上显得没精神。
///
/// 注意：[minSize] 是「最终渲染字号」的下限，测量用的 textScaler
/// 与实际渲染完全一致。若外层做了 `MediaQuery.withNoTextScaling`，
/// 这里量到的就是真实像素宽度。
class AutoFitText extends StatelessWidget {
  final String text;
  final TextStyle style;

  /// 设计字号
  final double maxSize;

  /// 允许缩到的最小字号，再小就不如直接省略
  final double minSize;

  /// 行数上限。超过 1 时优先换行，仍放不下才省略
  final int maxLines;

  const AutoFitText(
    this.text, {
    super.key,
    required this.style,
    required this.maxSize,
    this.minSize = 11,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    // 测量必须用与实际渲染一致的 textScaler，否则算出来的不是真宽
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);

    /// 按给定字号在 maxWidth 内排版，看是否还能完整容纳
    bool fits(double size, double maxWidth) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style.copyWith(fontSize: size)),
        maxLines: maxLines,
        textDirection: dir,
        textScaler: scaler,
      )..layout(maxWidth: maxWidth);
      // 用 didExceedMaxLines 判断，而不是比宽度：
      // 允许换行时宽度总是 <= maxWidth，只有行数溢出才算真正放不下
      final ok = !tp.didExceedMaxLines;
      tp.dispose();
      return ok;
    }

    return LayoutBuilder(
      builder: (context, c) {
        // 宽度无界（例如横向滚动容器里）时不做收缩，按设计字号走
        if (!c.maxWidth.isFinite) return _build(maxSize);
        final maxW = c.maxWidth;

        // 先按设计字号试一次，放得下就到此为止
        if (fits(maxSize, maxW)) return _build(maxSize);

        // 二分查找能放下的最大字号（6 次即收敛到 0.2 以内）
        var lo = minSize;
        var hi = maxSize;
        if (!fits(minSize, maxW)) {
          // 最小字号也放不下，直接用最小字号 + 省略，避免无谓二分
          return _build(minSize);
        }
        for (var i = 0; i < 6 && hi - lo > 0.2; i++) {
          final mid = (lo + hi) / 2;
          if (fits(mid, maxW)) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        return _build(lo);
      },
    );
  }

  Widget _build(double size) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(fontSize: size),
    );
  }
}
