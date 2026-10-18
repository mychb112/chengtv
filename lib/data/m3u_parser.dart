import '../models/channel.dart';

/// M3U / M3U8 播放列表解析器。
///
/// 关键行为：**同名频道自动合并为一条，多个地址成为它的多条信号源**。
/// 合并键优先取 `tvg-id`，没有则用归一化后的频道名（去掉画质词、标点、括号注释）。
class M3uParser {
  static final _attrRe = RegExp(r'([\w-]+)="([^"]*)"');

  /// 画质/线路类的噪声词，归一化时剔除，避免同名频道因画质后缀被拆开。
  static const _noiseTokens = [
    '4k', '8k', 'uhd', 'fhd', 'hd', 'sd', '1080p', '1080i', '720p', '576p', '480p',
    '2160p', '超高清', '超清', '高清', '标清', '蓝光', '原画', '流畅', '极速',
    '备用', '备用源', '测试', '线路',
  ];

  static Playlist parse(String raw, {String name = '我的播放列表'}) {
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((e) => e.trim())
        .toList();

    final merged = <String, _ChannelDraft>{};
    final order = <String>[];

    Map<String, String> attrs = {};
    String? extTitle;
    String? extName;
    String? extLogo;
    String? extGroup;
    String? extTvgId;
    String? extCatchupSrc;
    String? extCatchupMode;
    String? extCatchupDays;

    var seq = 0;
    for (final line in lines) {
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        attrs = {};
        final comma = line.indexOf(',');
        final meta = comma > 0 ? line.substring(0, comma) : line;
        for (final m in _attrRe.allMatches(meta)) {
          attrs[m.group(1)!.toLowerCase()] = m.group(2)!.trim();
        }
        extName = _nonEmpty(attrs['tvg-name']);
        extLogo = _nonEmpty(attrs['tvg-logo']);
        extGroup = _nonEmpty(attrs['group-title']);
        extTvgId = _nonEmpty(attrs['tvg-id']);
        extCatchupSrc = _nonEmpty(attrs['catchup-source']);
        extCatchupMode = _nonEmpty(attrs['catchup']);
        extCatchupDays = _nonEmpty(attrs['catchup-days']);
        extTitle = comma > 0 ? _nonEmpty(line.substring(comma + 1)) : null;
        continue;
      }

      if (line.startsWith('#')) continue;

      var url = line;
      String? title = extTitle ?? extName;
      if (!_looksLikeUrl(line)) {
        final comma = line.lastIndexOf(',');
        if (comma > 0 && _looksLikeUrl(line.substring(comma + 1).trim())) {
          title = _nonEmpty(line.substring(0, comma)) ?? title;
          url = line.substring(comma + 1).trim();
        } else {
          continue;
        }
      }
      if (!_looksLikeUrl(url)) continue;

      final displayName = (title ?? '').isEmpty ? _fallbackName(url) : title!;
      final group = extGroup ?? '';

      // 播放列表里常混入 "更新时间：2026-10-18" 这类元信息行，它们不是频道，
      // 不剔除会被当成一个频道显示（点开就是它带的地址，看起来像"进了第一个台"）。
      if (isMetaEntry(displayName)) {
        attrs = {};
        extTitle = null;
        extName = null;
        extLogo = null;
        extGroup = null;
        extTvgId = null;
        extCatchupSrc = null;
        extCatchupMode = null;
        extCatchupDays = null;
        continue;
      }

      final key = (extTvgId != null && extTvgId.isNotEmpty)
          ? 'id:${extTvgId.toLowerCase()}'
          : 'nm:${normalizeName(displayName)}';

      final source = ChannelSource(
        url: url,
        rawLabel: displayName,
        baseScore: scoreSource(displayName, url),
        userAgent: _nonEmpty(attrs['http-user-agent']),
        referer: _nonEmpty(attrs['http-referer']),
      );

      final draft = merged[key];
      if (draft == null) {
        merged[key] = _ChannelDraft(
          key: key,
          name: displayName,
          logo: extLogo,
          group: group,
          tvgId: extTvgId,
          catchupSrc: extCatchupSrc,
          catchupMode: extCatchupMode,
          catchupDays: extCatchupDays,
          index: seq++,
          sources: [source],
        );
        order.add(key);
      } else {
        if (!draft.sources.any((s) => s.url == url)) draft.sources.add(source);
        // 显示名优先取不含画质噪声的那个
        if (_hasNoise(draft.name) && !_hasNoise(displayName)) {
          draft.name = displayName;
        }
        draft.logo ??= extLogo;
        if (draft.group.isEmpty && group.isNotEmpty) draft.group = group;
        draft.catchupSrc ??= extCatchupSrc;
        draft.catchupMode ??= extCatchupMode;
        draft.catchupDays ??= extCatchupDays;
      }

      attrs = {};
      extTitle = null;
      extName = null;
      extLogo = null;
      extGroup = null;
      extTvgId = null;
      extCatchupSrc = null;
      extCatchupMode = null;
      extCatchupDays = null;
    }

