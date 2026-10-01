import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';
import 'user_session_test.dart' as sessions;

/// Deliberately ignores cancellation to exercise the restricted public facade.
class AcceptanceSignedTransport extends FakeSignedUploadTransport {
  final started = Completer<void>();
  final release = Completer<SignedUploadResult>();
  void Function(UploadProgress)? emit;

  @override
  Future<SignedUploadResult> upload({
    required UploadSource source,
    required Uri url,
    String method = 'PUT',
    int offset = 0,
    int? length,
    Map<String, String> headers = const {},
    Duration? timeout,
    required CancellationToken cancellation,
    void Function(UploadProgress)? onProgress,
  }) {
    calls.add(
      SignedCall(
        url: url,
        method: method,
        headers: Map.of(headers),
        offset: offset,
        length: length ?? source.contentLength,
      ),
    );
    emit = onProgress;
    if (!started.isCompleted) started.complete();
    return release.future;
  }
}

TenantCredential credential(SdkConfig config, String key) => TenantCredential(
  serviceNamespace: SessionContext.serviceNamespaceFor(config),
  tenantId: 'same-tenant',
  principal: 'tenant-principal',
  apiKey: key,
);

UserSessionManager manager(
  SdkConfig config,
  TenantCredentialSource source,
  List<VmodalTransport> apis, {
  SignedUploadTransport? signed,
}) {
  var count = 0;
  return UserSessionManager(
    config: config,
    credentialSource: source,
    transportFactory: (_) => apis[count++],
    signedUploadTransportFactory: (_) =>
        count == 1 && signed != null ? signed : FakeSignedUploadTransport(),
  );
}

UploadSource uploadSource() => UploadSource(
  fileName: 'same.mp4',
  contentLength: 1,
  sourceId: 'same-source',
  versionTag: 'v1',
  opener: () => Stream.value([7]),
);

class CustomPassthroughSubclass extends PassthroughVideoTranscoder {
  bool called = false;

  @override
  bool get isPassthrough => false;

  @override
  Future<TranscodeResult> reduce(File input) {
    called = true;
    throw StateError('unbound hook');
  }
}

