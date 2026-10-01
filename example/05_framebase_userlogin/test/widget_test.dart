import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/main.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:framebase/user/auth_adapter.dart';
import 'package:framebase/user/login_page.dart';
import 'package:framebase/user/mock_firebase_auth.dart';
import 'package:framebase/user/user_session_controller.dart';
import 'package:framebase/user/vmodal_credential.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import 'session_fixture.dart';

class FakeGateway extends SearchGateway {
  FakeGateway(super.session, super.scopeId);
  @override
  Future<void> connect(String expectedUserId) async {
    version = 1;
  }

  @override
  Future<DeleteCollectionResponse> previewLibraryDeletion(
    CancellationToken cancellation,
  ) async => DeleteCollectionResponse({
    'status': 'dry_run',
    'group_name': collection,
    'mode': 'vid_file',
    'scope': 'all',
    'removed_bytes': 20,
    'sql_rows_deleted': 2,
  });

  @override
  Future<DeleteCollectionResponse> deleteLibrary(
    CancellationToken cancellation,
  ) async => DeleteCollectionResponse({
    'status': 'ok',
    'group_name': collection,
    'mode': 'vid_file',
    'scope': 'all',
  });
}

class LifecycleArchive extends ArchiveController {
  LifecycleArchive() : super(persist: false);
  int stopCalls = 0;
  int invalidateCalls = 0;

  @override
  void stopWork() {
    stopCalls++;
    super.stopWork();
  }

  @override
  void invalidateSearch() {
    invalidateCalls++;
    super.invalidateSearch();
  }
}

VmodalCredential fixture([String uid = 'alice']) => VmodalCredential(
  contractVersion: 1,
  sessionId: 'widget-session',
  issuedAt: DateTime.now().toUtc(),
  apiToken: 'test-only-placeholder',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  firebaseUid: uid,
  vmodalUserId: 'vmodal-alice',
  scopeId: 'scope_7K3A',
  allowed: true,
  permissions: {'library:read', 'library:write'},
);

class DelayedFileArchive extends ArchiveController {
  DelayedFileArchive()
    : super(persist: false, supportDirectory: Directory.systemTemp);
  final file = Completer<File>();
  @override
  Future<File> localFile(ArchiveClip clip) => file.future;
}

FrameMatch frameMatch({
  required String name,
  required int offsetMs,
  double distance = .7,
  String? assetId,
}) {
  final raw = <String, Object?>{
    'file_name': name,
    'playback_offset_ms': offsetMs,
    'distance': distance,
  };
  if (assetId != null) raw['asset_id'] = assetId;
  return FrameMatch(hit: VideoSearchHit(raw));
}

