import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../data/app_state.dart';
import '../data/epg.dart';
import '../models/channel.dart';
import 'widgets/auto_fit_text.dart';

/// 播放页配色：深墨底 + 雾青强调，面板半透明玻璃质感。
class _P {
  static const rail = Color(0xF2000000);
  static const panel = Color(0xE60E1A20);
  static const panelSoft = Color(0xCC101E24);
  static const teal = Color(0xFF2E8B8B);
  static const tealDeep = Color(0xFF124B4F);
  static const tealText = Color(0xFF6FE3D2);
  static const white = Color(0xFFFFFFFF);
  static const dim = Color(0xFF98A8B2);
}

enum _FitMode { contain, cover, stretch4x3 }

extension on _FitMode {
  String get label => switch (this) {
    _FitMode.contain => '适应',
    _FitMode.cover => '铺满',
    _FitMode.stretch4x3 => '4:3',
  };
  _FitMode get next => _FitMode.values[(index + 1) % _FitMode.values.length];
}

enum _Panel { none, channels, sources, epg }

class PlayerPage extends StatefulWidget {
  final Channel channel;
  final List<Channel> playOrder;

  const PlayerPage({super.key, required this.channel, required this.playOrder});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  static const _hwChannel = MethodChannel('chengtv/keys');
  static const _sourceTimeout = Duration(seconds: 5);

  late Channel _channel;
  List<ChannelSource> _sources = const [];
  int _srcIndex = 0;

  VideoPlayerController? _controller;
  bool _loading = true;
  bool _allFailed = false;
  String? _error;

  bool _osdVisible = true;
  bool _muted = false;
  // 直播默认「适应」：完整显示原始画面，多余区域留黑边，不裁切不变形
  _FitMode _fit = _FitMode.contain;
  _Panel _panel = _Panel.none;
  String _groupTab = '';

  Timer? _osdTimer;
  Timer? _clockTimer;
  Timer? _toastTimer;
  Timer? _digitTimer;
  Timer? _watchdog;

  /// 面板闲置计时：弹出后 5 秒内没有任何操作就自动收起，别挡着直播画面
  Timer? _panelIdleTimer;
  static const _kPanelIdle = Duration(seconds: 5);

  /// 操作栏（含右下信息栏与左侧「频道」提示条）的自动隐藏时长，
  /// 与面板的闲置时长保持一致，避免换台后信息栏一直挂在画面上
  static const _kOsdIdle = Duration(seconds: 5);

  String _clock = '';
  String? _toast;
  String _digitBuffer = '';

  /// 右侧上下滑动换台的累计位移
  double _swipeDy = 0;

  /// 播放代次：切换频道/源时自增，用于丢弃过期的异步回调
  int _gen = 0;

  final _rootFocus = FocusNode(debugLabel: 'player_root');
  final _panelFocus = FocusNode(debugLabel: 'panel_first');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel = widget.channel;
    _groupTab = _channel.displayGroup;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _hwChannel.setMethodCallHandler((call) async {
      if (call.method == 'hardwareKey' && mounted) {
        _onHardwareKey(call.arguments as String);
      }
      return null;
    });

