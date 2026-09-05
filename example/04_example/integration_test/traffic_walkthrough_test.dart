// Drives the traffic tab end to end and captures a screenshot at each step, so
// the delivery set can be regenerated on any device with one command:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/traffic_walkthrough_test.dart -d <device>
//
// Expects the collection to be empty, so the upload and indexing steps are
// visible, and a key already remembered by a previous debug run.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sightline/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Signals the capture script and waits for it to take the shot. Screenshots
  /// come from outside the app so they carry the status bar and a device frame,
  /// which the in-test capture cannot provide.
  /// The key the capture script left for this run. Never in the repo.
  String demoKey() {
    final File file = File(
      '${Directory.systemTemp.parent.path}/Documents/.demo_key',
    );
    return file.existsSync() ? file.readAsStringSync().trim() : '';
  }

  Future<void> shot(WidgetTester tester, String name) async {
    final Directory docs = Directory(
      '${Directory.systemTemp.parent.path}/Documents',
    );
    final File flag = File('${docs.path}/.shot_$name');
    flag.writeAsStringSync('');
    for (int i = 0; i < 240; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!flag.existsSync()) return;
    }
    throw StateError('nobody captured $name; is tool/shoot.sh running?');
  }

  /// Pumps for [seconds] real time, since indexing happens on the server.
  Future<void> wait(WidgetTester tester, int seconds) async {
    for (int i = 0; i < seconds * 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Pumps until [finder] appears, or gives up after [timeout] seconds.
  Future<bool> waitFor(
    WidgetTester tester,
    Finder finder, {
    int timeout = 240,
  }) async {
    for (int i = 0; i < timeout * 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('traffic camera, start to results', (WidgetTester tester) async {
    await tester.pumpWidget(const SightlineApp());
    await tester.pumpAndSettle();

    await shot(tester, '01_start');

    // the explainer panel
    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    await shot(tester, '02_what_it_does');
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    // setup: the key and the collection to work in
    await tester.tap(find.text('Add your key'));
    await tester.pumpAndSettle();
    final List<Finder> fields = <Finder>[
      find.byType(TextField).at(0),
      find.byType(TextField).at(1),
    ];
    await tester.enterText(fields[0], demoKey());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(fields[1], 'traffic_camera');
    await tester.pump(const Duration(milliseconds: 600));
    await shot(tester, '03_setup');

    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await waitFor(tester, find.text('KEY ACTIVE'));
    await shot(tester, '04_connected');

    // upload the bundled clip
    final bool canUpload = await waitFor(
      tester,
      find.text('Upload and index'),
      timeout: 30,
    );
    expect(canUpload, isTrue, reason: 'no upload action appeared');
    await tester.tap(find.text('Upload and index'));
    await wait(tester, 3);
    await shot(tester, '05_uploading');

    await waitFor(tester, find.text('INDEXING'));
    await shot(tester, '06_indexing');

    final bool ready = await waitFor(tester, find.text('SEARCHABLE'));
    expect(ready, isTrue, reason: 'indexing never finished');
    await shot(tester, '07_searchable');

    // a query with obvious hits
    await tester.tap(find.text('pedestrians on a zebra crossing'));
    await waitFor(tester, find.textContaining('MOMENTS'));
    await wait(tester, 4);
    await shot(tester, '08_results_pedestrians');

    // one frame, full size
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    await shot(tester, '09_frame_detail');
    await tester.tapAt(const Offset(20, 60));
    await tester.pumpAndSettle();

    // a second query, to show the counts differ
    await tester.tap(find.text('a bus waiting at the junction'));
    await wait(tester, 6);
    await shot(tester, '10_results_bus');

    // colour and object together, which this clip answers well
    await tester.enterText(find.byType(TextField).first, 'a red car');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await wait(tester, 6);
    await shot(tester, '11_results_red_car');

    // something that is not in the footage
    await tester.enterText(find.byType(TextField).first, 'a giraffe');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await wait(tester, 6);
    await shot(tester, '12_no_match');
  });
}
