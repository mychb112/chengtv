import 'package:chengtv/data/app_state.dart';
import 'package:chengtv/models/channel.dart';
import 'package:flutter_test/flutter_test.dart';

Channel ch(String name, int i) => Channel(
  id: 'c$i',
  name: name,
  group: '央视',
  sources: [ChannelSource(url: 'http://x/$i.m3u8', rawLabel: '', baseScore: 10)],
  index: i,
);

AppState stateWith(List<String> names) {
  final app = AppState();
  app.playlist = Playlist(
    name: 'test',
    channels: [for (var i = 0; i < names.length; i++) ch(names[i], i)],
    groups: const ['央视'],
  );
  return app;
}

void main() {
  group('启动默认频道', () {
    test('优先选 CCTV13，各种写法都能命中', () {
      for (final n in ['CCTV13', 'CCTV-13', 'CCTV-13 新闻', 'CCTV13新闻高清']) {
        final app = stateWith(['CCTV1', n, 'CCTV5']);
        expect(app.defaultChannel()?.name, n, reason: n);
      }
    });

    test('没有 13 套时退到「央视 + 新闻」', () {
      final app = stateWith(['CCTV1', 'CCTV-新闻', '湖南卫视']);
      expect(app.defaultChannel()?.name, 'CCTV-新闻');
    });

    test('再退一步：名字里带新闻的频道', () {
      final app = stateWith(['CCTV1', '新闻综合', '湖南卫视']);
      expect(app.defaultChannel()?.name, '新闻综合');
    });

    test('完全没有新闻类频道时返回 null（停在首页）', () {
      final app = stateWith(['CCTV1', 'CCTV5', '湖南卫视']);
      expect(app.defaultChannel(), isNull);
    });

    test('列表为空时返回 null', () {
      expect(stateWith(const []).defaultChannel(), isNull);
    });
  });
}