    _tickClock();
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickClock(),
    );
    _restartOsdTimer();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      _startChannel(_channel, app: app);
      // 横屏切换完成后系统才给出正确的挖孔方向，这里补读一次
      app.refreshDisplayInfo();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hwChannel.setMethodCallHandler(null);
    _osdTimer?.cancel();
    _clockTimer?.cancel();
    _toastTimer?.cancel();
    _digitTimer?.cancel();
    _watchdog?.cancel();
    _panelIdleTimer?.cancel();
    _gen++;
    _controller?.dispose();
    _rootFocus.dispose();
    _panelFocus.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller?.pause();
    } else if (state == AppLifecycleState.resumed) {
      _controller?.play();
      context.read<AppState>().refreshDisplayInfo();
    }
  }

  /// 屏幕旋转/窗口尺寸变化后挖孔位置会换边，重新读一次安全区
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().refreshDisplayInfo();
    });
  }

  void _tickClock() {
    final now = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    if (mounted) {
      setState(() {
        _clock = '${p(now.hour)}:${p(now.minute)}:${p(now.second)}';
      });
    }
  }

  // ---------------- 播放与选源 ----------------

  Future<void> _startChannel(
    Channel c, {
    required AppState app,
    int? startIndex,
  }) async {
    final gen = ++_gen;
    final ordered = app.orderedSources(c);
    if (!mounted) return;
    setState(() {
      _channel = c;
      _sources = ordered;
      _allFailed = false;
      _error = null;
      _loading = true;
      _srcIndex = (startIndex ?? 0).clamp(
        0,
        ordered.isEmpty ? 0 : ordered.length - 1,
      );
    });
    app.markPlayed(c);

    await _tryFrom(_srcIndex, gen);
  }

  /// 从指定线路开始依次尝试，直到成功或全部失败。
  Future<void> _tryFrom(int start, int gen) async {
    if (_sources.isEmpty) {
      if (gen == _gen && mounted) {
        setState(() {
          _loading = false;
          _allFailed = true;
          _error = '该频道没有可用的信号源';
        });
      }
      return;
    }

    final tried = <int>{};
    var idx = start;
    while (mounted && gen == _gen) {
      tried.add(idx);
      if (mounted) {
        setState(() {
          _srcIndex = idx;
          _loading = true;
          _error = null;
        });
      }

      final ok = await _attempt(_sources[idx], gen);
      if (!mounted || gen != _gen) return;
      if (ok) {
        setState(() => _loading = false);
        return;
      }

      if (tried.length >= _sources.length) {
        setState(() {
          _loading = false;
          _allFailed = true;
          _error = '全部信号源不可用';
        });
        return;
      }

      final next = _nextUntried(tried, idx);
      _showToast('线路 ${idx + 1} 无响应，切换线路 ${next + 1}');
      idx = next;
    }
  }

  int _nextUntried(Set<int> tried, int from) {
    for (var step = 1; step <= _sources.length; step++) {
      final i = (from + step) % _sources.length;
      if (!tried.contains(i)) return i;
    }
    return from;
  }

  /// 单条源尝试；5 秒内没起来就算失败。
  Future<bool> _attempt(ChannelSource source, int gen) async {
    final old = _controller;
    _controller = null;
    await old?.dispose();

    if (source.url.toLowerCase().startsWith('rtmp') ||
        source.url.toLowerCase().startsWith('rtsp') ||
        source.url.toLowerCase().startsWith('udp')) {
      // 当前内核不支持，直接判定失败，交给下一条线路
      return false;
    }

    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(source.url),
      httpHeaders: {
        'User-Agent': source.userAgent ?? 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        if (source.referer != null) 'Referer': source.referer!,
      },
    );
    _controller = ctrl;

    try {
      await ctrl.initialize().timeout(_sourceTimeout);
    } catch (_) {
      if (_controller == ctrl) _controller = null;
      _safeDispose(ctrl);
      return false;
    }
    if (!mounted || gen != _gen) {
      _safeDispose(ctrl);
      return false;
    }

    try {
      ctrl.setVolume(_muted ? 0 : 1);
      await ctrl.play();
    } catch (_) {
      if (_controller == ctrl) _controller = null;
      _safeDispose(ctrl);
      return false;
    }

    ctrl.addListener(_onControllerTick);

    // 记录实测分辨率，用于下次"选质量最好的源"
    final size = ctrl.value.size;
    if (size.height > 0) {
      context.read<AppState>().recordResolution(
        source.url,
        size.height.round(),
      );
    }
    context.read<AppState>().rememberSource(_channel.id, source);

    _armWatchdog(gen);
    return true;
  }

  void _safeDispose(VideoPlayerController c) {
    c.removeListener(_onControllerTick);
    c.dispose().catchError((_) {});
  }

  /// 持续缓冲超过 5 秒 → 认为源质量不佳，自动切下一条。
  void _armWatchdog(int gen) {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (t) async {
      final c = _controller;
      if (!mounted || gen != _gen || c == null) {
        t.cancel();
        return;
      }
      if (c.value.hasError) {
        t.cancel();
        _failoverCurrent('线路 ${_srcIndex + 1} 播放中断');
        return;
      }
      if (c.value.isBuffering) {
        _bufferingSeconds++;
        if (_bufferingSeconds >= 5) {
          t.cancel();
          _failoverCurrent('线路 ${_srcIndex + 1} 缓冲超时');
        }
      } else {
        _bufferingSeconds = 0;
      }
    });
  }

  int _bufferingSeconds = 0;
  bool _failingOver = false;

  Future<void> _failoverCurrent(String reason) async {
    if (!mounted || _failingOver) return;
    _failingOver = true;
    try {
      if (_sources.length <= 1) {
        setState(() {
          _loading = false;
          _allFailed = true;
          _error = '全部信号源不可用';
        });
        return;
      }
      final next = _nextUntried({_srcIndex}, _srcIndex);
      _bufferingSeconds = 0;
      _showToast('$reason，切换线路 ${next + 1}');
      await _tryFrom(next, _gen);
    } finally {
      _failingOver = false;
    }
  }

  void _onControllerTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    if (c.value.hasError && !_allFailed) {
      _failoverCurrent('播放中断');
    }
  }

  Future<void> _switchSource(int index) async {
    if (index < 0 || index >= _sources.length) return;
    _cancelPanelIdle();
    setState(() {
      _panel = _Panel.none;
      _srcIndex = index;
      _loading = true;
      _allFailed = false;
      _error = null;
    });
    _rootFocus.requestFocus();
    final gen = ++_gen;
    setState(() {});
    await _tryFrom(index, gen);
  }

  /// 信息栏底排「换源」按钮：每点一次切到下一个信号源，到尾再从头循环
  void _cycleSource() {
    if (_sources.length < 2) {
      _showToast('该频道只有 1 个信号源');
      _showOsd();
      return;
    }
    final next = (_srcIndex + 1) % _sources.length;
    _showToast('切换信号源 ${next + 1}/${_sources.length}');
    _switchSource(next);
    _showOsd();
  }

  void _zap(int delta) {
    if (widget.playOrder.length < 2) return;
    final i = _currentOrderIndex;
    var n = (i + delta) % widget.playOrder.length;
    if (n < 0) n += widget.playOrder.length;
    final next = widget.playOrder[n];
    _showToast('${n + 1}/${widget.playOrder.length}  ${next.name}');
    _startChannel(next, app: context.read<AppState>());
    // 换台后把操作栏唤出来让大家看到台名，但必须重新计时，
    // 否则信息栏和左侧「频道」提示条会一直挂在画面上不消失
    _showOsd();
  }

  int get _currentOrderIndex {
    final i = widget.playOrder.indexWhere((e) => e.id == _channel.id);
    return i < 0 ? 0 : i;
  }

  // ---------------- OSD 控制 ----------------

  void _showToast(String msg) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  /// 唤出操作栏并重新计时：任何操作（点击、换台、换源、遥控器按键）
  /// 都走这里，5 秒没有后续操作就自动淡出
  void _showOsd() {
    if (!mounted) return;
    setState(() => _osdVisible = true);
    _restartOsdTimer();
  }

  void _hideOsd() {
    _cancelPanelIdle();
    setState(() {
      _osdVisible = false;
      _panel = _Panel.none;
    });
  }

  void _restartOsdTimer() {
    _osdTimer?.cancel();
    _osdTimer = Timer(_kOsdIdle, () {
      if (!mounted) return;
      // 面板还开着时交给面板自己的闲置计时处理
      if (_panel != _Panel.none) return;
      setState(() => _osdVisible = false);
    });
  }

  void _openPanel(_Panel p) {
    setState(() {
      _panel = p;
      _osdVisible = true;
    });
    _osdTimer?.cancel();
    _armPanelIdle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panel != _Panel.none) _panelFocus.requestFocus();
    });
  }

  void _closePanel() {
    _cancelPanelIdle();
    setState(() => _panel = _Panel.none);
    _rootFocus.requestFocus();
    _restartOsdTimer();
  }

  /// 重新计时：面板还开着的话，5 秒后自动收起
  void _armPanelIdle() {
    _panelIdleTimer?.cancel();
    if (_panel == _Panel.none) return;
    _panelIdleTimer = Timer(_kPanelIdle, () {
      if (!mounted || _panel == _Panel.none) return;
      _closePanel();
    });
  }

  void _cancelPanelIdle() {
    _panelIdleTimer?.cancel();
    _panelIdleTimer = null;
  }

  void _toggleFavorite() {
    final app = context.read<AppState>();
    app.toggleFavorite(_channel);
    _showToast(app.isFavorite(_channel) ? '已加入收藏' : '已取消收藏');
  }

  /// 频道列表长按 2 秒：收藏 / 取消收藏（收藏分类里同样操作即为取消）
  void _toggleFavoriteChannel(Channel c) {
    final app = context.read<AppState>();
    final wasFav = app.isFavorite(c);
    HapticFeedback.selectionClick();
    app.toggleFavorite(c);
    _showToast(wasFav ? '已取消收藏 · ${c.name}' : '已收藏 · ${c.name}');
  }

  /// 回到应用启动时的频道主界面
  void _backToHome() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.popUntil((r) => r.isFirst);
    } else {
      _showToast('已经在频道主界面');
    }
  }

  void _cycleFit() {
    setState(() => _fit = _fit.next);
    _showToast('画面：${_fit.label}');
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller?.setVolume(_muted ? 0 : 1);
    _showToast(_muted ? '已静音' : '已取消静音');
  }

  void _handleDigit(String d) {
    _digitBuffer += d;
    _digitTimer?.cancel();
    _digitTimer = Timer(const Duration(seconds: 2), () {
      final num = int.tryParse(_digitBuffer);
      _digitBuffer = '';
      if (!mounted || num == null || num < 1) return;
      if (num <= widget.playOrder.length) {
        _playChannel(widget.playOrder[num - 1]);
      } else {
        _showToast('没有第 $num 号频道');
      }
    });
    _showToast('跳转：$_digitBuffer');
  }

  void _playChannel(Channel c) {
    _cancelPanelIdle();
    setState(() => _panel = _Panel.none);
    _rootFocus.requestFocus();
    _startChannel(c, app: context.read<AppState>());
  }

  // ---------------- 按键 ----------------

  void _onHardwareKey(String kind) {
    switch (kind) {
      case 'color0':
        _openPanel(_Panel.epg);
        break;
      case 'color1':
        _openQuickMenu();
        break;
      case 'color2':
        _openPanel(_Panel.channels);
        break;
      case 'color3':
        _onTimeshift();
        break;
      case 'chUp':
        _zap(-1);
        break;
      case 'chDown':
        _zap(1);
        break;
      case 'info':
        _showOsd();
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // 遥控器上任何一次按键都算"有操作"，重新开始数面板的 5 秒
    if (_panel != _Panel.none) _armPanelIdle();

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (_panel != _Panel.none) {
        _closePanel();
        return KeyEventResult.handled;
      }
      if (_osdVisible) {
        _hideOsd();
        return KeyEventResult.handled;
      }
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }

    // 数字键直选频道
    if (key.keyLabel.length == 1 && '0123456789'.contains(key.keyLabel)) {
      _handleDigit(key.keyLabel);
      return KeyEventResult.handled;
    }

    // OSD 打开时方向键交给焦点系统，用于在面板/按钮间移动
    final panelOpen = _panel != _Panel.none;
    if (panelOpen) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.channelUp) {
      _zap(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.channelDown) {
      _zap(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _openPanel(_Panel.channels);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _cycleFit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (_osdVisible) {
        _hideOsd();
      } else {
        _showOsd();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu) {
      _openPanel(_Panel.channels);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFavorite();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      _openPanel(_Panel.sources);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onTimeshift() {
    if (_channel.canCatchup) {
      _openPanel(_Panel.epg);
      _showToast('该频道支持回看，可在节目单中选择');
    } else {
      _showToast('该频道不支持时移/回看');
    }
  }

  // ---------------- 快捷菜单（换源 / 收藏 / 设置） ----------------

  Future<void> _openQuickMenu() async {
    setState(() => _osdVisible = true);
    _osdTimer?.cancel();
    final app = context.read<AppState>();
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _QuickMenu(
        favorite: app.isFavorite(_channel),
        sourceCount: _sources.length,
        fitLabel: _fit.label,
        onSources: () {
          Navigator.of(ctx).pop();
          _openPanel(_Panel.sources);
        },
        onFavorite: () {
          Navigator.of(ctx).pop();
          _toggleFavorite();
        },
        onFit: () {
          Navigator.of(ctx).pop();
          _cycleFit();
        },
        onMute: () {
          Navigator.of(ctx).pop();
          _toggleMute();
        },
        onSettings: () {
          Navigator.of(ctx).pop();
          _showToast('播放设置：画面 ${_fit.label} · ${_muted ? "已静音" : "有声"}');
        },
      ),
    );
    if (mounted) _restartOsdTimer();
  }

  // ---------------- 构 建 ----------------

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_panel != _Panel.none) {
              _closePanel();
            } else if (_osdVisible) {
              _hideOsd();
            } else {
              _showOsd();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildVideo(),
              if (_loading) _buildLoading(),
              if (_toast != null) _buildToast(),
              if (_digitBuffer.isNotEmpty) _buildDigit(),
              // 左侧触摸热区（放在 OSD 之下，不遮挡面板本身的点击）
              _buildLeftTouchZone(),
              // 右侧半屏上下滑动换台（放在 OSD 之下，不挡信息栏的点击）
              _buildRightSwipeZone(),
              AnimatedOpacity(
                opacity: _osdVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_osdVisible,
                  child: _buildOsd(app),
                ),
              ),
              if (_allFailed) _buildAllFailed(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    final size = c.value.size;
    if (size.width == 0 || size.height == 0) return const SizedBox.shrink();

    switch (_fit) {
      case _FitMode.contain:
        return Center(
          child: AspectRatio(
            aspectRatio: size.width / size.height,
            child: VideoPlayer(c),
          ),
        );
      case _FitMode.cover:
        return FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(c),
          ),
        );
      case _FitMode.stretch4x3:
        return Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: VideoPlayer(c),
              ),
            ),
          ),
        );
    }
  }

  Widget _buildLoading() {
    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: _P.tealText,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '正在连接 线路 ${_srcIndex + 1}/${_sources.length}',
            style: const TextStyle(color: _P.dim, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  /// 关闭「全部信号源不可用」提示层，回到播放界面继续选台。
  ///
  /// 这里必须把播放器彻底停掉：否则 controller 一直停在 error 状态，
  /// 监听回调和缓冲看门狗会立刻再触发一次失败流程，遮罩刚关掉又弹回来。
  void _dismissAllFailed() {
    ++_gen; // 让仍在重试的 _tryFrom 立即退出
    _watchdog?.cancel();
    final c = _controller;
    _controller = null;
    if (c != null) _safeDispose(c);

    setState(() {
      _allFailed = false;
      _error = null;
      _loading = false;
    });

    _rootFocus.requestFocus();
    // 此时没有画面，直接把频道列表打开，用户可以立刻换台；
    // 5 秒不动它仍会像平时一样自动收起
    _openPanel(_Panel.channels);
    _showToast('已关闭，可继续选择频道');
  }

  Widget _buildAllFailed() {
    return Container(
      color: Colors.black.withValues(alpha: 0.82),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            size: 34,
            color: Color(0xFFFF6B6B),
          ),
          const SizedBox(height: 14),
          const Text(
            '全部信号源不可用',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _P.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error == '全部信号源不可用'
                ? '已尝试该频道全部 ${_sources.length} 条线路'
                : (_error ?? '已尝试该频道全部 ${_sources.length} 条线路'),
            style: const TextStyle(fontSize: 12, color: _P.dim),
          ),
          const SizedBox(height: 20),
          Padding(
            // 四个按钮按内容宽度排，整体在屏幕水平居中；
            // 极窄屏放不下一行时自动换行，仍然居中，不会溢出
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                _flatButton('重新检测', () {
                  final gen = ++_gen;
                  setState(() {
                    _allFailed = false;
                    _error = null;
                  });
                  _tryFrom(0, gen);
                }),
                _flatButton('选择线路', () => _openPanel(_Panel.sources)),
                _flatButton('下一个频道', () => _zap(1)),
                _flatButton('关闭', _dismissAllFailed),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _flatButton(String text, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: _P.tealDeep,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _P.teal),
          ),
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: _P.white),
          ),
        ),
      ),
    );
  }

  // --- OSD 主体：左侧分类 + 频道/源/节目单面板 + 右侧信息 ---

  Widget _buildOsd(AppState app) {
    final showPanels = _panel != _Panel.none;
    final media = MediaQuery.of(context);
    // 挖孔/刘海安全区：沉浸模式下 MediaQuery.padding 经常被清零，
    // 所以和原生 displayCutout 读数取最大值，谁准用谁。
    final safeLeft = math.max(
      math.max(media.padding.left, media.viewPadding.left),
      app.cutoutLeft,
    );
    final safeRight = math.max(
      math.max(media.padding.right, media.viewPadding.right),
      app.cutoutRight,
    );
    final safeBottom = math.max(
      math.max(media.padding.bottom, media.viewPadding.bottom),
      app.cutoutBottom,
    );

    return LayoutBuilder(
      builder: (context, c) {
        // 宽度只按屏幕算一次：先给右侧留出目标列宽，剩余给左侧面板。
        // 这样面板开合不会让右侧元素重新缩放，位置和宽度始终不变。
        final w = c.maxWidth;
        final railW = w >= 1100 ? 176.0 : 148.0;
        // 左栏整体让开前置摄像头。判断依据是挖孔本身，不能看屏幕宽度：
        // 横屏手机普遍 900dp 以上，按宽度判断会把手机误当成平板而完全不让位。
        // 系统一点挖孔信息都没给时，手机仍留 24dp，避免面板贴着物理边缘。
        final leftInset = safeLeft > 0
            ? safeLeft + 10
            : (app.isPhone ? 24.0 : 0.0);
        // 右侧留出不贴曲面边缘的余量
        final margin = (w >= 1100 ? 26.0 : 14.0) + safeRight * 0.6;
        final bottomMargin = 12.0 + safeBottom * 0.4;

        // 左侧面板约占屏幕 1/5（夹在 170~320），剩下的宽度全给右侧合并信息栏。
        // 两个值都只跟屏幕宽度有关，面板开合不会让它们变化。
        final panelW = (w * 0.22).clamp(170.0, 320.0);
        final barW = (w - leftInset - railW - panelW - margin * 2).clamp(
          300.0,
          640.0,
        );

        // 面板区域里的任何触摸、拖动、滚轮都算"有操作"，重新开始数 5 秒；
        // 到点没动静就自动收起面板，手机与电视（遥控器按键另计）行为一致
        return Listener(
          onPointerDown: (_) => _armPanelIdle(),
          onPointerMove: (_) => _armPanelIdle(),
          onPointerSignal: (_) => _armPanelIdle(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showPanels) SizedBox(width: leftInset),
              if (showPanels) _buildRail(app, railW),
              if (showPanels) _buildPanel(app, panelW),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, cc) {
                    // 极端窄屏下兜底，避免固定宽度超出可用区域
                    final bw = math.min(barW, cc.maxWidth - margin);
                    return Stack(
                      children: [
                        // 台标 / 节目单 / 回看预约 合成一条，固定在右下角
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: margin,
                              bottom: bottomMargin,
                            ),
                            child: _buildInfoBar(app, bw),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 播放画面左侧的触摸热区：点一下弹出分类与频道列表，再点一下收起。
  /// 整条区域跟随挖孔让位一起右移，提示条不会压在前置摄像头上；
  /// 面板打开时热区只剩让位那一条，不会挡住栏本身的点击。
  /// 右侧半屏的上下滑动换台热区：上滑下一个频道，下滑上一个频道。
  /// 左半边完全不响应，翻频道列表或误触都不会切台。
  Widget _buildRightSwipeZone() {
    final half = MediaQuery.of(context).size.width * 0.5;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: half,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) => _swipeDy = 0,
        onVerticalDragUpdate: (d) => _swipeDy += d.delta.dy,
        onVerticalDragEnd: (d) {
          final dy = _swipeDy;
          final v = d.primaryVelocity ?? 0;
          _swipeDy = 0;
          // 位移够 60dp 或甩动速度够快都算一次有效滑动
          if (dy < -60 || v < -180) {
            _zap(1); // 上滑：下一个频道
          } else if (dy > 60 || v > 180) {
            _zap(-1); // 下滑：上一个频道
          }
        },
      ),
    );
  }

  Widget _buildLeftTouchZone() {
    final app = context.watch<AppState>();
    final media = MediaQuery.of(context);
    final safeLeft = math.max(
      math.max(media.padding.left, media.viewPadding.left),
      app.cutoutLeft,
    );
    final pad = safeLeft > 0 ? safeLeft + 10 : (app.isPhone ? 24.0 : 0.0);
    final panelOpen = _panel != _Panel.none;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: pad + (panelOpen ? 8 : 86),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (panelOpen) {
            _closePanel();
          } else {
            _openPanel(_Panel.channels);
          }
        },
        child: Padding(
          padding: EdgeInsets.only(left: pad),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedOpacity(
              opacity: (_osdVisible && !panelOpen) ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Container(
                width: 34,
                height: 96,
                decoration: const BoxDecoration(
                  color: Color(0x8C000000),
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(8),
                  ),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: Color(0xFFBFD3D8),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '频道',
                      style: TextStyle(
                        fontSize: 9,
                        color: Color(0xFFBFD3D8),
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRail(AppState app, double width) {
    final tabs = <String>['收藏', ...app.groups];
    return Container(
      width: width,
      color: _P.rail,
      padding: const EdgeInsets.only(top: 18, bottom: 14),
      // 分类栏是固定宽度的导航条，属于「界面骨架」而不是正文：
      // 不跟随系统字体倍率。系统字体调到特大时若跟着放大，4 个汉字会挤成「央视…」，
      // 而这一栏的宽度是按设计稿定死的，只能让字号保持设计值。
      child: MediaQuery.withNoTextScaling(
        child: ListView.builder(
          itemCount: tabs.length,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          itemBuilder: (context, i) {
            final g = tabs[i];
            final selected = g == _groupTab;
            return _RailItem(
              key: ValueKey('rail_$g'),
              text: g,
              selected: selected,
              autofocus: i == 0 && _panel == _Panel.channels,
              focusNode: i == 0 ? _panelFocus : null,
              onTap: () {
                setState(() {
                  _groupTab = g;
                  _panel = _Panel.channels;
                });
                _showOsd();
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildPanel(AppState app, double width) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [_P.panel, _P.panelSoft],
        ),
      ),
      child: MediaQuery.withNoTextScaling(
        // 整个频道面板（频道列表 / 信号源 / 节目单）都是按设计稿定死列宽的
        // 紧凑布局：统一不跟随系统字体倍率，否则系统字体调到「特大」时
        // 每一行都会被压成「央视…」。确实放不下的长名字由 AutoFitText 收缩或折行。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _panelBody(app)),
            _buildChannelInfoFooter(),
          ],
        ),
      ),
    );
  }

  Widget _panelBody(AppState app) {
    switch (_panel) {
      case _Panel.channels:
        final list = _channelsOfTab(app);
        return Column(
          children: [
            // 表头固定在列表外，不占用任何条目位，保证第 1 条就是第 1 个频道
            _listHeader(
              _groupTab.isEmpty ? '全部频道' : _groupTab,
              _groupTab == '收藏'
                  ? '${list.length} 个 · 长按取消'
                  : '${list.length} 个 · 长按收藏',
            ),
            Expanded(
              child: list.isEmpty
                  ? _emptyData()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final c = list[i];
                        final fav = app.isFavorite(c);
                        return _PanelRow(
                          key: ValueKey('pc_${c.id}'),
                          title: c.name,
                          number: i + 1,
                          trailing: '${c.sourceCount}源',
                          selected: c.id == _channel.id,
                          favorite: fav,
                          onTap: () => _playChannel(c),
                          // 长按 2 秒：收藏 / 取消收藏（「收藏」分类里长按即取消）
                          onLongPress: () => _toggleFavoriteChannel(c),
                        );
                      },
                    ),
            ),
          ],
        );
      case _Panel.sources:
        return Column(
          children: [
            _listHeader('信号源 · ${_channel.name}', '共 ${_sources.length} 条'),
            Expanded(
              child: _sources.isEmpty
                  ? _emptyData()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                      itemCount: _sources.length,
                      itemBuilder: (context, idx) {
                        final s = _sources[idx];
                        final h = app.sourceHeight[s.url];
                        final sub = [
                          s.qualityLabel,
                          if (h != null && h > 0) '${h}P',
                          s.hostLabel,
                        ].join(' · ');
                        return _PanelRow(
                          key: ValueKey('ps_$idx'),
                          title: '线路 ${idx + 1}',
                          subtitle: sub,
                          selected: idx == _srcIndex,
                          onTap: () => _switchSource(idx),
                        );
                      },
                    ),
            ),
          ],
        );
      case _Panel.epg:
        return _buildEpgPanel(app);
      case _Panel.none:
        return const SizedBox.shrink();
    }
  }

  List<Channel> _channelsOfTab(AppState app) {
    if (_groupTab == '收藏') return app.favoriteChannels;
    if (_groupTab.isEmpty) return app.channels;
    return app.channels.where((c) => c.displayGroup == _groupTab).toList();
  }

  Widget _emptyData() {
    return const Center(
      child: Text('暂无数据', style: TextStyle(fontSize: 15, color: _P.dim)),
    );
  }

  /// 列表面板固定表头（在 ListView 之外，不占条目序号）
  Widget _listHeader(String title, String trailing) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _P.white,
              ),
            ),
          ),
          Text(trailing, style: const TextStyle(fontSize: 10.5, color: _P.dim)),
        ],
      ),
    );
  }

  Widget _buildEpgPanel(AppState app) {
    final programs = app.programsFor(_channel);
    final hasData = programs != null && programs.isNotEmpty;
    return Column(
      children: [
        _epgHeader(app, hasData),
        Expanded(child: hasData ? _epgList(app, programs) : _epgEmpty(app)),
      ],
    );
  }

  Widget _epgHeader(AppState app, bool hasData) {
    final now = DateTime.now();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '节目单 · ${_channel.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: _P.white,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${now.month}月${now.day}日 · ${app.epg.isEmpty ? "未载入节目单" : "共 ${app.epg.length} 个频道"}',
                  style: const TextStyle(fontSize: 10.5, color: _P.dim),
                ),
              ],
            ),
          ),
          _miniButton(
            hasData ? '重载' : '设置',
            () => _openEpgConfig(),
            autofocus: !hasData,
          ),
        ],
      ),
    );
  }

  Widget _epgEmpty(AppState app) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 18),
          const Icon(Icons.event_note_rounded, size: 30, color: _P.dim),
          const SizedBox(height: 12),
          const Text(
            '还没有节目单数据',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _P.white,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '载入 XMLTV 节目单后，这里会列出当天节目，可直接预约和回看。\n'
            '支持 .xml / .xml.gz 订阅地址，也支持本地文件。',
            style: TextStyle(fontSize: 11.5, color: _P.dim, height: 1.7),
          ),
          const SizedBox(height: 16),
          _wideButton('填入订阅地址', Icons.link_rounded, () => _openEpgConfig()),
          const SizedBox(height: 8),
          _wideButton(
            '从本地文件导入',
            Icons.folder_open_rounded,
            () => _importEpgFile(app),
          ),
          if (app.epgUrl.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              '上次来源：${app.epgUrl}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: _P.dim),
            ),
            const SizedBox(height: 6),
            _wideButton('重新载入上次来源', Icons.refresh_rounded, () async {
              if (app.epgUrl.startsWith('http')) {
                await app.loadEpg(app.epgUrl);
                if (mounted) _showToast(app.lastError ?? '节目单已更新');
              } else {
                _showToast('上次来源是本地文件，请重新选择文件');
              }
            }),
          ],
        ],
      ),
    );
  }

  Widget _epgList(AppState app, List<EpgProgram> programs) {
    final now = DateTime.now();
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: programs.length,
            itemBuilder: (context, i) {
              final p = programs[i];
              final playing = p.contains(now);
              final reminded = app.hasReminder(_channel, p);
              return _EpgRow(
                key: ValueKey('epg_${p.start.millisecondsSinceEpoch}'),
                program: p,
                playing: playing,
                reminded: reminded,
                onTap: () {
                  if (playing) {
                    _showToast('正在播出');
                    return;
                  }
                  if (reminded) {
                    app.removeReminder(_channel, p);
                    _showToast('已取消预约');
                  } else {
                    app.addReminder(_channel, p);
                    _showToast('已预约 ${_hhmm(p.start)} ${p.title}');
                  }
                },
                onCatchup: () {
                  if (!_channel.canCatchup) {
                    _showToast('该频道不支持回看（源未声明 catchup）');
                    return;
                  }
                  _playCatchup(p);
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 11, color: _P.dim),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _channel.canCatchup
                      ? 'OK 预约 · 长按/C 键回看'
                      : 'OK 预约 · 该源未声明 catchup，暂不支持回看',
                  style: const TextStyle(fontSize: 10, color: _P.dim),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _miniButton(
    String text,
    VoidCallback onTap, {
    bool autofocus = false,
  }) {
    return Focus(
      autofocus: autofocus,
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _P.tealDeep,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: _P.teal),
          ),
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: _P.white),
          ),
        ),
      ),
    );
  }

  Widget _wideButton(String text, IconData icon, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF16262B),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF2A4A4E)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: _P.tealText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 12, color: _P.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importEpgFile(AppState app) async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['xml', 'gz', 'txt'],
        dialogTitle: '选择 XMLTV 节目单',
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        _showToast('文件为空');
        return;
      }
      // 交给 AppState 统一处理（自动识别 gzip / 编码）
      await app.importEpgBytes(bytes, source: picked.name);
      if (!mounted) return;
      _showToast(app.lastError ?? '节目单已载入，共 ${app.epg.length} 个频道');
    } catch (e) {
      _showToast('导入失败：$e');
    }
  }

  Future<void> _openEpgConfig() async {
    final app = context.read<AppState>();
    final url = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _EpgConfigDialog(
        initial: app.epgUrl.startsWith('http') ? app.epgUrl : '',
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    await app.loadEpg(url);
    if (!mounted) return;
    _showToast(app.lastError ?? '节目单已载入，共 ${app.epg.length} 个频道');
  }

  Future<void> _playCatchup(EpgProgram p) async {
    final catchup = _channel.catchup;
    if (catchup == null) return;
    final base = _sources.isEmpty ? '' : _sources[_srcIndex].url;
    final url = catchup.buildUrl(
      base,
      p.start,
      p.stop.add(const Duration(minutes: 1)),
    );
    setState(() {
      _panel = _Panel.none;
      _loading = true;
      _allFailed = false;
    });
    _rootFocus.requestFocus();
    final gen = ++_gen;
    final ok = await _attempt(
      ChannelSource(url: url, rawLabel: '回看', baseScore: 0),
      gen,
    );
    if (!mounted || gen != _gen) return;
    if (ok) {
      setState(() => _loading = false);
      _showToast('回看：${p.title}');
    } else {
      setState(() {
        _loading = false;
        _error = '回看源不可用';
      });
      _showToast('回看源不可用');
    }
  }

  /// 面板底部：频道号 + 线路 + 可回看 + 频道名
  Widget _buildChannelInfoFooter() {
    final num = _currentOrderIndex + 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '$num',
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w300,
              color: Color(0x99FFFFFF),
              height: 1,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_channel.name}${_channel.canCatchup ? " · 可回看" : ""}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: _P.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Text(
                      '线路 ${_srcIndex + 1}/${_sources.length}',
                      style: const TextStyle(fontSize: 11, color: _P.dim),
                    ),
                    if (_sources.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        _sources[_srcIndex].qualityLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          color: _P.tealText,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 右下：当前节目 / 下一节目 / 按键提示
  /// 右下角一体化信息栏的数据装配：台标信息 | 当前·下一节目 | 回看 / 预约
  Widget _buildInfoBar(AppState app, double width) {
    final programs = app.programsFor(_channel);
    final (cur, next) = EpgParser.currentAndNext(programs, DateTime.now());
    return _InfoBar(
      width: width,
      channel: _channel,
      sourceCount: _sources.length,
      sourceIndex: _srcIndex,
      quality: _sources.isEmpty
          ? null
          : _sources[_srcIndex.clamp(0, _sources.length - 1)].qualityLabel,
      curTitle: cur?.title,
      nextText: next == null ? null : '${_hhmm(next.start)} ${next.title}',
      clock: _clock,
      onTap: () => _openPanel(_Panel.epg),
      onZap: _zap,
      onBackHome: _backToHome,
      onCycleSource: _cycleSource,
    );
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _buildToast() {
    return Align(
      alignment: const Alignment(0, -0.78),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2A3A42)),
        ),
        child: Text(
          _toast!,
          style: const TextStyle(
            fontSize: 13,
            color: _P.white,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildDigit() {
    return Align(
      alignment: const Alignment(0.86, -0.6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _P.teal,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          _digitBuffer,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 3,
          ),
        ),
      ),
    );
  }
}

// ---------------- 组件 ----------------

/// 右下角一体化信息栏：台标信息 ｜ 当前·下一节目 ｜ 回看 / 预约
class _InfoBar extends StatefulWidget {
  final double width;
  final Channel channel;
  final int sourceCount;
  final int sourceIndex;
  final String? quality;
  final String? curTitle;
  final String? nextText;
  final String clock;
  final VoidCallback onTap;

  /// 整条栏的上/下竖滑换台（正值：下滑上一个频道；负值：上滑下一个频道）
  final ValueChanged<int> onZap;

  /// 「返回主页」按钮：回到应用启动时的频道主界面
  final VoidCallback onBackHome;

  /// 底排「换源」按钮：切到下一个信号源
  final VoidCallback onCycleSource;

  const _InfoBar({
    required this.width,
    required this.channel,
    required this.sourceCount,
    required this.sourceIndex,
    required this.clock,
    required this.onTap,
    required this.onZap,
    required this.onBackHome,
    required this.onCycleSource,
    this.quality,
    this.curTitle,
    this.nextText,
  });

  @override
  State<_InfoBar> createState() => _InfoBarState();
}

class _InfoBarState extends State<_InfoBar> {
  bool _focused = false;
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    // 信息栏和左侧频道面板一样是固定列宽的紧凑排版，不跟随系统字体倍率：
    // 系统字体一大，「回看 / 预约」就会被挤成「回看 / …」
    return MediaQuery.withNoTextScaling(child: _buildBar(context));
  }

  Widget _buildBar(BuildContext context) {
    // 栏体越窄，右侧按钮和竖线分隔越紧凑，把宽度让给台标与节目名
    final w = widget.width;
    // 按钮列宽按「回看 / 预约」6 个字形留足：字号固定后 14 号约需 72dp，
    // 再留一点余量，避免贴边
    final ctaW = w < 360 ? 68.0 : (w < 430 ? 80.0 : 94.0);
    final divPad = w < 430 ? 8.0 : 12.0;

    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        // 栏体本身也吃掉竖滑，保证「整个右侧」到处都能换台，
        // 单击仍然是打开节目单（没有位移时 tap 胜出）
        onVerticalDragStart: (_) => _dy = 0,
        onVerticalDragUpdate: (d) => _dy += d.delta.dy,
        onVerticalDragEnd: (d) {
          final dy = _dy;
          final v = d.primaryVelocity ?? 0;
          _dy = 0;
          if (dy < -60 || v < -180) {
            widget.onZap(1); // 上滑：下一个频道
          } else if (dy > 60 || v > 180) {
            widget.onZap(-1); // 下滑：上一个频道
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.width,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: _focused
                ? const Color(0xFF1B6B70)
                : _P.tealDeep.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused ? _P.tealText : _P.teal,
              width: _focused ? 2 : 1.2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 上排：台标信息 ｜ 当前·下一节目 ｜ 回看 / 预约
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 左：台标 / 频道名 / 信号源 / 时间
                  Expanded(
                    flex: 4,
                    child: _ChannelBadge(
                      channel: widget.channel,
                      sourceCount: widget.sourceCount,
                      sourceIndex: widget.sourceIndex,
                      quality: widget.quality,
                      clock: widget.clock,
                    ),
                  ),
                  _BarDivider(hPad: divPad),
                  // 中：当前节目 / 下一节目
                  Expanded(flex: 5, child: _buildPrograms()),
                  _BarDivider(hPad: divPad),
                  // 右：回看 / 预约
                  SizedBox(
                    width: ctaW,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 字数固定但列宽较窄，用自适应再兜一层：
                        // 万一某种字体更宽，宁可把字号收到 11 也不打省略号
                        AutoFitText(
                          '回看 / 预约',
                          maxSize: 14,
                          minSize: 11,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _P.white,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Text(
                              '节目单',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: Color(0xFFB8D6D4),
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 13,
                              color: _P.tealText.withValues(alpha: 0.9),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 横线分隔
              Container(height: 1, color: _P.teal.withValues(alpha: 0.35)),
              const SizedBox(height: 7),
              // 下排：A/B/C/D 四色键提示
              _buildKeyHints(),
            ],
          ),
        ),
      ),
    );
  }

  /// A/B/C/D 四色功能键提示（遥控器）：提示按内容占位，
  /// 剩余宽度平均分给「换源」与「返回主页」，右侧不留空隙、点击区也更大。
  Widget _buildKeyHints() {
    return LayoutBuilder(
      builder: (context, c) {
        // 栏体窄时提示文案收短，把宽度让给右侧两个按钮
        final tight = c.maxWidth < 430;
        final items = [
          (
            letter: 'A',
            color: const Color(0xFFE24D4D),
            text: tight ? '列表' : '列表、回看、预约',
          ),
          (
            letter: 'B',
            color: const Color(0xFF3FB56B),
            text: tight ? '换源' : '换源、收藏、设置',
          ),
          (letter: 'C', color: const Color(0xFFE0B238), text: '换台'),
          (letter: 'D', color: const Color(0xFF3F86D6), text: '时移'),
        ];
        final gap = tight ? 9.0 : 13.0;
        return Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              _keyHint(items[i].letter, items[i].color, items[i].text),
            ],
            const SizedBox(width: 8),
            // 剩余宽度全给这两个按钮，各占一半
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _barButton(
                      icon: Icons.swap_horiz_rounded,
                      label: '换源',
                      enabled: widget.sourceCount > 1,
                      onTap: widget.onCycleSource,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _barButton(
                      icon: Icons.home_rounded,
                      label: '返回主页',
                      onTap: widget.onBackHome,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _keyHint(String letter, Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 13,
          height: 13,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Text(
            letter,
            style: const TextStyle(
              fontSize: 8.5,
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 这里的宽度由外层按内容给足，不能再套 Flexible：
        // 外层 Row 量非弹性子项时是无限宽约束，Flexible 会直接报错
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 84),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9.5, color: _P.dim, height: 1.1),
          ),
        ),
      ],
    );
  }

  /// 底排按钮：撑满分配给它的宽度，宽度不够时自动只留图标
  Widget _barButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final fg = enabled ? const Color(0xFFBFD3D8) : const Color(0xFF6E8288);
    return Focus(
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, bc) {
          // 按钮自己判断宽度：够宽就带文字，太窄只留图标
          final showText = bc.maxWidth >= 66;
          return GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: showText ? 8 : 4,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: const Color(0x332E8B8B),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: _P.teal.withValues(alpha: enabled ? 0.7 : 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 12, color: fg),
                  if (showText) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: fg,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPrograms() {
    final cur = widget.curTitle;
    final next = widget.nextText;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          cur == null ? '当前节目：暂无数据' : '当前节目：$cur',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12.5,
            color: _P.white,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          next == null ? '下一节目：暂无数据' : '下一节目：$next',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: _P.white, height: 1.2),
        ),
      ],
    );
  }
}