void main() {
  testWidgets(
    'collapsed A B A resets navigation and evicts private memory images',
    (tester) async {
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final auth = MockFirebaseAuth();
      final session = (await tester.runAsync(
        () async => UserSessionController(
          auth: auth,
          credentials: MockVmodalCredentialSource([
            fixture('alice'),
            fixture('bob'),
            fixture('alice'),
          ]),
          archive: archive,
          transportFactory: (_) => QueueTransport(),
          gatewayFactory: (session, scope, fresh) =>
              FakeGateway(session, scope),
        ),
      ))!;
      await tester.pumpWidget(
        FramebaseApp(controller: archive, session: session),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        auth.setUser(const AppUser('alice'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(session.state, SessionState.ready);
      final aSessionId = session.gateway!.session.sessionId;
      final originalNavigator = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      unawaited(
        originalNavigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Private A navigation')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private A navigation'), findsOneWidget);

      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(Colors.blue, ui.BlendMode.src);
      final pixel = (await tester.runAsync(
        () => recorder.endRecording().toImage(1, 1),
      ))!;
      final png = (await tester.runAsync(
        () => pixel.toByteData(format: ui.ImageByteFormat.png),
      ))!;
      final image = MemoryImage(png.buffer.asUint8List());
      pixel.dispose();
      final imageContext = tester.element(find.text('Private A navigation'));
      await tester.runAsync(() => precacheImage(image, imageContext));
      await tester.pump();
      final cache = PaintingBinding.instance.imageCache;
      expect(cache.containsKey(image), isTrue);

      // Resolve both transitions without rendering an intermediate B frame.
      await tester.runAsync(() async {
        auth.setUser(const AppUser('bob'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(session.state, SessionState.ready);
        expect(cache.containsKey(image), isFalse);
        auth.setUser(const AppUser('alice'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(session.state, SessionState.ready);
      expect(session.user!.uid, 'alice');
      expect(session.gateway!.session.sessionId, isNot(aSessionId));
      await tester.pumpAndSettle();
      expect(find.text('Private A navigation'), findsNothing);
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)),
        isNot(same(originalNavigator)),
      );
      expect(cache.containsKey(image), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      archive.dispose();
    },
  );

  testWidgets(
    'archive invalidation hides a recording while its file load is still pending',
    (tester) async {
      final archive = DelayedFileArchive();
      final gateway = SearchGateway(await testSession(), 'scope_7K3A');
      await tester.runAsync(
        () => archive.activate(
          'scope_7K3A',
          gateway,
          canRead: true,
          canWrite: true,
          serviceNamespace: gateway.context.serviceNamespace,
          tenantId: gateway.context.tenantId,
          appUserId: gateway.context.appUserId,
          policyRevision: gateway.context.policyRevision,
        ),
      );
      final clip = archive.clips.first;
      await tester.pumpWidget(
        MaterialApp(
          home: RecordingSheet(archive: archive, clip: clip),
        ),
      );
      await tester.pump();
      expect(find.text(clip.title), findsOneWidget);
      archive.deactivate();
      await tester.pump();
      expect(find.text(clip.title), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      archive.file.complete(
        File('${Directory.systemTemp.path}/stale-never-open.mp4'),
      );
      await tester.pumpAndSettle();
      expect(find.text(clip.title), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      archive.dispose();
      await gateway.close();
    },
  );
  testWidgets(
    'search starts with two moments per video and expands on request',
    (tester) async {
      final c = ArchiveController(persist: false);
      c.batch = SearchBatch(
        matches: [
          for (final second in [0, 10, 20, 30, 40])
            frameMatch(name: 'neighborhood_crossing', offsetMs: second * 1000),
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
  testWidgets('lifecycle exit cancels work without replay on resume', (
    tester,
  ) async {
    final c = LifecycleArchive();
    final session = UserSessionController(
      auth: MockFirebaseAuth(),
      credentials: MockVmodalCredentialSource(),
      archive: c,
    );
    await tester.pumpWidget(FramebaseApp(controller: c, session: session));
    await tester.pumpAndSettle();
    final stopped = c.stopCalls;
    final invalidated = c.invalidateCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(c.stopCalls, stopped);
    expect(c.invalidateCalls, invalidated);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(c.stopCalls, stopped + 1);
    expect(c.invalidateCalls, invalidated + 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(c.stopCalls, stopped + 2);
    expect(c.invalidateCalls, invalidated + 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(c.stopCalls, stopped + 3);
    expect(c.invalidateCalls, invalidated + 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(c.stopCalls, stopped + 3);
    expect(c.invalidateCalls, invalidated + 3);
    expect(c.busy, isFalse);
    expect(c.searching, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
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
    final session = (await tester.runAsync(
      () async => UserSessionController(
        auth: auth,
        credentials: source,
        archive: c,
        transportFactory: (_) => QueueTransport(),
        gatewayFactory: (session, id, fresh) => FakeGateway(session, id),
      ),
    ))!;
    await tester.pumpWidget(FramebaseApp(controller: c, session: session));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'alice@example.com');
    await tester.enterText(find.byKey(const Key('password')), 'password');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sign_in')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 200 && session.state == SessionState.resolving; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(session.state, SessionState.ready);
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
    final sdkSession = session.gateway!.session;
    await tester.tap(find.byKey(const Key('sign_out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_in')), findsOneWidget);
    expect(find.byType(VideoRow), findsNothing);
    expect(c.connected, isFalse);
    expect(session.gateway, isNull);
    expect(sdkSession.isActive, isFalse);
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
  testWidgets('recoverable session shows safe retry and sign-out actions', (
    tester,
  ) async {
    final c = ArchiveController(persist: false);
    final session = UserSessionController(
      auth: MockFirebaseAuth(),
      credentials: MockVmodalCredentialSource(),
      archive: c,
    );
    await tester.pump();
    session.state = SessionState.recoverable;
    session.failureKind = SessionFailureKind.transient;
    session.message =
        'Connection interrupted. Retry to reconnect your library.';

    await tester.pumpWidget(MaterialApp(home: LoginPage(session: session)));

    expect(find.text(session.message), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.textContaining('CredentialTransient'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    c.dispose();
  });
  testWidgets(
    'identity expiry signs in again and tenant 401 offers connection retry',
    (tester) async {
      for (final kind in [
        SessionFailureKind.firebaseIdentityExpired,
        SessionFailureKind.vmodalUnauthorized,
      ]) {
        final c = ArchiveController(persist: false);
        final session = UserSessionController(
          auth: MockFirebaseAuth(initial: const AppUser('alice')),
          credentials: MockVmodalCredentialSource(),
          archive: c,
        );
        await tester.pump();
        final expiredIdentity =
            kind == SessionFailureKind.firebaseIdentityExpired;
        session.state = expiredIdentity
            ? SessionState.error
            : SessionState.recoverable;
        session.failureKind = kind;
        session.message = kind == SessionFailureKind.firebaseIdentityExpired
            ? 'Your sign-in expired. Sign in again.'
            : 'The tenant connection needs recovery. Retry to reconnect your library.';

        await tester.pumpWidget(MaterialApp(home: LoginPage(session: session)));

        expect(find.text(session.message), findsOneWidget);
        expect(
          find.text('Sign in again'),
          expiredIdentity ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('Retry'),
          expiredIdentity ? findsNothing : findsOneWidget,
        );
        if (!expiredIdentity) expect(session.user!.uid, 'alice');
        await tester.tap(
          find.text(expiredIdentity ? 'Sign in again' : 'Sign out'),
        );
        await tester.pumpAndSettle();
        expect(session.state, SessionState.signedOut);
        expect(find.byKey(const Key('sign_in')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
        c.dispose();
      }
    },
  );
  testWidgets('denial, VMODAL 403, and contract failures cannot retry', (
    tester,
  ) async {
    for (final kind in [
      SessionFailureKind.credentialDenied,
      SessionFailureKind.vmodalForbidden,
      SessionFailureKind.contract,
    ]) {
      final c = ArchiveController(persist: false);
      final session = UserSessionController(
        auth: MockFirebaseAuth(),
        credentials: MockVmodalCredentialSource(),
        archive: c,
      );
      await tester.pump();
      session.state = kind == SessionFailureKind.contract
          ? SessionState.error
          : SessionState.denied;
      session.failureKind = kind;
      session.message = kind == SessionFailureKind.contract
          ? 'The library connection is not configured correctly.'
          : 'Access to this library is unavailable.';

      await tester.pumpWidget(MaterialApp(home: LoginPage(session: session)));

      expect(find.text(session.message), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.textContaining('raw issuer detail'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      c.dispose();
    }
  });
  test(
    'nearby moments collapse per video while relevance order is preserved',
    () {
      final grouped = groupMoments([
        frameMatch(name: 'one-a.mp4', offsetMs: 35000, assetId: 'asset-one'),
        frameMatch(name: 'one-b.mp4', offsetMs: 36000, assetId: 'asset-one'),
        frameMatch(name: 'two.mp4', offsetMs: 35000, assetId: 'asset-two'),
        frameMatch(name: 'one-a.mp4', offsetMs: 22000, assetId: 'asset-one'),
        frameMatch(name: 'one-b.mp4', offsetMs: 23000, assetId: 'asset-one'),
      ]);
      expect(grouped.keys, ['asset-one', 'asset-two']);
      expect(grouped['asset-one']!.map((m) => m.seconds), [35, 22]);
      expect(grouped['asset-two'], hasLength(1));
    },
  );
  test('relative video timestamps and score meaning', () {
    final hit = FrameMatch(
      hit: VideoSearchHit(const <String, Object?>{
        'file_name': 'test',
        'playback_offset_ms': 35000,
        'score': .92,
        'score_ui': 1.0,
      }),
    );
    expect(hit.seconds, 35);
    expect(hit.distance, .92);
    expect(
      VideoSearchHit(const <String, Object?>{
        'ts_unix': '1788510000000',
      }).playbackOffsetMs,
      isNull,
    );
    expect(timeLabel(75), '01:15');
    expect(indexDone('success'), isTrue);
    expect(indexFailed('failed'), isTrue);
  });

  testWidgets('storage deletion previews before final confirmation', (
    tester,
  ) async {
    final c = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final gateway = FakeGateway(await testSession(), 'scope_7K3A');
    await tester.runAsync(
      () => c.activate(
        'scope_7K3A',
        gateway,
        canRead: true,
        canWrite: true,
        serviceNamespace: gateway.context.serviceNamespace,
        tenantId: gateway.context.tenantId,
        appUserId: gateway.context.appUserId,
        policyRevision: gateway.context.policyRevision,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: StorageDeletionPage(archive: c)));
    expect(
      find.text('Signing out keeps videos on this device and in the cloud.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('delete_cloud_library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete cloud library?'), findsOneWidget);
    expect(
      find.textContaining('Videos stored on this device remain'),
      findsOneWidget,
    );
    await tester.tap(find.text('Preview deletion'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Deletion preview'), findsOneWidget);
    expect(find.textContaining('20 bytes'), findsOneWidget);
    expect(
      find.byKey(const Key('confirm_delete_cloud_library')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('confirm_delete_cloud_library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.notice, 'Cloud library deleted. Videos on this device were kept.');
    c.dispose();
    await gateway.close();
  });

  testWidgets('uploaded local removal explains cloud retention', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('widget_remove_');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/clip.mp4')..writeAsBytesSync([1]);
    final c = ArchiveController(persist: false);
    final clip = ArchiveClip(
      id: 'clip',
      title: 'Clip',
      location: 'Test',
      duration: 1,
      asset: '',
      poster: '',
      path: file.path,
      remoteAssetId: 'asset-clip',
      uploaded: true,
      bundled: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordingSheet(archive: c, clip: clip),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('remove_local_copy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('cloud copy remains searchable'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(file.existsSync(), isTrue);
    c.dispose();
  });

  testWidgets('remote-only row never opens local playback', (tester) async {
    final c = ArchiveController(persist: false);
    final session = UserSessionController(
      auth: MockFirebaseAuth(),
      credentials: MockVmodalCredentialSource(),
      archive: c,
    );
    await tester.pump();
    c.clips = [
      ArchiveClip(
        id: 'remote',
        title: 'Remote',
        location: 'Test',
        duration: 1,
        asset: '',
        poster: '',
        remoteAssetId: 'asset-remote',
        uploaded: true,
        bundled: false,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(controller: c, session: session),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Cloud only'), findsOneWidget);
    await tester.tap(find.byType(VideoRow));
    await tester.pump();
    expect(
      find.text('This video is in the cloud but is not stored on this device.'),
      findsOneWidget,
    );
    expect(find.byType(RecordingSheet), findsNothing);
    session.dispose();
    c.dispose();
  });
}
