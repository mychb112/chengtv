import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import 'epg.dart';
import 'm3u_parser.dart';

/// 预约提醒。
class Reminder {
  final String channelId;
  final String channelName;
  final String title;
  final DateTime start;

  const Reminder({
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.start,
  });

  Map<String, dynamic> toJson() => {
        'channelId': channelId,
        'channelName': channelName,
        'title': title,
        'start': start.toIso8601String(),
      };

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        channelId: j['channelId'] as String,
        channelName: j['channelName'] as String,
        title: j['title'] as String,
        start: DateTime.parse(j['start'] as String),
      );
}

/// 全局应用状态：播放列表、收藏、最近播放、信号源偏好、节目单、预约。
///
/// 说明：本应用不内置任何直播源。所有频道均来自用户自行导入的 M3U 播放列表；
/// 节目单来自用户自行配置的 XMLTV 地址。
class AppState extends ChangeNotifier {
  static const _kPlaylistRaw = 'playlist_raw';
  static const _kPlaylistName = 'playlist_name';
  static const _kFavorites = 'favorites';
  static const _kRecents = 'recents';
  static const _kLastPlayed = 'last_played';
  static const _kPreferredSource = 'preferred_source';
  static const _kSourceHeight = 'source_height';
  static const _kEpgUrl = 'epg_url';
  static const _kEpgRaw = 'epg_raw';
  static const _kReminders = 'reminders';

  Playlist playlist = Playlist.empty;
  Set<String> favorites = {};
  List<String> recents = [];
  String? lastPlayedId;

  /// 频道 → 上次成功播放的源地址（手动切换后会更新，下次优先用它）
  Map<String, String> preferredSource = {};

  /// 源地址 → 实测分辨率高度，用于"质量最好"排序
  Map<String, int> sourceHeight = {};

  String epgUrl = '';
  Map<String, List<EpgProgram>> epg = {};
  List<Reminder> reminders = [];

  /// 从安装包读到的版本号（与 APK 清单一致，避免界面/包体版本不一致）
  String version = '';

  /// 前置摄像头挖孔在四个方向上占用的安全区（dp）。
  /// 来源是原生的 WindowInsets.displayCutout：Android 15 起 targetSdk 35+ 强制边到边，
  /// 界面会画进挖孔区域，而沉浸模式下 MediaQuery.padding 常常报 0，必须自己避让。
  double cutoutLeft = 0;
  double cutoutRight = 0;
  double cutoutBottom = 0;

  /// 是否手机（最小边 < 600dp）。电视/平板有足够边框，不需要额外留白。
  bool isPhone = true;

  /// 重新读取挖孔安全区。进播放页和屏幕旋转后都要调一次，横竖屏的挖孔方向不一样。
  Future<void> refreshDisplayInfo() async {
    try {
      final r = await const MethodChannel('chengtv/keys')
          .invokeMapMethod<String, dynamic>('getDisplayInfo');
      if (r == null) return;
      double num_(String k) => (r[k] as num?)?.toDouble() ?? 0;
      final smallest = (r['smallestWidthDp'] as num?)?.toInt() ?? 0;
      final l = num_('cutoutLeft');
      final rt = num_('cutoutRight');
      final b = num_('cutoutBottom');
      final phone = smallest > 0 ? smallest < 600 : true;
      if (l == cutoutLeft &&
          rt == cutoutRight &&
          b == cutoutBottom &&
          phone == isPhone) {
        return;
      }
      cutoutLeft = l;
      cutoutRight = rt;
      cutoutBottom = b;
      isPhone = phone;
      notifyListeners();
    } catch (_) {
      // 老系统没有挖孔概念，保持 0 即可
    }
  }

  bool busy = false;
  String? lastError;

  SharedPreferences? _prefs;

  List<Channel> get channels => playlist.channels;
  List<String> get groups => playlist.groups;
  bool get hasContent => channels.isNotEmpty;
  bool get hasEpg => epg.isNotEmpty;

  /// 启动时默认打开的频道：CCTV-13 新闻。
  /// 播放列表里写法五花八门（CCTV13 / CCTV-13 / 央视新闻 / 新闻频道），
  /// 所以按归一化后的名字做三级匹配，一级比一级松。
  Channel? defaultChannel() {
    if (channels.isEmpty) return null;
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_·•.、（）()\[\]【】]'), '')
        .replaceAll('高清', '')
        .replaceAll('超清', '');

