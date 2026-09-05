// Drives the archive tab at a human pace, for a screen recording. Expects the
// key to be saved already from the traffic run, so this shows it being reused.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sightline/gallery_view.dart';
import 'package:sightline/main.dart';

import 'demo_pace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('media archive, at a human pace', (WidgetTester tester) async {
    await tester.pumpWidget(const SightlineApp());
    await tester.pumpAndSettle();
    await pause(tester, 1200);

    await tapGently(tester, find.text('Archive'));
    await pause(tester, 1500);

    await tapGently(tester, find.byIcon(Icons.info_outline).first);
    await pause(tester, 3200);
    await tapGently(tester, find.text('Got it'));

    // the key is already saved from the traffic tab, so only this tab's
    // collection is needed here
    final Finder setup = find.text('Set the collection').evaluate().isNotEmpty
        ? find.text('Set the collection')
        : find.text('Add your key');
    if (setup.evaluate().isNotEmpty) {
      await tapGently(tester, setup);
      await pause(tester, 1200);
      await typeLikeAPerson(
        tester,
        find.byKey(const Key('setup-collection')),
        'media_archive',
      );
      await pause(tester, 900);
      await tapGently(tester, find.widgetWithText(FilledButton, 'Connect'));
      await waitFor(tester, find.text('Key active'));
      await pause(tester, 3500);
    }

    // read the list of what is in there
    await pause(tester, 2500);

    for (final String query in <String>['a bird', 'an animal', 'clouds']) {
      await typeLikeAPerson(tester, find.byType(TextField).first, query);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pause(tester, 4500);
      await scrollDown(tester, 300);
      await pause(tester, 2500);
      await scrollUp(tester, 300);
      await pause(tester, 800);
    }

    // and by picture instead of words
    final GalleryView view = tester.widget<GalleryView>(
      find.byType(GalleryView),
    );
    await tester.enterText(find.byType(TextField).first, '');
    await pause(tester, 600);
    await view.controller.searchByAsset(
      view.scene,
      'assets/queries/sunset.jpg',
    );
    await pause(tester, 5000);
    await scrollDown(tester, 300);
    await pause(tester, 3000);
  });
}
