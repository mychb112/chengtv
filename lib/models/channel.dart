/// 一个频道下的单条信号源（线路）。
class ChannelSource {
  final String url;
  final String rawLabel;
  final int baseScore;
  final String? userAgent;
  final String? referer;

  const ChannelSource({
    required this.url,
    required this.rawLabel,
    required this.baseScore,
    this.userAgent,
    this.referer,
  });

  /// 画质标签：优先用源名称里的描述，否则从 URL 推断。
  String get qualityLabel {
    final l = rawLabel.toLowerCase();
    if (l.contains('4k') || l.contains('2160')) return '4K';
    if (l.contains('蓝光') || l.contains('bluray')) return '蓝光';
    if (l.contains('超清') || l.contains('1080') || l.contains('uhd')) return '超清';
    if (l.contains('高清') || l.contains('hd')) return '高清';
    if (l.contains('标清') || l.contains('sd ')) return '标清';
    final u = url.toLowerCase();
    if (u.contains('4k') || u.contains('2160')) return '4K';
    if (u.contains('1080')) return '超清';
    if (u.contains('/hd') || u.contains('hd.')) return '高清';
    return '标准';
  }

  String get hostLabel {
    try {
      final h = Uri.parse(url).host;
      return h.isEmpty ? url : h;
    } catch (_) {
      return url;
    }
  }
}

/// 回看能力（M3U 的 catchup-* 属性）。
class Catchup {
  final String source;
  final String mode;
  final int days;

  const Catchup({required this.source, required this.mode, required this.days});

  static Catchup? fromAttrs(Map<String, String> attrs) {
    final src = attrs['catchup-source'];
    final mode = attrs['catchup'] ?? '';
    if (src == null || src.isEmpty) return null;
    if (mode.isEmpty || mode == 'none') return null;
    final days = int.tryParse(attrs['catchup-days'] ?? '') ?? 0;
    return Catchup(source: src, mode: mode, days: days);
  }

  /// 生成某时间点的回看地址。支持 {start}/{end} 与 ${start}/${end} 占位，
  /// 时间格式 yyyyMMddHHmmss；{utc}/{utcend} 为 epoch 秒；{channel} 为原频道地址。
  String buildUrl(String baseUrl, DateTime start, DateTime end) {
    final fmt = _fmt(start);
    final fmtEnd = _fmt(end);
    var r = source;
    r = r.replaceAll(r'${start}', fmt).replaceAll(r'${end}', fmtEnd);
    r = r.replaceAll('{start}', fmt).replaceAll('{end}', fmtEnd);
    r = r.replaceAll('{utc}', '${start.toUtc().millisecondsSinceEpoch ~/ 1000}');
    r = r.replaceAll('{utcend}', '${end.toUtc().millisecondsSinceEpoch ~/ 1000}');
    r = r.replaceAll(r'${channel}', baseUrl).replaceAll('{channel}', baseUrl);
    return r;
  }

  static String _fmt(DateTime t) {
    String p(int v, [int n = 2]) => v.toString().padLeft(n, '0');
    return '${p(t.year, 4)}${p(t.month)}${p(t.day)}${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }
}

class Channel {
  final String id;
  final String name;
  final String? logo;
  final String group;
  final String? tvgId;
  final List<ChannelSource> sources;
  final Catchup? catchup;
  final int index;

  const Channel({
    required this.id,
    required this.name,
    required this.group,
    required this.sources,
    required this.index,
    this.logo,
    this.tvgId,
    this.catchup,
  });

  String get displayGroup => group.isEmpty ? '未分类' : group;
  int get sourceCount => sources.length;
  bool get canCatchup => catchup != null;
}

class Playlist {
  final String name;
  final List<Channel> channels;
  final List<String> groups;

  const Playlist({required this.name, required this.channels, required this.groups});

  static const empty = Playlist(name: '', channels: [], groups: []);
}

/// XMLTV 节目单条目。
class EpgProgram {
  final DateTime start;
  final DateTime stop;
  final String title;
  final String description;

  const EpgProgram({
    required this.start,
    required this.stop,
    required this.title,
    this.description = '',
  });

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(stop);
}