    // 1) 明确写着 CCTV13 的
    for (final c in channels) {
      if (norm(c.name).contains('cctv13')) return c;
    }
    // 2) “央视/中央/CCTV + 新闻”这一类（CCTV-新闻 与 13 套是同一个）
    for (final c in channels) {
      final n = norm(c.name);
      final isCctv =
          n.contains('cctv') || n.contains('央视') || n.contains('中央');
      if (isCctv && n.contains('新闻')) return c;
    }
    // 3) 名字里带“新闻”的任何频道
    for (final c in channels) {
      if (norm(c.name).contains('新闻')) return c;
    }
    return null;
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    try {
      version = await const MethodChannel('chengtv/keys').invokeMethod<String>('getVersion') ?? '';
    } catch (_) {
      version = '';
    }
    favorites = (p.getStringList(_kFavorites) ?? []).toSet();
    recents = p.getStringList(_kRecents) ?? [];
    lastPlayedId = p.getString(_kLastPlayed);
    epgUrl = p.getString(_kEpgUrl) ?? '';

    final prefRaw = p.getString(_kPreferredSource);
    if (prefRaw != null && prefRaw.isNotEmpty) {
      try {
        preferredSource = (jsonDecode(prefRaw) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }
    final heightRaw = p.getString(_kSourceHeight);
    if (heightRaw != null && heightRaw.isNotEmpty) {
      try {
        sourceHeight = (jsonDecode(heightRaw) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, (v as num).toInt()));
      } catch (_) {}
    }
    final remRaw = p.getString(_kReminders);
    if (remRaw != null && remRaw.isNotEmpty) {
      try {
        reminders = (jsonDecode(remRaw) as List)
            .map((e) => Reminder.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    final raw = p.getString(_kPlaylistRaw);
    if (raw != null && raw.trim().isNotEmpty) {
      playlist = M3uParser.parse(raw, name: p.getString(_kPlaylistName) ?? '我的播放列表');
    }

    final epgRaw = p.getString(_kEpgRaw);
    if (epgRaw != null && epgRaw.isNotEmpty) {
      epg = EpgParser.parse(epgRaw);
    }
    notifyListeners();
  }

  // ---------- 播放列表 ----------

  Future<void> importFromUrl(String url) async {
    await _guard(() async {
      final uri = Uri.parse(url.trim());
      final resp = await http
          .get(uri, headers: {'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20'})
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) throw Exception('服务器返回 ${resp.statusCode}');
      await _applyImport(_decode(resp.bodyBytes), name: uri.host);
    });
  }

  Future<void> importFromText(String text, {String name = '我的播放列表'}) async {
    await _guard(() => _applyImport(text, name: name));
  }

  Future<void> _applyImport(String text, {required String name}) async {
    final parsed = M3uParser.parse(text, name: name);
    if (parsed.channels.isEmpty) {
      throw Exception('没有解析到任何频道，请检查文件格式是否为 M3U/M3U8');
    }
    playlist = parsed;
    final p = _prefs!;
    await p.setString(_kPlaylistRaw, text);
    await p.setString(_kPlaylistName, name);
    final ids = parsed.channels.map((e) => e.id).toSet();
    favorites = favorites.where(ids.contains).toSet();
    await p.setStringList(_kFavorites, favorites.toList());
    notifyListeners();
  }

  Future<void> clearPlaylist() async {
    playlist = Playlist.empty;
    favorites = {};
    recents = [];
    lastPlayedId = null;
    preferredSource = {};
    sourceHeight = {};
    final p = _prefs!;
    await p.remove(_kPlaylistRaw);
    await p.remove(_kPlaylistName);
    await p.remove(_kFavorites);
    await p.remove(_kRecents);
    await p.remove(_kLastPlayed);
    await p.remove(_kPreferredSource);
    await p.remove(_kSourceHeight);
    notifyListeners();
  }

  // ---------- 收藏 / 历史 ----------

  bool isFavorite(Channel c) => favorites.contains(c.id);

  Future<void> toggleFavorite(Channel c) async {
    if (favorites.contains(c.id)) {
      favorites.remove(c.id);
    } else {
      favorites.add(c.id);
    }
    await _prefs?.setStringList(_kFavorites, favorites.toList());
    notifyListeners();
  }

  Future<void> markPlayed(Channel c) async {
    lastPlayedId = c.id;
    recents.remove(c.id);
    recents.insert(0, c.id);
    if (recents.length > 30) recents = recents.sublist(0, 30);
    final p = _prefs;
    if (p != null) {
      await p.setString(_kLastPlayed, c.id);
      await p.setStringList(_kRecents, recents);
    }
    notifyListeners();
  }

  Channel? channelById(String? id) {
    if (id == null) return null;
    for (final c in channels) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<Channel> get recentChannels =>
      recents.map(channelById).whereType<Channel>().toList();

  List<Channel> get favoriteChannels =>
      channels.where((c) => favorites.contains(c.id)).toList();

  // ---------- 信号源 ----------

  /// 按"质量最好"排出该频道的信号源顺序：
  /// 1) 上次手动选择/成功播放的源；2) 实测分辨率高的；3) 启发式评分高的。
  List<ChannelSource> orderedSources(Channel c) {
    final list = List<ChannelSource>.from(c.sources);
    list.sort((a, b) {
      final sa = _sourceRank(c.id, a);
      final sb = _sourceRank(c.id, b);
      return sb.compareTo(sa);
    });
    return list;
  }

  int _sourceRank(String channelId, ChannelSource s) {
    var rank = s.baseScore;
    final pref = preferredSource[channelId];
    if (pref != null && pref == s.url) rank += 1000;
    final h = sourceHeight[s.url];
    if (h != null) rank += h ~/ 10; // 1080 → +108，2160 → +216
    return rank;
  }

  Future<void> rememberSource(String channelId, ChannelSource source) async {
    preferredSource[channelId] = source.url;
    await _prefs?.setString(_kPreferredSource, jsonEncode(preferredSource));
    notifyListeners();
  }

  Future<void> recordResolution(String url, int height) async {
    if (height <= 0) return;
    final old = sourceHeight[url] ?? 0;
    if (height <= old) return;
    sourceHeight[url] = height;
    await _prefs?.setString(_kSourceHeight, jsonEncode(sourceHeight));
  }

  // ---------- 节目单 ----------

  Future<void> loadEpg(String url) async {
    await _guard(() async {
      final uri = Uri.parse(url.trim());
      final resp = await http.get(uri).timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) throw Exception('服务器返回 ${resp.statusCode}');
      final text = _decodeMaybeGzip(resp.bodyBytes);
      await _applyEpg(text, uri.toString());
    });
  }

  /// 从本地文件或粘贴内容导入节目单。
  Future<void> importEpgText(String text, {String source = '本地文件'}) async {
    await _guard(() => _applyEpg(text, source));
  }

  /// 直接吃字节流：自动识别 gzip 与编码。
  Future<void> importEpgBytes(List<int> bytes, {String source = '本地文件'}) async {
    await _guard(() => _applyEpg(_decodeMaybeGzip(bytes), source));
  }

  Future<void> _applyEpg(String text, String source) async {
    final parsed = EpgParser.parse(text);
    if (parsed.isEmpty) {
      throw Exception('没有解析到节目单数据，确认是 XMLTV 格式（可为 .xml 或 .xml.gz）');
    }
    epg = parsed;
    epgUrl = source;
    await _prefs?.setString(_kEpgRaw, text);
    await _prefs?.setString(_kEpgUrl, epgUrl);
    notifyListeners();
  }

  /// XMLTV 常见 .gz 压缩，先按 gzip 魔数判断再解压。
  String _decodeMaybeGzip(List<int> bytes) {
    if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      try {
        final out = GZipCodec().decode(bytes);
        return utf8.decode(out, allowMalformed: true);
      } catch (_) {
        // 解压失败则按原文处理
      }
    }
    return _decode(bytes);
  }

  List<EpgProgram>? programsFor(Channel c) => EpgParser.lookup(epg, c);

  Future<void> clearEpg() async {
    epg = {};
    epgUrl = '';
    await _prefs?.remove(_kEpgRaw);
    await _prefs?.remove(_kEpgUrl);
    notifyListeners();
  }

  // ---------- 预约 ----------

  bool hasReminder(Channel c, EpgProgram p) => reminders.any(
      (r) => r.channelId == c.id && r.start == p.start && r.title == p.title);

  Future<void> toggleReminder(Channel c, EpgProgram p) async {
    if (hasReminder(c, p)) {
      await removeReminder(c, p);
    } else {
      await addReminder(c, p);
    }
  }

  Future<void> addReminder(Channel c, EpgProgram p) async {
    if (hasReminder(c, p)) return;
    reminders.add(Reminder(
      channelId: c.id,
      channelName: c.name,
      title: p.title,
      start: p.start,
    ));
    await _prefs?.setString(
      _kReminders,
      jsonEncode(reminders.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> removeReminder(Channel c, EpgProgram p) async {
    reminders.removeWhere((r) => r.channelId == c.id && r.start == p.start);
    await _prefs?.setString(
      _kReminders,
      jsonEncode(reminders.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  // ---------- 内部 ----------

  Future<void> _guard(Future<void> Function() fn) async {
    busy = true;
    lastError = null;
    notifyListeners();
    try {
      await fn();
    } catch (e) {
      lastError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }
}