/// 三个区块之间的竖线分隔
class _BarDivider extends StatelessWidget {
  final double hPad;
  const _BarDivider({this.hPad = 12});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 40,
      margin: EdgeInsets.symmetric(horizontal: hPad),
      color: _P.teal.withValues(alpha: 0.5),
    );
  }
}

/// 台标 + 频道名 + 信号源状态 + 时间（一体化信息栏左段）
class _ChannelBadge extends StatelessWidget {
  final Channel channel;
  final int sourceCount;
  final int sourceIndex;
  final String? quality;
  final String clock;

  const _ChannelBadge({
    required this.channel,
    required this.sourceCount,
    required this.sourceIndex,
    required this.clock,
    this.quality,
  });

  String get _initials {
    final t = channel.name.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');
    if (t.isEmpty) return 'TV';
    return t.characters.take(2).toString().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // 区块窄时收小台标，把宽度让给文字
        final avail = c.maxWidth.isFinite ? c.maxWidth : 160.0;
        final logoSize = avail < 130 ? 32.0 : (avail < 170 ? 38.0 : 44.0);

        return Row(
          children: [
            Container(
              width: logoSize,
              height: logoSize,
              decoration: BoxDecoration(
                color: const Color(0xFF07161A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _P.teal.withValues(alpha: 0.45)),
              ),
              clipBehavior: Clip.antiAlias,
              child: _logo(),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: _P.white,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    sourceCount == 0
                        ? '无信号源'
                        : '信号源 ${sourceIndex + 1}/$sourceCount'
                              '${quality == null ? "" : " · $quality"}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: Color(0xFF9FC4C6),
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.access_time_rounded,
                        size: 10,
                        color: _P.dim,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        clock,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: _P.dim,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _logo() {
    final fallback = Center(
      child: Text(
        _initials,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: _P.tealText,
          letterSpacing: 1,
        ),
      ),
    );
    final url = channel.logo;
    if (url == null || url.isEmpty) return fallback;
    return Image.network(
      url,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => fallback,
      loadingBuilder: (_, child, p) => p == null ? child : fallback,
    );
  }
}

class _RailItem extends StatefulWidget {
  final String text;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _RailItem({
    super.key,
    required this.text,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || widget.selected;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: _focused ? const Color(0xFF1F2E34) : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: _focused ? _P.tealText : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: AutoFitText(
            widget.text,
            maxSize: 16,
            minSize: 12,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: active ? _P.white : const Color(0xCCFFFFFF),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelRow extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? trailing;
  final int? number;
  final bool selected;
  final VoidCallback onTap;

  /// 已收藏时在频道名后显示黄色五角星
  final bool favorite;

  /// 长按 2 秒触发（频道列表：收藏 / 取消收藏）
  final VoidCallback? onLongPress;

  const _PanelRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.number,
    this.favorite = false,
    this.onLongPress,
  });

  @override
  State<_PanelRow> createState() => _PanelRowState();
}

class _PanelRowState extends State<_PanelRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // 字体倍率由 _buildPanel 统一屏蔽（固定列宽的紧凑布局），
    // 宽度放不下时再交给 AutoFitText 收缩。
    final active = _focused || widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Focus(
        onFocusChange: (v) {
          setState(() => _focused = v);
          if (v) {
            Scrollable.ensureVisible(
              context,
              alignment: 0.45,
              duration: const Duration(milliseconds: 160),
            );
          }
        },
        onKeyEvent: (n, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.select ||
                  e.logicalKey == LogicalKeyboardKey.enter ||
                  e.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(),
                  (r) => r.onTap = widget.onTap,
                ),
            if (widget.onLongPress != null)
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                    // 系统默认长按是 500ms，这里显式要求按住满 2 秒才算
                    () => LongPressGestureRecognizer(
                      duration: const Duration(seconds: 2),
                    ),
                    (r) => r.onLongPress = widget.onLongPress,
                  ),
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _focused
                  ? const Color(0xFF1F3A3E)
                  : (widget.selected
                        ? const Color(0xFF16262B)
                        : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _focused ? _P.tealText : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                if (widget.number != null)
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${widget.number}',
                      style: TextStyle(
                        fontSize: 11,
                        color: active ? _P.tealText : _P.dim,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AutoFitText(
                        widget.title,
                        maxSize: 13.5,
                        minSize: 10.5,
                        // 频道名较长时允许折两行，比直接省略更容易看清
                        maxLines: 2,
                        style: TextStyle(
                          color: active ? _P.white : const Color(0xDDD8E2E6),
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10.5, color: _P.dim),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.favorite)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.star_rounded,
                      size: 15,
                      color: Color(0xFFFFC53D),
                    ),
                  ),
                if (widget.trailing != null)
                  Padding(
                    padding: EdgeInsets.only(left: widget.favorite ? 3 : 0),
                    child: Text(
                      widget.trailing!,
                      style: TextStyle(
                        fontSize: 10,
                        color: widget.selected ? _P.tealText : _P.dim,
                      ),
                    ),
                  ),
                if (widget.selected)
                  const Padding(
                    padding: EdgeInsets.only(left: 5),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 14,
                      color: _P.tealText,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpgRow extends StatefulWidget {
  final EpgProgram program;
  final bool playing;
  final bool reminded;
  final VoidCallback onTap;
  final VoidCallback onCatchup;

  const _EpgRow({
    super.key,
    required this.program,
    required this.playing,
    required this.reminded,
    required this.onTap,
    required this.onCatchup,
  });

  @override
  State<_EpgRow> createState() => _EpgRowState();
}

class _EpgRowState extends State<_EpgRow> {
  bool _focused = false;

  String _t(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Focus(
        onFocusChange: (v) {
          setState(() => _focused = v);
          if (v) {
            Scrollable.ensureVisible(
              context,
              alignment: 0.45,
              duration: const Duration(milliseconds: 160),
            );
          }
        },
        onKeyEvent: (n, e) {
          if (e is KeyDownEvent) {
            if (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter) {
              widget.onTap();
              return KeyEventResult.handled;
            }
            if (e.logicalKey == LogicalKeyboardKey.keyC) {
              widget.onCatchup();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onCatchup,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _focused
                  ? const Color(0xFF1F3A3E)
                  : (widget.playing
                        ? const Color(0xFF16262B)
                        : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _focused ? _P.tealText : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    _t(widget.program.start),
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.playing ? _P.tealText : _P.dim,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    widget.program.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: _focused || widget.playing
                          ? _P.white
                          : const Color(0xDDD8E2E6),
                    ),
                  ),
                ),
                if (widget.reminded)
                  const Icon(
                    Icons.notifications_active_rounded,
                    size: 13,
                    color: _P.tealText,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// B 键快捷菜单：换源 / 收藏 / 画面 / 静音 / 设置
class _QuickMenu extends StatelessWidget {
  final bool favorite;
  final int sourceCount;
  final String fitLabel;
  final VoidCallback onSources;
  final VoidCallback onFavorite;
  final VoidCallback onFit;
  final VoidCallback onMute;
  final VoidCallback onSettings;

  const _QuickMenu({
    required this.favorite,
    required this.sourceCount,
    required this.fitLabel,
    required this.onSources,
    required this.onFavorite,
    required this.onFit,
    required this.onMute,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _P.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2A4A4E)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '快捷功能',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _P.white,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _item(
                    Icons.alt_route_rounded,
                    '换源 ($sourceCount 线)',
                    onSources,
                  ),
                  _item(
                    favorite ? Icons.star_rounded : Icons.star_border_rounded,
                    favorite ? '取消收藏' : '收藏',
                    onFavorite,
                  ),
                  _item(Icons.aspect_ratio_rounded, '画面：$fitLabel', onFit),
                  _item(Icons.volume_up_rounded, '声音', onMute),
                  _item(Icons.settings_rounded, '设置', onSettings),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(IconData icon, String label, VoidCallback onTap) {
    return _MenuButton(icon: icon, label: label, onTap: onTap);
  }
}

class _MenuButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: false,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: _focused ? _P.tealDeep : const Color(0xFF16262B),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused ? _P.tealText : const Color(0xFF2A4A4E),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: _focused ? _P.tealText : _P.dim,
              ),
              const SizedBox(width: 7),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: _focused ? _P.white : const Color(0xDDD8E2E6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 节目单订阅地址输入框
class _EpgConfigDialog extends StatefulWidget {
  final String initial;
  const _EpgConfigDialog({this.initial = ''});

  @override
  State<_EpgConfigDialog> createState() => _EpgConfigDialogState();
}

class _EpgConfigDialogState extends State<_EpgConfigDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop(v.startsWith('http') ? v : 'http://$v');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _P.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2A4A4E)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '载入节目单',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _P.white,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '填写 XMLTV 订阅地址，支持 .xml 与 .xml.gz',
                style: TextStyle(fontSize: 11.5, color: _P.dim),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                style: const TextStyle(fontSize: 13, color: _P.white),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: 'http://example.com/epg.xml.gz',
                  hintStyle: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF6E7F88),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0A1216),
                  isDense: true,
                  prefixIcon: const Icon(
                    Icons.link_rounded,
                    size: 17,
                    color: _P.dim,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF2A4A4E)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF2A4A4E)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: _P.tealText),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(foregroundColor: _P.dim),
                    child: const Text('取消', style: TextStyle(fontSize: 12.5)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: _P.teal,
                      foregroundColor: _P.white,
                    ),
                    child: const Text('载入', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