    final channels = <Channel>[];
    for (final key in order) {
      final d = merged[key]!;
      final sources = List<ChannelSource>.from(d.sources)
        ..sort((a, b) => b.baseScore.compareTo(a.baseScore));
      channels.add(Channel(
        id: d.key,
        name: d.name,
        logo: d.logo,
        group: d.group,
        tvgId: d.tvgId,
        catchup: (d.catchupSrc == null)
            ? null
            : Catchup(
                source: d.catchupSrc!,
                mode: d.catchupMode ?? 'append',
                days: int.tryParse(d.catchupDays ?? '') ?? 0,
              ),
        sources: sources,
        index: d.index,
      ));
    }

    final groups = <String>[];
    for (final c in channels) {
      final g = c.displayGroup;
      if (!groups.contains(g)) groups.add(g);
    }

    return Playlist(name: name, channels: channels, groups: groups);
  }

  /// 归一化频道名，用于合并同一频道的不同画质/线路版本。
  static String normalizeName(String input) {
    var s = input.toLowerCase();
    s = s.replaceAll(RegExp(r'[\(\[【（].*?[\)\]】）]'), '');
    for (final t in _noiseTokens) {
      s = s.replaceAll(t, '');
    }
    s = s.replaceAll(RegExp(r'[\s\-_·.,、|/\\:：]+'), '');
    return s.isEmpty ? input.toLowerCase() : s;
  }

  /// 信号源质量启发式打分，用于默认选源顺序。
  static int scoreSource(String label, String url) {
    var score = 0;
    final l = label.toLowerCase();
    final u = url.toLowerCase();

    if (l.contains('4k') || l.contains('2160') || u.contains('4k') || u.contains('2160')) {
      score += 45;
    } else if (l.contains('蓝光')) {
      score += 38;
    } else if (l.contains('超清') || l.contains('1080') || l.contains('uhd') || u.contains('1080')) {
      score += 30;
    } else if (l.contains('高清') || l.contains('hd') || u.contains('/hd')) {
      score += 22;
    } else if (l.contains('标清') || l.contains('sd')) {
      score += 0;
    } else {
      score += 10;
    }

    if (u.startsWith('https://')) score += 6;
    if (u.contains('.m3u8')) score += 8;
    if (u.contains('.flv')) score -= 6;
    if (u.endsWith('.ts') || u.contains('.ts?')) score += 3;
    if (u.contains('cdn') || u.contains('ali') || u.contains('tencent') || u.contains('huawei')) score += 3;
    if (l.contains('备用') || l.contains('测试') || u.contains('backup')) score -= 25;

    return score;
  }

  static bool _hasNoise(String name) {
    final l = name.toLowerCase();
    return _noiseTokens.any(l.contains);
  }

  /// 是否是播放列表的元信息行（更新时间、公告、订阅地址等），而非真正的频道。
  static bool isMetaEntry(String name) {
    final s = name.trim();
    if (s.isEmpty) return true;

    // 纯日期 / 纯时间 / 纯数字（"2026-10-18"、"13:30"、"20261018"）
    if (RegExp(r'^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}').hasMatch(s)) return true;
    if (RegExp(r'^(\d{1,2}:\d{2}(:\d{2})?)$').hasMatch(s)) return true;
    if (RegExp(r'^\d{8,14}$').hasMatch(s)) return true;

    const keywords = [
      '更新时间', '更新日期', '最后更新', '更新于', '发布时间',
      '订阅地址', '播放列表地址', '本列表', '列表更新',
      '免责声明', '版权声明', '公告', '通知', '扫码', '二维码',
      '关注公众号', '加群', 'qq群', '微信群', '客服', '说明',
    ];
    final l = s.toLowerCase();
    for (final k in keywords) {
      if (l.contains(k)) return true;
    }
    if (l == 'tips' || l == 'tip' || l == 'update' || l == 'updated') return true;
    return false;
  }

  static String? _nonEmpty(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  static bool _looksLikeUrl(String s) {
    final l = s.toLowerCase();
    return l.startsWith('http://') ||
        l.startsWith('https://') ||
        l.startsWith('rtsp://') ||
        l.startsWith('rtmp://') ||
        l.startsWith('udp://') ||
        l.startsWith('rtp://') ||
        l.startsWith('file://');
  }

  static String _fallbackName(String url) {
    try {
      final u = Uri.parse(url);
      final seg = u.pathSegments.where((e) => e.isNotEmpty).toList();
      if (seg.isNotEmpty) return seg.last.split('.').first;
      return u.host;
    } catch (_) {
      return '未命名频道';
    }
  }
}

class _ChannelDraft {
  final String key;
  String name;
  String? logo;
  String group;
  final String? tvgId;
  String? catchupSrc;
  String? catchupMode;
  String? catchupDays;
  final int index;
  final List<ChannelSource> sources;

  _ChannelDraft({
    required this.key,
    required this.name,
    required this.group,
    required this.index,
    required this.sources,
    this.logo,
    this.tvgId,
    this.catchupSrc,
    this.catchupMode,
    this.catchupDays,
  });
}
