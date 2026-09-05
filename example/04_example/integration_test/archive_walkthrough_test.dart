// Drives the archive tab and captures a framed screenshot at each step:
//
//   OUT=screenshots/archive KEY_FILE=<secrets> tool/shoot.sh &
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/archive_walkthrough_test.dart -d <device>
//
// The file picker is native iOS, which the driver cannot tap, so this shows the
// bundled clips going up and the bundled pictures being searched with. Picking a
// file from the device is a manual step.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sightline/gallery_view.dart';
import 'package:sightline/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> shot(WidgetTester tester, String name) async {
    final File flag = File(
      '${Directory.systemTemp.parent.path}/Documents/.shot_$name',
    );
    flag.writeAsStringSync('');
    for (int i = 0; i < 240; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!flag.existsSync()) return;
    }
    throw StateError('nobody captured $name; is tool/shoot.sh running?');
  }

  Future<void> wait(WidgetTester tester, int seconds) async {
    for (int i = 0; i < seconds * 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<bool> waitFor(
    WidgetTester tester,
    Finder finder, {
    int timeout = 300,
  }) async {
    for (int i = 0; i < timeout * 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  Future<void> search(WidgetTester tester, String query) async {
    final Finder field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(field, query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('media archive, start to results', (WidgetTester tester) async {
    await tester.pumpWidget(const SightlineApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await shot(tester, '01_start');

    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    await shot(tester, '02_what_it_does');
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect to VModal'));
    await tester.pumpAndSettle();
    await shot(tester, '03_api_key');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await waitFor(tester, find.text('Key active'));
    await wait(tester, 8);
    await shot(tester, '04_uploaded_videos');

    // send the bundled clips if the collection is empty
    if (find.text('Upload and index').evaluate().isNotEmpty) {
      await tester.tap(find.text('Upload and index'));
      await wait(tester, 4);
      await shot(tester, '05_uploading');
      await waitFor(tester, find.textContaining('Indexing'));
      await shot(tester, '06_indexing');
      await waitFor(tester, find.textContaining('VIDEOS UPLOADED'));
      await wait(tester, 3);
      await shot(tester, '07_indexed');
    }

    await search(tester, 'a bird');
    await wait(tester, 8);
    await shot(tester, '08_search_bird');

    await search(tester, 'clouds and sky');
    await wait(tester, 8);
    await shot(tester, '09_search_clouds');

    await search(tester, 'an animal');
    await wait(tester, 8);
    await shot(tester, '10_search_animal');

    // by picture. The picker is native iOS and no driver can tap it, so the
    // search itself is triggered through the controller with the same bundled
    // picture the button would hand over, and the picker is shown last since
    // nothing can dismiss it.
    final GalleryView view = tester.widget<GalleryView>(
      find.byType(GalleryView),
    );
    // The button clears the typed query; do the same so the screenshot does not
    // show a stale one next to picture results.
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump(const Duration(milliseconds: 300));
    await view.controller.searchByAsset(view.scene, 'assets/queries/bird.jpg');
    await wait(tester, 10);
    await shot(tester, '11_image_search_result');

    await view.controller.searchByAsset(
      view.scene,
      'assets/queries/sunset.jpg',
    );
    await wait(tester, 10);
    await shot(tester, '12_image_search_sunset');

    await tester.tap(find.text('Search by image'));
    await wait(tester, 3);
    await shot(tester, '13_picking_an_image');
  });
}
