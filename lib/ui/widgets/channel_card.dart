import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/channel.dart';
import '../../theme.dart';

/// 可聚焦卡片：遥控器焦点时放大 + 描边发光；触屏点击同样生效。
class ChannelCard extends StatefulWidget {
  final Channel channel;
  final bool isFavorite;
  final bool isCurrent;
  final bool autofocus;
  final VoidCallback onTap;

  const ChannelCard({
    super.key,
    required this.channel,
    required this.onTap,
    this.isFavorite = false,
    this.isCurrent = false,
    this.autofocus = false,
  });

  @override
  State<ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<ChannelCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            scale: active ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: active ? AppColors.surfaceAlt : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active ? AppColors.accent : AppColors.stroke,
                  width: active ? 2 : 1,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: AppColors.accent.withValues(alpha: 0.28),
                          blurRadius: 22,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _logo(active)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: active ? AppColors.textPrimary : AppColors.textPrimary.withValues(alpha: 0.86),
                          ),
                        ),
                      ),
                      if (widget.isFavorite)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.star_rounded, size: 14, color: AppColors.accent),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.channel.displayGroup,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ),
                      if (widget.channel.sourceCount > 1)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.accentDim.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${widget.channel.sourceCount}源',
                            style: const TextStyle(fontSize: 9, color: AppColors.accent),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _logo(bool active) {
    final placeholder = Center(
      child: Text(
        _initials(widget.channel.name),
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: active ? AppColors.accent : AppColors.textSecondary,
          letterSpacing: 1,
        ),
      ),
    );

    if (widget.channel.logo == null || widget.channel.logo!.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: placeholder,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        widget.channel.logo!,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => placeholder,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }

  String _initials(String name) {
    final trimmed = name.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');
    if (trimmed.isEmpty) return 'TV';
    return trimmed.characters.take(2).toString().toUpperCase();
  }
}
