import '../models/channel.dart';
import 'm3u_parser.dart';

/// XMLTV 节目单解析（够用即可，不引入完整 XML 依赖）。
///
/// 只取 `<programme>` 的 start / stop / channel 与 `<title>`，用于播放页的
/// "当前节目 / 下一节目" 与节目单面板。没有节目单时界面显示"暂无数据"。
class EpgParser {
  static final _programmeRe = RegExp(
    r'<programme\b([^>]*)>(.*?)</programme>',
    dotAll: true,
    caseSensitive: false,
  );
  static final _channelRe = RegExp(
    r'<channel\b([^>]*)>(.*?)</channel>',
    dotAll: true,
    caseSensitive: false,
  );
  static final _displayNameRe = RegExp(
    r'<display-name\b[^>]*>(.*?)</display-name>',
    dotAll: true,
    caseSensitive: false,
  );
  static final _attrRe = RegExp(r'(\w+)="([^"]*)"');
  static final _titleRe = RegExp(
    r'<title\b[^>]*>(.*?)</title>',
    dotAll: true,
    caseSensitive: false,
  );
  static final _descRe = RegExp(
    r'<desc\b[^>]*>(.*?)</desc>',
    dotAll: true,
    caseSensitive: false,
  );

  static Map<String, List<EpgProgram>> parse(String xml) {
    // 第一遍：channel id → display-name，很多源（51zmt / epg.pw）的 id 是纯数字，
    // 真正可读的名字只在 display-name 里，必须靠它做别名匹配。
    final idNames = <String, List<String>>{};
    for (final m in _channelRe.allMatches(xml)) {
      final attrs = _attrs(m.group(1)!);
      final id = attrs['id'];
      if (id == null || id.isEmpty) continue;
      final names = _displayNameRe
          .allMatches(m.group(2)!)
          .map((e) => _clean(e.group(1) ?? ''))
          .where((e) => e.isNotEmpty)
          .toList();
      if (names.isNotEmpty) idNames[id.toLowerCase()] = names;
    }

    final map = <String, List<EpgProgram>>{};
    for (final m in _programmeRe.allMatches(xml)) {
      final attrs = _attrs(m.group(1)!);
      final channel = attrs['channel'];
      final start = _parseTime(attrs['start']);
      final stop = _parseTime(attrs['stop']);
      if (channel == null || start == null || stop == null) continue;

      final body = m.group(2)!;
      final title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) continue;
      final desc = _clean(_descRe.firstMatch(body)?.group(1) ?? '');

      map.putIfAbsent(channel.toLowerCase(), () => []).add(
            EpgProgram(start: start, stop: stop, title: title, description: desc),
          );
    }
    for (final list in map.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    // 别名索引：nm:<归一化频道名> → 节目列表，与 M3U 侧的合并键同构
    for (final entry in map.entries.toList()) {
      for (final name in idNames[entry.key] ?? const <String>[]) {
        final alias = 'nm:${M3uParser.normalizeName(name)}';
        map.putIfAbsent(alias, () => entry.value);
      }
    }
    return map;
  }

  static Map<String, String> _attrs(String s) {
    final out = <String, String>{};
    for (final a in _attrRe.allMatches(s)) {
      out[a.group(1)!.toLowerCase()] = a.group(2)!;
    }
    return out;
  }

  /// XMLTV 时间格式：20261018133000 +0800
  static DateTime? _parseTime(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.length < 14) return null;
    final y = int.tryParse(s.substring(0, 4));
    final mo = int.tryParse(s.substring(4, 6));
    final d = int.tryParse(s.substring(6, 8));
    final h = int.tryParse(s.substring(8, 10));
    final mi = int.tryParse(s.substring(10, 12));
    final se = int.tryParse(s.substring(12, 14));
    if (y == null || mo == null || d == null || h == null || mi == null || se == null) {
      return null;
    }
    // XMLTV 时间自带时区偏移：先按 UTC 构造，再减去偏移得到绝对时刻，最后转本地时区
    var t = DateTime.utc(y, mo, d, h, mi, se);
    final tz = RegExp(r'([+-])(\d{2})(\d{2})').firstMatch(s);
    if (tz != null) {
      final sign = tz.group(1) == '-' ? -1 : 1;
      final offMin = sign * (int.parse(tz.group(2)!) * 60 + int.parse(tz.group(3)!));
      t = t.subtract(Duration(minutes: offMin));
    }
    return t.toLocal();
  }

  static String _clean(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// 按 tvg-id / 频道名 / display-name 别名查节目单。
  static List<EpgProgram>? lookup(
    Map<String, List<EpgProgram>> map,
    Channel channel,
  ) {
    // 1) tvg-id 直配
    final id = channel.tvgId;
    if (id != null && id.isNotEmpty) {
      final hit = map[id.toLowerCase()];
      if (hit != null && hit.isNotEmpty) return hit;
    }

    // 2) 合并键直配（nm:xxx / id:xxx）
    final byKey = map[channel.id];
    if (byKey != null && byKey.isNotEmpty) return byKey;

    // 3) display-name 别名（51zmt / epg.pw 这类数字 id 的源主要靠这条）
    final norm = M3uParser.normalizeName(channel.name);
    final alias = map['nm:$norm'];
    if (alias != null && alias.isNotEmpty) return alias;

    // 4) 兜底：逐个键做归一化比较
    for (final e in map.entries) {
      if (_norm(e.key) == norm) return e.value;
    }
    return null;
  }

  /// 去掉 "nm:" / "id:" 前缀后归一化，用于兜底比较
  static String _norm(String s) {
    var k = s.toLowerCase();
    if (k.startsWith('nm:')) k = k.substring(3);
    if (k.startsWith('id:')) k = k.substring(3);
    return M3uParser.normalizeName(k);
  }

  /// 当前节目与下一节目。
  static (EpgProgram?, EpgProgram?) currentAndNext(
    List<EpgProgram>? programs,
    DateTime now,
  ) {
    if (programs == null || programs.isEmpty) return (null, null);
    EpgProgram? current;
    EpgProgram? next;
    for (final p in programs) {
      if (p.contains(now)) {
        current = p;
      } else if (p.start.isAfter(now)) {
        next = p;
        break;
      }
    }
    return (current, next);
  }
}
