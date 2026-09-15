import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/main.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/data/search_gateway.dart';

void main() {
  testWidgets(
    'search starts with two moments per video and expands on request',
    (tester) async {
      final c = ArchiveController(persist: false);
      c.batch = SearchBatch(
        matches: [
          for (final second in [0, 10, 20, 30, 40])
            FrameMatch(
              row: const {'score': .7},
              filename: 'neighborhood_crossing',
              timestamp: '$second',
              seconds: second.toDouble(),
            ),
        ],
        total: 5,
        serverMs: 10,
        roundTripMs: 20,
        imageMs: 0,
      );
      await tester.pumpWidget(MaterialApp(home: SearchPage(archive: c)));
      await tester.pumpAndSettle();
      expect(find.byType(MomentTile), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('expand_neighborhood_crossing')));
      await tester.pumpAndSettle();
      expect(find.byType(MomentTile), findsNWidgets(5));
      expect(find.textContaining('ms'), findsNothing);
      c.dispose();
    },
  );
  test(
    'invalid runtime key resets connecting and never appears in error',
    () async {
      final c = ArchiveController(persist: false);
      expect(await c.connect('invalid\nkey'), isFalse);
      expect(c.connecting, isFalse);
      expect(c.connected, isFalse);
      expect(c.notice, isNot(contains('invalid\nkey')));
      c.dispose();
    },
  );
  testWidgets('library is content first with no dashboard decoration', (
    tester,
  ) async {
    final c = ArchiveController(persist: false);
    await tester.pumpWidget(FramebaseApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Framebase'), findsOneWidget);
    expect(find.byType(VideoRow), findsWidgets);
    expect(c.clips.length, 3);
    for (final label in [
      'LIVE',
      'COLLECTION / 01',
      'STREET ARCHIVE',
      'Activity',
      'Connected',
      'Distance ≤ 0.85',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byKey(const Key('open_search')));
    await tester.pumpAndSettle();
    expect(find.text('Try a search'), findsOneWidget);
    expect(find.byType(MomentTile), findsNothing);
    await tester.enterText(find.byType(TextField), 'a bus');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('run_search')));
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(find.byKey(const Key('api_key')));
    expect(input.obscureText, isTrue);
    expect(input.enableSuggestions, isFalse);
    c.dispose();
  });
  testWidgets('trip selection narrows the library and carries into search', (
    tester,
  ) async {
    final c = ArchiveController(persist: false);
    await tester.pumpWidget(FramebaseApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_Singapore')));
    await tester.pumpAndSettle();
    expect(find.byType(VideoRow), findsOneWidget);
    expect(find.text('Downtown traffic'), findsOneWidget);
    expect(find.text('Neighborhood crossing'), findsNothing);
    expect(find.text('Search Singapore'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open_search')));
    await tester.pumpAndSettle();
    expect(find.text('Searching in Singapore'), findsOneWidget);
    c.dispose();
  });
  testWidgets('import details require a human title and trip', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ImportDetailsSheet(sourceName: 'old_town-walk.mp4'),
        ),
      ),
    );
    expect(find.widgetWithText(TextField, 'Old Town Walk'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_to_trip')));
    await tester.pump();
    expect(find.text('Enter a place'), findsOneWidget);
  });
  testWidgets('320px layout and secondary history route', (tester) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ArchiveController(persist: false);
    await tester.pumpWidget(FramebaseApp(controller: c));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('library_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync history'));
    await tester.pumpAndSettle();
    expect(find.text('No uploads or searches yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    c.dispose();
  });
  test(
    'nearby moments collapse per video while relevance order is preserved',
    () {
      FrameMatch hit(String name, double time) => FrameMatch(
        row: const {'score': .7},
        filename: name,
        timestamp: '$time',
        seconds: time,
      );
      final grouped = groupMoments([
        hit('one', 35),
        hit('one', 36),
        hit('two', 35),
        hit('one', 22),
        hit('one', 23),
      ]);
      expect(grouped.keys, ['one', 'two']);
      expect(grouped['one']!.map((m) => m.seconds), [35, 22]);
      expect(grouped['two'], hasLength(1));
    },
  );
  test('relative video timestamps and score meaning', () {
    expect(timestamp13({'ts_unix': '0000000035000'}), '0000000035000');
    expect(hitSeconds({'ts_unix': '0000000035000'}), 35);
    expect(hitSeconds({'ts_unix': '1788510000000'}), isNull);
    expect(hitSeconds({'ts_unix': '-5'}), isNull);
    const hit = FrameMatch(
      row: {'score': .92, 'score_ui': 1.0},
      filename: 'test',
      timestamp: '0',
    );
    expect(hit.distance, .92);
    expect(timeLabel(75), '01:15');
    expect(indexDone('success'), isTrue);
    expect(indexFailed('failed'), isTrue);
  });
}
