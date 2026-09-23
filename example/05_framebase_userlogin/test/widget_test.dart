import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/main.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:framebase/user/auth_adapter.dart';
import 'package:framebase/user/mock_firebase_auth.dart';
import 'package:framebase/user/user_session_controller.dart';
import 'package:framebase/user/vmodal_credential.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

class FakeGateway extends SearchGateway {
  FakeGateway(super.keys, super.collectionUserId);
  @override
  Future<void> connect(String expectedUserId) async {
    accountId = expectedUserId;
    version = 1;
  }
}

VmodalCredential fixture() => VmodalCredential(
  apiToken: 'test-only-placeholder',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  firebaseUid: 'alice',
  vmodalUserId: 'vmodal-alice',
  collectionUserId: 'alice',
  allowed: true,
  permissions: {'library:read', 'library:write'},
);

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
  testWidgets('empty mock opens signed out without requests', (tester) async {
    final c = ArchiveController(persist: false);
    final auth = MockFirebaseAuth();
    final source = MockVmodalCredentialSource();
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: c,
    );
    expect(session.state, SessionState.loading);
    await tester.pumpWidget(FramebaseApp(controller: c, session: session));
    await tester.pumpAndSettle();
    expect(session.state, SessionState.signedOut);
    expect(source.calls, 0);
    expect(find.byKey(const Key('sign_in')), findsOneWidget);
    expect(find.byType(VideoRow), findsNothing);
    expect(find.byKey(const Key('api_key')), findsNothing);
    session.dispose();
    c.dispose();
  });
  testWidgets('sign in exposes library and sign out clears it', (tester) async {
    final c = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final auth = MockFirebaseAuth(
      accounts: {
        'alice@example.com': const AppUser('alice', email: 'alice@example.com'),
      },
    );
    final source = MockVmodalCredentialSource([fixture()]);
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: c,
      gatewayFactory: (provider, id, fresh) => FakeGateway(provider, id),
    );
    await tester.pumpWidget(FramebaseApp(controller: c, session: session));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'alice@example.com');
    await tester.enterText(find.byKey(const Key('password')), 'password');
    await tester.tap(find.byKey(const Key('sign_in')));
    for (var i = 0; i < 200 && session.state == SessionState.resolving; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(session.state, SessionState.ready);
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
    await tester.tap(find.byKey(const Key('library_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('VMODAL connected'), findsOneWidget);
    final keys = session.gateway!.keys;
    await tester.tap(find.byKey(const Key('sign_out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_in')), findsOneWidget);
    expect(find.byType(VideoRow), findsNothing);
    expect(c.connected, isFalse);
    expect(session.gateway, isNull);
    expect(() => keys.current(), throwsA(isA<AuthException>()));
    session.dispose();
    c.dispose();
  });
  testWidgets('search screen preserves grouped results', (tester) async {
    final c = ArchiveController(persist: false);
    await tester.pumpWidget(MaterialApp(home: SearchPage(archive: c)));
    await tester.pumpAndSettle();
    expect(find.text('Try a search'), findsOneWidget);
    expect(find.byType(MomentTile), findsNothing);
    c.dispose();
  });
  testWidgets('320px layout and secondary history route', (tester) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ArchiveController(persist: false);
    final session = UserSessionController(
      auth: MockFirebaseAuth(),
      credentials: MockVmodalCredentialSource(),
      archive: c,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(controller: c, session: session),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('library_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync history'));
    await tester.pumpAndSettle();
    expect(find.text('No uploads or searches yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    session.dispose();
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
