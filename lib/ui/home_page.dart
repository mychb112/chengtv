import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/channel.dart';
import '../theme.dart';
import 'import_dialog.dart';
import 'player_page.dart';
import 'widgets/channel_card.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _allKey = '__all__';
  static const _favKey = '__fav__';
  static const _recentKey = '__recent__';

  String _selected = _allKey;
  String _query = '';
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// 整个进程只自动跳一次：从播放页按「返回主页」回来时不该又被弹进直播
  static bool _bootAutoOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _bootAutoOpened) return;
      _bootAutoOpened = true;
      final app = context.read<AppState>();
      final c = app.defaultChannel();
      // 没有列表（首次安装未导入）就老老实实停在首页
      if (c == null) return;
      _openPlayer(c, app.channels);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<String> _tabs(AppState app) {
    return [
      _allKey,
      if (app.favoriteChannels.isNotEmpty) _favKey,
      if (app.recentChannels.isNotEmpty) _recentKey,
      ...app.groups,
    ];
  }

  String _tabLabel(String key, AppState app) {
    if (key == _allKey) return '全部频道';
    if (key == _favKey) return '我的收藏';
    if (key == _recentKey) return '最近播放';
    return key;
  }

  IconData _tabIcon(String key) {
    if (key == _allKey) return Icons.grid_view_rounded;
    if (key == _favKey) return Icons.star_rounded;
    if (key == _recentKey) return Icons.history_rounded;
    return Icons.live_tv_rounded;
  }

  List<Channel> _visibleChannels(AppState app) {
    List<Channel> base;
    if (_selected == _favKey) {
      base = app.favoriteChannels;
    } else if (_selected == _recentKey) {
      base = app.recentChannels;
    } else if (_selected == _allKey) {
      base = app.channels;
    } else {
      base = app.channels.where((c) => c.displayGroup == _selected).toList();
    }
    if (_query.isEmpty) return base;
    final q = _query.toLowerCase();
    return base.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  void _openPlayer(Channel c, List<Channel> order) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, __, ___) => PlayerPage(channel: c, playOrder: order),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 220),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final tabs = _tabs(app);
    if (!tabs.contains(_selected)) _selected = _allKey;
    final channels = _visibleChannels(app);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            return Column(
              children: [
                _Header(
                  app: app,
                  searchController: _searchController,
                  searchFocus: _searchFocus,
                  onQuery: (v) => setState(() => _query = v.trim()),
                  onImport: () => showImportDialog(context),
                  onClearQuery: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
                const Divider(height: 1, color: AppColors.stroke),
                Expanded(
                  child: app.hasContent
                      ? (wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _CategoryRail(
                                  tabs: tabs,
                                  selected: _selected,
                                  label: (k) => _tabLabel(k, app),
                                  icon: _tabIcon,
                                  onSelect: (k) => setState(() => _selected = k),
                                ),
                                const VerticalDivider(width: 1, color: AppColors.stroke),
                                Expanded(child: _buildGrid(channels, app)),
                              ],
                            )
                          : Column(
                              children: [
                                _CategoryStrip(
                                  tabs: tabs,
                                  selected: _selected,
                                  label: (k) => _tabLabel(k, app),
                                  icon: _tabIcon,
                                  onSelect: (k) => setState(() => _selected = k),
                                ),
                                Expanded(child: _buildGrid(channels, app)),
                              ],
                            ))
                      : _EmptyState(onImport: () => showImportDialog(context)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGrid(List<Channel> channels, AppState app) {
    if (channels.isEmpty) {
      return const Center(
        child: Text(
          '这个分类下还没有频道',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return FocusTraversalGroup(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 0.98,
        ),
        itemCount: channels.length,
        itemBuilder: (context, i) {
          final c = channels[i];
          return ChannelCard(
            key: ValueKey('ch_${c.id}'),
            channel: c,
            isFavorite: app.isFavorite(c),
            onTap: () => _openPlayer(c, channels),
            autofocus: i == 0,
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AppState app;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onQuery;
  final VoidCallback onImport;
  final VoidCallback onClearQuery;

  const _Header({
    required this.app,
    required this.searchController,
    required this.searchFocus,
    required this.onQuery,
    required this.onImport,
    required this.onClearQuery,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.accent, AppColors.accentDim],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.play_arrow_rounded, color: AppColors.bg, size: 22),
          ),
          const SizedBox(width: 10),
          const Text(
            '电视',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 2),
          ),
          const SizedBox(width: 12),
          if (app.playlist.name.isNotEmpty)
            Flexible(
              child: Text(
                '· ${app.playlist.name} · ${app.channels.length} 个频道',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ),
          const Spacer(),
          SizedBox(
            width: 240,
            height: 38,
            child: TextField(
              controller: searchController,
              focusNode: searchFocus,
              onChanged: onQuery,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜索频道',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textSecondary),
                suffixIcon: searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: onClearQuery,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _IconAction(icon: Icons.playlist_add_rounded, tooltip: '导入播放列表', onTap: onImport),
        ],
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconAction({required this.icon, required this.tooltip, required this.onTap});

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _focused ? AppColors.accent : AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _focused ? AppColors.accent : AppColors.stroke),
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: _focused ? AppColors.bg : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  final List<String> tabs;
  final String selected;
  final String Function(String) label;
  final IconData Function(String) icon;
  final ValueChanged<String> onSelect;

  const _CategoryRail({
    required this.tabs,
    required this.selected,
    required this.label,
    required this.icon,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 208,
      color: AppColors.bg,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        itemCount: tabs.length,
        itemBuilder: (context, i) {
          final key = tabs[i];
          return _CategoryItem(
            key: ValueKey('cat_$key'),
            icon: icon(key),
            text: label(key),
            selected: key == selected,
            onTap: () => onSelect(key),
          );
        },
      ),
    );
  }
}

class _CategoryStrip extends StatelessWidget {
  final List<String> tabs;
  final String selected;
  final String Function(String) label;
  final IconData Function(String) icon;
  final ValueChanged<String> onSelect;

  const _CategoryStrip({
    required this.tabs,
    required this.selected,
    required this.label,
    required this.icon,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final key = tabs[i];
          return _CategoryItem(
            key: ValueKey('chip_$key'),
            icon: icon(key),
            text: label(key),
            selected: key == selected,
            compact: true,
            onTap: () => onSelect(key),
          );
        },
      ),
    );
  }
}

class _CategoryItem extends StatefulWidget {
  final IconData icon;
  final String text;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _CategoryItem({
    super.key,
    required this.icon,
    required this.text,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  @override
  State<_CategoryItem> createState() => _CategoryItemState();
}

class _CategoryItemState extends State<_CategoryItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _focused || widget.selected;
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: widget.compact ? EdgeInsets.zero : const EdgeInsets.only(bottom: 6),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 14 : 12,
            vertical: widget.compact ? 6 : 11,
          ),
          decoration: BoxDecoration(
            color: highlight
                ? (_focused ? AppColors.surfaceAlt : AppColors.surface)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.compact ? 20 : 10),
            border: Border.all(
              color: _focused
                  ? AppColors.accent
                  : (widget.selected && !widget.compact
                      ? AppColors.stroke
                      : Colors.transparent),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: widget.compact ? 15 : 17,
                color: highlight ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.compact ? 12.5 : 13.5,
                    fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                    color: highlight ? AppColors.textPrimary : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onImport;

  const _EmptyState({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppColors.stroke),
              ),
              child: const Icon(Icons.live_tv_rounded, size: 40, color: AppColors.accent),
            ),
            const SizedBox(height: 22),
            const Text(
              '还没有频道',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              '导入你自己的 M3U / M3U8 播放列表即可开始观看。\n支持链接导入与本地文件导入。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.7, fontSize: 13),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text('导入播放列表'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.bg,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
