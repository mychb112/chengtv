import 'package:chengtv/data/epg.dart';
import 'package:chengtv/data/m3u_parser.dart';
import 'package:chengtv/models/channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="cctv1"><display-name>CCTV-1</display-name></channel>
  <programme start="20261018120000 +0800" stop="20261018133000 +0800" channel="cctv1">
    <title>新闻30分</title>
  </programme>
  <programme start="20261018133000 +0800" stop="20261018150000 +0800" channel="cctv1">
    <title>今日说法</title>
    <desc>法制节目</desc>
  </programme>
  <programme start="20261018150000 +0800" stop="20261018163000 +0800" channel="cctv1">
    <title>第一动画乐园</title>
  </programme>
</tv>''';

  test('XMLTV 能被解析并按时间排序', () {
    final map = EpgParser.parse(xml);
    expect(map.containsKey('cctv1'), isTrue);
    final list = map['cctv1']!;
    expect(list.length, 3);
    expect(list.first.title, '新闻30分');
    // 12:00 +0800 == 04:00 UTC
    expect(list.first.start.toUtc().hour, 4);
    expect(list[1].description, '法制节目');
  });

  test('当前节目与下一节目定位正确', () {
    final map = EpgParser.parse(xml);
    final list = map['cctv1']!;
    // 14:00 +0800 == 06:00 UTC，此时正在播「今日说法」
    final now = DateTime.utc(2026, 10, 18, 6, 0).toLocal();
    final (cur, next) = EpgParser.currentAndNext(list, now);
    expect(cur?.title, '今日说法');
    expect(next?.title, '第一动画乐园');
  });

  test('按 tvg-id 关联到频道', () {
    final map = EpgParser.parse(xml);
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV-1 综合",CCTV-1 综合
http://a.example.com/1.m3u8
''';
    final ch = M3uParser.parse(raw).channels.single;
    final hit = EpgParser.lookup(map, ch);
    expect(hit, isNotNull);
    expect(hit!.length, 3);
  });

  test('按频道名兜底关联', () {
    final map = EpgParser.parse(xml);
    const ch = Channel(
      id: 'nm:cctv1',
      name: 'CCTV-1',
      group: '央视',
      sources: [],
      index: 0,
    );
    final hit = EpgParser.lookup(map, ch);
    expect(hit, isNotNull);
  });

  test('没有节目单时返回空', () {
    expect(EpgParser.parse('<tv></tv>').isEmpty, isTrue);
    final (cur, next) = EpgParser.currentAndNext(null, DateTime.now());
    expect(cur, isNull);
    expect(next, isNull);
  });

  test('数字 channel id + display-name 的源（51zmt / epg.pw 形态）也能匹配', () {
    // 51zmt 实际结构：channel id 是 "1"，可读名字只在 display-name
    const numericXml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="1"><display-name>CCTV1</display-name></channel>
  <channel id="2"><display-name>湖南卫视</display-name></channel>
  <programme start="20261018200000 +0800" stop="20261018220000 +0800" channel="1">
    <title>晚间新闻</title>
  </programme>
</tv>''';
    final map = EpgParser.parse(numericXml);

    // M3U 里常见写法：没有 tvg-id，名称带画质后缀
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV-1 高清" group-title="央视",CCTV-1 高清
http://a.example.com/1.m3u8
''';
    final ch = M3uParser.parse(raw).channels.single;
    expect(ch.id, 'nm:cctv1');
    final hit = EpgParser.lookup(map, ch);
    expect(hit, isNotNull, reason: '应通过 display-name 别名匹配到数字 id');
    expect(hit!.first.title, '晚间新闻');
  });

  test('tvg-id 与 display-name 同时存在时优先 tvg-id', () {
    const mixed = '''<tv>
  <channel id="cctv1"><display-name>CCTV1</display-name></channel>
  <channel id="1"><display-name>CCTV1</display-name></channel>
  <programme start="20261018200000 +0800" stop="20261018220000 +0800" channel="cctv1"><title>正确节目</title></programme>
  <programme start="20261018200000 +0800" stop="20261018220000 +0800" channel="1"><title>错误节目</title></programme>
</tv>''';
    final map = EpgParser.parse(mixed);
    const ch = Channel(
      id: 'id:cctv1',
      name: 'CCTV1',
      group: '央视',
      sources: [],
      index: 0,
      tvgId: 'cctv1',
    );
    final hit = EpgParser.lookup(map, ch);
    expect(hit!.first.title, '正确节目');
  });
}