void main() {
  test(
    'same principal/key/URL/query never joins A response or cache in B',
    () async {
      stdout.writeln(
        '[acceptance] identical tenant identity and query, independent A/B work',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final pending = Completer<VmodalResponse>();
      final dispatched = Completer<void>();
      final aApi = HandlerTransport((request) async {
        if (request.method == 'GET') {
          return jsonResponse('{"user_id":"tenant-principal"}');
        }
        dispatched.complete();
        return pending.future;
      });
      final bApi = FakeTransport()
        ..addJson({'user_id': 'tenant-principal'})
        ..addJson({
          'data': [
            {'asset_id': 'B', 'filename': 'B.mp4'},
          ],
        });
      final control = manager(config, keys, [aApi, bApi]);
      final map = sessions.mapping('same');
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      await a.verifyPrincipal('tenant-principal');
      final old = a.scope(map).search('identical');
      final rejected = expectLater(old, throwsA(isA<OperationCanceled>()));
      await dispatched.future;
      final b = await control.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      await b.verifyPrincipal('tenant-principal');
      final fresh = await b.scope(map).search('identical');
      expect(fresh.assets.single.assetId, 'B');
      expect(aApi.requests.last.uri, bApi.requests.last.uri);
      expect(aApi.requests.last.jsonBody, bApi.requests.last.jsonBody);
      expect(aApi.requests.last.headers['Authorization'], 'Bearer same-key');
      expect(bApi.requests.last.headers['Authorization'], 'Bearer same-key');
      await rejected.timeout(const Duration(seconds: 1));
      pending.complete(
        jsonResponse('{"data":[{"asset_id":"A","filename":"A.mp4"}]}'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(control.current, same(b));
      expect(fresh.assets.single.assetId, 'B');
      await control.close();
    },
  );

  test(
    'switch after headers while body stays open cancels public search promptly',
    () async {
      stdout.writeln(
        '[acceptance] uncooperative response body cannot keep A public operation alive',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final consumed = Completer<void>();
      final body = StreamController<List<int>>(onListen: consumed.complete);
      final aApi = FakeTransport()
        ..addResponse(VmodalResponse(statusCode: 200, body: body.stream));
      final bApi = FakeTransport()..addJson({'data': <Object?>[]});
      final control = manager(config, keys, [aApi, bApi]);
      final map = sessions.mapping('same');
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final result = a.scope(map).search('query');
      final rejected = expectLater(
        result,
        throwsA(isA<OperationCanceled>().having((e) => e.body, 'body', isNull)),
      );
      await consumed.future;
      body.add('{"data":['.codeUnits);
      final b = await control.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      await rejected.timeout(const Duration(seconds: 1));
      body.add('{"asset_id":"A"}]}'.codeUnits);
      await body.close();
      expect((await b.scope(map).search('query')).assets, isEmpty);
      expect(control.current, same(b));
      await control.close();
    },
  );

  test(
    'gateway retry queued for A does not dispatch after B activation',
    () async {
      stdout.writeln(
        '[acceptance] real gateway retry delay retains originating lease',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test', maxRetries: 3);
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final consumed = Completer<void>();
      Stream<List<int>> response() async* {
        yield '{}'.codeUnits;
        consumed.complete();
      }

      final aApi = FakeTransport()
        ..addResponse(VmodalResponse(statusCode: 503, body: response()));
      final bApi = FakeTransport()..addJson({'user_id': 'tenant-principal'});
      final control = manager(config, keys, [aApi, bApi]);
      final map = sessions.mapping('same');
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final read = a.verifyPrincipal('tenant-principal');
      final rejected = expectLater(read, throwsA(isA<OperationCanceled>()));
      await consumed.future;
      await Future<void>.delayed(Duration.zero);
      final b = await control.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      await rejected.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(aApi.requests, hasLength(1));
      await b.verifyPrincipal('tenant-principal');
      expect(control.current, same(b));
      await control.close();
    },
  );

  test(
    'A switch during shared renewal keeps B recovery and app identity alive',
    () async {
      stdout.writeln(
        '[acceptance] tenant renewal continues for B; outgoing A provider stays closed',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final started = Completer<void>();
      final pending = Completer<TenantCredential>();
      var renewals = 0;
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
        renew: () {
          renewals++;
          started.complete();
          return pending.future;
        },
      );
      final aApi = FakeTransport()..addJson({}, status: 401);
      final bApi = FakeTransport()
        ..addJson({}, status: 401)
        ..addJson({'user_id': 'tenant-principal'});
      final control = manager(config, keys, [aApi, bApi]);
      final map = sessions.mapping('same');
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final old = a.verifyPrincipal('tenant-principal');
      final rejected = expectLater(old, throwsA(isA<OperationCanceled>()));
      await started.future;
      final b = await control.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      final fresh = b.verifyPrincipal('tenant-principal');
      await Future<void>.delayed(Duration.zero);
      pending.complete(credential(config, 'rotated-key'));
      await rejected;
      await fresh;
      expect(renewals, 1);
      expect(aApi.requests, hasLength(1));
      expect(bApi.requests.last.headers['Authorization'], 'Bearer rotated-key');
      expect(b.context.appUserId, 'B');
      expect(b.isActive, isTrue);
      expect(control.current, same(b));
      await control.close();
    },
  );

  test('nested JSON maps with broad key types are immutable snapshots', () async {
    stdout.writeln(
      '[acceptance] JSON-compatible nested maps do not retain mutable caller state',
    );
    final cfg = sessions.setup();
    final map = sessions.mapping('same');
    final a = await cfg.manager.openResolvedSession(
      () async => sessions.policy('A', map),
    );
    final nested = <Object?, Object?>{
      'filter': <Object?>['before'],
    };
    cfg.apis.single.addJson({'data': <Object?>[]});
    final query = a
        .scope(map)
        .search(
          'same',
          options: ScopedSearchOptions(queryMetadata: {'nested': nested}),
        );
    (nested['filter']! as List<Object?>)[0] = 'after';
    await query;
    final body = cfg.apis.single.requests.single.jsonBody! as Map;
    expect(body['query_metadata'], {
      'nested': {
        'filter': ['before'],
      },
    });
    await cfg.manager.close();
  });

  test(
    'non-string JSON keys and custom objects reject before dispatch',
    () async {
      stdout.writeln(
        '[acceptance] malformed mutable option values never reach transport',
      );
      final cfg = sessions.setup();
      final map = sessions.mapping('same');
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      for (final value in [
        <Object?, Object?>{1: 'invalid'},
        Object(),
      ]) {
        expect(
          () => a
              .scope(map)
              .search(
                'same',
                options: ScopedSearchOptions(queryMetadata: {'nested': value}),
              ),
          throwsA(isA<ValidationException>()),
        );
      }
      expect(cfg.apis.single.requests, isEmpty);
      expect(a.isActive, isTrue);
      await cfg.manager.close();
    },
  );

  test(
    'out-of-order renewals spanning A/B cannot overwrite newer B credential',
    () async {
      stdout.writeln(
        '[acceptance] revision/ticket fencing survives app-user switch',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final old = Completer<TenantCredential>();
      final newer = Completer<TenantCredential>();
      var calls = 0;
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
        renew: () => calls++ == 0 ? old.future : newer.future,
      );
      final aApi = FakeTransport();
      final bApi = FakeTransport()..addJson({'data': <Object?>[]});
      final control = manager(config, keys, [aApi, bApi]);
      final map = sessions.mapping('same');
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final first = keys.renewCredential();
      final b = await control.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      final second = keys.renewCredential(supersede: true);
      newer.complete(credential(config, 'newer-key'));
      await second;
      old.complete(credential(config, 'older-key'));
      await first;
      await b.scope(map).search('B');
      expect(keys.revision, 1);
      expect(bApi.requests.single.headers['Authorization'], 'Bearer newer-key');
      expect(a.isActive, isFalse);
      expect(() => a.scope(map), throwsA(isA<OperationCanceled>()));
      expect(control.current, same(b));
      await control.close();
    },
  );

  test(
    'authoritative key revocation blocks calls without logging app user out',
    () async {
      stdout.writeln(
        '[acceptance] tenant connection failure preserves the active app identity',
      );
      final cfg = sessions.setup();
      final map = sessions.mapping('same');
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final id = a.sessionId;
      cfg.credentials.revoke();
      await expectLater(
        a.scope(map).search('blocked'),
        throwsA(isA<TenantAuthException>()),
      );
      expect(cfg.apis.single.requests, isEmpty);
      expect(a.isActive, isTrue);
      expect(cfg.manager.current, same(a));
      expect(a.context.appUserId, 'A');
      cfg.credentials.install(
        credential(SdkConfig(baseUrl: 'https://gateway.test'), 'recovered-key'),
      );
      cfg.apis.single.addJson({'data': <Object?>[]});
      await a.scope(map).search('recovered');
      expect(a.sessionId, id);
      expect(
        cfg.apis.single.requests.single.headers['Authorization'],
        'Bearer recovered-key',
      );
      await cfg.manager.close();
    },
  );

  test(
    'service/principal binding replacements and caller checkpoint stores reject locally',
    () async {
      stdout.writeln(
        '[acceptance] in-place credential identity changes and unbound storage reject',
      );
      final cfg = sessions.setup();
      final map = sessions.mapping('same', actions: {UserAction.upload});
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      for (final candidate in [
        TenantCredential(
          serviceNamespace: 'https://another.test',
          tenantId: 'same-tenant',
          principal: 'tenant-principal',
          apiKey: 'same-key',
        ),
        TenantCredential(
          serviceNamespace: a.context.serviceNamespace,
          tenantId: 'another',
          principal: 'tenant-principal',
          apiKey: 'same-key',
        ),
        TenantCredential(
          serviceNamespace: a.context.serviceNamespace,
          tenantId: 'same-tenant',
          principal: 'another',
          apiKey: 'same-key',
        ),
      ]) {
        expect(
          () => cfg.credentials.install(candidate),
          throwsA(isA<TenantAuthException>()),
        );
      }
      expect(cfg.credentials.revision, 0);
      expect(cfg.credentials.currentSnapshot.apiKey, 'same-key');
      final hook = CustomPassthroughSubclass();
      expect(
        () => a
            .scope(map)
            .upload(
              uploadSource(),
              options: ScopedUploadOptions(
                uploadOptions: VideoUploadOptions(transcoder: hook),
              ),
            ),
        throwsA(isA<ValidationException>()),
      );
      expect(hook.called, isFalse);
      expect(
        () => a
            .scope(map)
            .upload(
              uploadSource(),
              options: ScopedUploadOptions(
                uploadOptions: VideoUploadOptions(
                  sessionStore: MemoryUploadSessionStore(),
                ),
              ),
            ),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.single.requests, isEmpty);
      expect(cfg.signed.single.calls, isEmpty);
      expect(a.isActive, isTrue);
      await cfg.manager.close();
    },
  );

  for (final phase in ['signed', 'retry', 'verification', 'completion']) {
    test('multipart switch during $phase prevents all later A phases', () async {
      stdout.writeln(
        '[acceptance] multipart A lease at $phase; no late signed retry/finalization',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final source = uploadSource();
      final digest = await md5Hex(source, offset: 0, length: 1);
      final reached = Completer<void>();
      final release = Completer<VmodalResponse>();
      final signed = AcceptanceSignedTransport();
      var statuses = 0;
      final aApi = HandlerTransport((request) async {
        final path = request.uri.path;
        if (path.endsWith(Routes.externalUploadMultipartCreate)) {
          return jsonResponse(
            '{"request_id":"r","upload_id":"u","key":"k","part_count":1,"part_size_bytes":5242880}',
          );
        }
        if (path.endsWith(Routes.externalUploadMultipartSignParts)) {
          return jsonResponse(
            '{"parts":[{"part_number":1,"url":"https://objects.test/1","method":"PUT"}]}',
          );
        }
        if (path.endsWith(Routes.externalUploadMultipartStatus)) {
          statuses++;
          if (statuses == 1 || phase == 'retry') {
            if (statuses == 2) reached.complete();
            return jsonResponse('{"status":"uploading","parts":[]}');
          }
          if (phase == 'verification') {
            reached.complete();
            return release.future;
          }
          return jsonResponse(
            '{"status":"uploading","parts":[{"part_number":1,"size_bytes":1,"etag":"$digest"}]}',
          );
        }
        if (path.endsWith(Routes.externalUploadMultipartComplete)) {
          reached.complete();
          return release.future;
        }
        throw StateError('A dispatched unexpected phase: $path');
      });
      final bApi = FakeTransport()..addJson({'data': <Object?>[]});
      final control = manager(config, keys, [aApi, bApi], signed: signed);
      final map = sessions.mapping(
        'same',
        actions: {UserAction.search, UserAction.upload},
      );
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final task = a
          .scope(map)
          .upload(
            source,
            options: const ScopedUploadOptions(
              uploadOptions: VideoUploadOptions(
                multipart: true,
                partSizeBytes: 5242880,
                maxConcurrency: 1,
                maxPartAttempts: 3,
              ),
            ),
          );
      final progress = <UploadProgress>[];
      final subscription = task.progress.listen(
        progress.add,
        onError: (Object _) {},
      );
      final rejected = expectLater(
        task.result,
        throwsA(isA<OperationCanceled>()),
      );
      await signed.started.future;
      if (phase != 'signed') {
        if (phase == 'retry') {
          signed.release.completeError(
            SignedUploadFailure(sentBytes: 1, localMd5: digest),
          );
        } else {
          signed.release.complete(
            SignedUploadResult(statusCode: 200, etag: digest, localMd5: digest),
          );
        }
        await reached.future;
        await Future<void>.delayed(Duration.zero);
      }
      final requestsBefore = aApi.requests.length;
      final b = await control.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      final emittedBefore = progress.length;
      await rejected.timeout(const Duration(seconds: 1));
      signed.emit?.call(const UploadProgress(1, 1));
      if (phase == 'signed') {
        signed.release.complete(
          SignedUploadResult(statusCode: 200, etag: digest, localMd5: digest),
        );
      } else if (phase == 'verification' || phase == 'completion') {
        release.complete(
          jsonResponse('{"etag":"completed","status":"completed","parts":[]}'),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(progress, hasLength(emittedBefore));
      expect(aApi.requests, hasLength(requestsBefore));
      expect(signed.calls, hasLength(1));
      expect(
        signed.calls.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        aApi.requests.where(
          (r) => r.uri.path.endsWith(Routes.externalUploadDone),
        ),
        isEmpty,
      );
      await b.scope(map).search('B still works');
      expect(control.current, same(b));
      await subscription.cancel();
      await control.close();
    });
  }

  test(
    'rotation while signed PUT waits preserves scope and uses fresh gateway finalization',
    () async {
      stdout.writeln(
        '[acceptance] independent signed capability remains bearer-free across rotation',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final keys = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final api = FakeTransport()
        ..addJson({
          'url': 'https://objects.test/same?signature=old',
          'key': 'k',
          'method': 'PUT',
        })
        ..addJson({'asset_id': 'a', 'filename': 'same.mp4'});
      final signed = AcceptanceSignedTransport();
      final control = manager(config, keys, [api], signed: signed);
      final map = sessions.mapping('same', actions: {UserAction.upload});
      final a = await control.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final owner = a.context.ownerKey;
      final scope = a.context.scopeKey(map);
      final id = a.sessionId;
      final task = a.scope(map).upload(uploadSource());
      await signed.started.future;
      keys.install(credential(config, 'rotated-key'));
      signed.release.complete(
        const SignedUploadResult(statusCode: 200, etag: 'e'),
      );
      expect((await task.result).asset?.assetId, 'a');
      expect(a.context.ownerKey, owner);
      expect(a.context.scopeKey(map), scope);
      expect(a.sessionId, id);
      expect(api.requests.first.headers['Authorization'], 'Bearer same-key');
      expect(api.requests.last.headers['Authorization'], 'Bearer rotated-key');
      expect(signed.calls.single.url.queryParameters['signature'], 'old');
      expect(
        signed.calls.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      await control.close();
    },
  );
}
