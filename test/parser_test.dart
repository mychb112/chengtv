import 'package:chengtv/data/m3u_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同名频道合并为一条，多地址成为多条信号源', () {
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV-1 高清" group-title="央视频道",CCTV-1 高清
http://a.example.com/cctv1_hd.m3u8
#EXTINF:-1 tvg-name="CCTV-1 超清" group-title="央视频道",CCTV-1 超清
https://b.example.com/live/cctv1_1080.m3u8
#EXTINF:-1 tvg-name="CCTV-1" group-title="央视频道",CCTV-1
http://c.example.com/cctv1.ts
#EXTINF:-1 tvg-name="湖南卫视" group-title="卫视频道",湖南卫视
http://d.example.com/hunan.m3u8
''';
    final p = M3uParser.parse(raw);
    expect(p.channels.length, 2, reason: '两条 CCTV-1 变体 + 一条湖南卫视 → 2 个频道');

    final cctv1 = p.channels.firstWhere((c) => c.name.contains('CCTV-1'));
    expect(cctv1.sources.length, 3);
    // 显示名应取不带画质噪声的
    expect(cctv1.name, 'CCTV-1');
    // 超清（https + 1080 + m3u8）应排第一
    expect(cctv1.sources.first.url, contains('cctv1_1080'));
    expect(cctv1.sources.first.qualityLabel, '超清');
  });

  test('tvg-id 相同则跨分组也合并', () {
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv5" tvg-name="CCTV-5 体育" group-title="央视",CCTV-5
http://a.example.com/1.m3u8
#EXTINF:-1 tvg-id="cctv5" tvg-name="CCTV5+" group-title="体育",CCTV5+
http://b.example.com/2.m3u8
''';
    final p = M3uParser.parse(raw);
    expect(p.channels.length, 1);
    expect(p.channels.single.sources.length, 2);
  });

  test('不同频道不会被误合并', () {
    const raw = '''
#EXTM3U
#EXTINF:-1,CCTV-1 综合
http://a.example.com/1.m3u8
#EXTINF:-1,CCTV-2 财经
http://a.example.com/2.m3u8
#EXTINF:-1,湖南卫视
http://a.example.com/3.m3u8
''';
    final p = M3uParser.parse(raw);
    expect(p.channels.length, 3);
  });

  test('重复地址不会重复计入信号源', () {
    const raw = '''
#EXTM3U
#EXTINF:-1,CCTV-1 高清
http://a.example.com/1.m3u8
#EXTINF:-1,CCTV-1 超清
http://a.example.com/1.m3u8
''';
    final p = M3uParser.parse(raw);
    expect(p.channels.single.sources.length, 1);
  });

  test('catchup 属性被解析，可生成回看地址', () {
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV-3" catchup="append" catchup-days="7" catchup-source="http://a.example.com/timeshift?start={start}&end={end}",CCTV-3
http://a.example.com/cctv3.m3u8
''';
    final p = M3uParser.parse(raw);
    final c = p.channels.single;
    expect(c.canCatchup, isTrue);
    final url = c.catchup!.buildUrl(
      'http://a.example.com/cctv3.m3u8',
      DateTime(2026, 10, 18, 13, 30),
      DateTime(2026, 10, 18, 14, 0),
    );
    expect(url, contains('start=20261018133000'));
    expect(url, contains('end=20261018140000'));
  });

  test('列表里的元信息行（更新时间等）不会被当成频道', () {
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-name="更新时间：2026-10-18 13:00",更新时间：2026-10-18 13:00
http://a.example.com/cctv1.m3u8
#EXTINF:-1,2026-10-18
http://a.example.com/cctv1.m3u8
#EXTINF:-1,扫码关注公众号获取更新
http://a.example.com/cctv1.m3u8
#EXTINF:-1 group-title="央视",CCTV-1 高清
http://a.example.com/cctv1.m3u8
''';
    final p = M3uParser.parse(raw);
    expect(p.channels.length, 1, reason: '只剩真正的频道');
    expect(p.channels.single.name, 'CCTV-1 高清');
    expect(M3uParser.isMetaEntry('更新时间：2026-10-18'), isTrue);
    expect(M3uParser.isMetaEntry('CCTV-1 高清'), isFalse);
    expect(M3uParser.isMetaEntry('湖南卫视'), isFalse);
  });
}
