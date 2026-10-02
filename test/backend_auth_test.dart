import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

final _start = DateTime.utc(2026, 10, 2);

String _token(String label) =>
    'eyJhbGciOiJSUzI1NiIsInR5cCI6InZtb2RhbC1zY29wZWQrand0Iiwia2lkIjoidGVzdCJ9.'
    '${base64Url.encode(utf8.encode(label)).replaceAll('=', '')}.c2lnbmF0dXJl';

Map<String, Object?> _envelope({
  String token = 'scoped-one',
  String project = 'framebase',
  String user = 'app-A',
  String policy = 'policy-1',
  DateTime? issued,
}) {
  final time = issued ?? _start;
  return {
    'version': 1,
    'auth_mode': 'developer_backend',
    'access_token': _token(token),
    'token_type': 'Bearer',
    'expires_in': 300,
    'issued_at': time.toIso8601String(),
    'expires_at': time.add(const Duration(seconds: 300)).toIso8601String(),
    'principal_id': 'principal-owner',
    'tenant_id': 'tenant-T',
    'project_id': project,
    'app_user_id': user,
    'policy_revision': policy,
    'delegation_revision': 3,
    'grants': [
      {
        'grant_id': 'my_library',
        'collection_id': 'opaque_A7f9',
        'stream_name': 'street_study',
        'mode': 'vid_file',
        'actions': ['discover', 'search', 'media'],
        'collection_wide': false,
      },
    ],
  };
}

Map<String, Object?> _profile(Map<String, Object?> value) => {
  for (final field in [
    'auth_mode',
    'principal_id',
    'tenant_id',
    'project_id',
    'app_user_id',
    'policy_revision',
    'delegation_revision',
    'grants',
  ])
    field: value[field],
  'user_id': value['principal_id'],
  'type': 'scoped_user',
  'expires_at': value['expires_at'],
};

class _Harness {
  DateTime now = _start;
  Map<String, Object?> next = _envelope();
  final Map<String, Map<String, Object?>> tokens = {};
  final List<VmodalRequest> requests = [];
  final List<Duration> delays = [];
  int loads = 0;
  Future<ScopedTokenEnvelope> Function()? load;
  Future<VmodalResponse> Function(VmodalRequest)? data;
  Map<String, Object?> Function(Map<String, Object?>)? profile;

  Future<ScopedTokenEnvelope> acquire() async {
    loads++;
    debugPrint('backend callback attempt $loads at $now');
    if (load != null) return load!();
    tokens[next['access_token']! as String] = next;
    return ScopedTokenEnvelope.fromJson(next);
  }

  VmodalTransport transport(SdkConfig config) => HandlerTransport((
    request,
  ) async {
    requests.add(request);
    debugPrint(
      '${request.method} ${request.uri.path} credential dispatched (redacted)',
    );
    expect(
      request.headers.keys.where((k) => k.toLowerCase().startsWith('x-user')),
      isEmpty,
    );
    if (request.uri.path == '/api/v1/auth/me') {
      final token = request.headers['Authorization']!.substring(7);
      final envelope = tokens[token] ?? next;
      return jsonResponse(
        jsonEncode(profile?.call(envelope) ?? _profile(envelope)),
      );
    }
    if (data != null) return data!(request);
    return jsonResponse(
      '{"data":[{"group_name":"opaque_A7f9","mode":"vid_file"}]}',
    );
  });
  Future<BackendConnection> connect({
    String project = 'framebase',
    String user = 'app-A',
    Duration leeway = const Duration(seconds: 60),
    ScopedTokenEnvelope? initial,
    Duration timeout = const Duration(seconds: 30),
  }) => VModal.connectWithBackend(
    expectedAppUserId: user,
    expectedProjectId: project,
    loadToken: acquire,
    baseUri: Uri.parse('https://gateway.test'),
    clock: () => now,
    refreshLeeway: leeway,
    timeout: timeout,
    initialToken: initial,
    delay: (duration) async {
      delays.add(duration);
    },
    transportFactory: transport,
    signedUploadTransportFactory: (_) => FakeSignedUploadTransport(),
  );
  List<VmodalRequest> get dataRequests =>
      requests.where((r) => r.uri.path != '/api/v1/auth/me').toList();
}

void main() {
  test(
    'strict immutable envelope accepts exact opaque grants and redacts bearer',
    () {
      debugPrint('Strict version, UTC lifetime, exact grant parsing');
      final raw = _envelope();
      final envelope = ScopedTokenEnvelope.fromJson(raw);
      expect(
        envelope.expiresAt.difference(envelope.issuedAt),
        const Duration(seconds: 300),
      );
      expect(envelope.grants.single.mapping.collectionId, 'opaque_A7f9');
      expect(
        envelope.grants.single.mapping.representation,
        ScopeRepresentation.opaque,
      );
      expect('$envelope', isNot(contains(_token('scoped-one'))));
      (raw['grants']! as List).clear();
      expect(envelope.grants, hasLength(1));
      expect(() => envelope.grants.clear(), throwsUnsupportedError);
      expect(
        () => envelope.grants.single.actions.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'reject unknown fields, versions, types, timestamps, sizes and grants',
    () {
      final bad = <Map<String, Object?>>[
        {..._envelope(), 'unexpected': true},
        {..._envelope(), 'version': true},
        {..._envelope(), 'version': 2},
        {..._envelope(), 'auth_mode': 'direct'},
        {..._envelope(), 'expires_in': 300.0},
        {..._envelope(), 'expires_in': 901},
        {..._envelope(), 'delegation_revision': true},
        {..._envelope(), 'expires_at': '2026-10-02T00:06:00Z'},
        {..._envelope(), 'issued_at': '2026-10-02T00:00:00+00:00'},
        {..._envelope(), 'issued_at': '2026-02-30T00:00:00Z'},
        {..._envelope(), 'access_token': 'x' * 8193},
        {..._envelope(), 'access_token': 'bad\nkey'},
        {..._envelope(), 'access_token': 'ak_master_key'},
        {..._envelope(), 'access_token': 'a..c'},
        {..._envelope(), 'app_user_id': '界' * 86},
        {..._envelope(), 'policy_revision': ''},
        {..._envelope(), 'app_user_id': 'user\u0085'},
        {..._envelope(), 'project_id': 'p' * 257},
        {..._envelope(), 'grants': []},
      ];
      final grant =
          (_envelope()['grants']! as List).single as Map<String, Object?>;
      for (final altered in [
        {...grant, 'actions': <String>[]},
        {
          ...grant,
          'actions': ['search', 'unknown'],
        },
        {
          ...grant,
          'actions': ['search', 'search'],
        },
        {...grant, 'collection_id': '*'},
        {...grant, 'collection_wide': 'false'},
        {...grant, 'extra': 1},
      ]) {
        bad.add({
          ..._envelope(),
          'grants': [altered],
        });
      }
      bad.add({
        ..._envelope(),
        'grants': [grant, grant],
      });
      for (var i = 0; i < bad.length; i++) {
        debugPrint('reject malformed envelope case $i');
        expect(
          () => ScopedTokenEnvelope.fromJson(bad[i]),
          throwsA(isA<ValidationException>()),
        );
      }
    },
  );

  test(
    'activate after auth/me agreement and scope does not prefix selectors',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      expect(connection.state, BackendConnectionState.ready);
      expect(h.loads, 1);
      expect(h.requests.single.uri.path, '/api/v1/auth/me');
      final scope = connection.scope('my_library');
      expect(scope.mapping.collectionId, 'opaque_A7f9');
      expect(
        () => connection.scope('unknown'),
        throwsA(isA<ValidationException>()),
      );
      await scope.search('person entering');
      expect(
        h.dataRequests.single.headers['Authorization'],
        'Bearer ${_token('scoped-one')}',
      );
      final json = h.dataRequests.single.jsonBody as Map;
      expect(json['group_name'], 'opaque_A7f9');
      expect(json['stream_name'], 'street_study');
      final session = connection.session;
      final closing = connection.close();
      expect(session.isActive, isFalse);
      expect(connection.state, BackendConnectionState.closed);
      expect(() => connection.session, throwsA(isA<SessionInvalidated>()));
      expect(identical(closing, connection.close()), isTrue);
      await closing;
    },
  );

  test(
    'initial token has identical verification without calling host loader',
    () async {
      final h = _Harness();
      final connection = await h.connect(
        initial: ScopedTokenEnvelope.fromJson(h.next),
      );
      expect(h.loads, 0);
      expect(h.requests.single.uri.path, '/api/v1/auth/me');
      await connection.close();
    },
  );

  test(
    'expected app/project mismatch and expired token fail before probe',
    () async {
      for (final raw in [
        _envelope(user: 'B'),
        _envelope(project: 'other'),
        _envelope(issued: _start.subtract(const Duration(seconds: 300))),
      ]) {
        final h = _Harness()..next = raw;
        await expectLater(h.connect(), throwsA(isA<BackendAuthException>()));
        expect(h.loads, 1);
        expect(h.requests, isEmpty);
      }
    },
  );

  test(
    'authoritative profile rejects missing binding and forged copied grants',
    () async {
      for (final field in [
        'user_id',
        'principal_id',
        'tenant_id',
        'project_id',
        'app_user_id',
        'policy_revision',
        'delegation_revision',
        'auth_mode',
        'grants',
      ]) {
        final h = _Harness()..profile = (raw) => _profile(raw)..remove(field);
        debugPrint('auth/me must contain agreeing $field');
        await expectLater(h.connect(), throwsA(isA<SdkException>()));
        expect(h.loads, 1);
      }
      final h = _Harness();
      h.profile = (raw) => {
        ..._profile(raw),
        'grants': [
          {
            ...(raw['grants']! as List).single as Map<String, Object?>,
            'collection_id': 'other_collection',
          },
        ],
      };
      await expectLater(h.connect(), throwsA(isA<BackendAuthException>()));
    },
  );

  test(
    'same policy rotation coalesces and preserves session, owner and lease',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      final session = connection.session;
      final lease = connection.scope('my_library').storageLease;
      final pending = Completer<ScopedTokenEnvelope>();
      h.next = _envelope(
        token: 'scoped-two',
        issued: _start.add(const Duration(seconds: 30)),
      );
      h.load = () => pending.future;
      final states = <BackendConnectionState>[];
      final subscription = connection.states.listen(states.add);
      final first = connection.refresh(), second = connection.refresh();
      expect(identical(first, second), isTrue);
      pending.complete(ScopedTokenEnvelope.fromJson(h.next));
      await Future.wait([first, second]);
      expect(h.loads, 2);
      expect(identical(session, connection.session), isTrue);
      lease.check();
      await connection.session.listCollections();
      expect(
        h.dataRequests.last.headers['Authorization'],
        'Bearer ${_token('scoped-two')}',
      );
      expect(states, [
        BackendConnectionState.refreshing,
        BackendConnectionState.ready,
      ]);
      await subscription.cancel();
      await connection.close();
    },
  );

  test(
    'policy, grants, tenant or principal change invalidates synchronously',
    () async {
      for (final field in [
        'policy_revision',
        'delegation_revision',
        'principal_id',
        'tenant_id',
        'grants',
      ]) {
        final h = _Harness();
        final connection = await h.connect();
        final old = connection.session;
        h.next = {
          ..._envelope(token: 'scoped-two'),
          field: field == 'delegation_revision'
              ? 4
              : field == 'grants'
              ? [
                  {
                    ...(_envelope()['grants']! as List).single
                        as Map<String, Object?>,
                    'actions': ['search'],
                  },
                ]
              : 'changed',
        };
        await expectLater(
          connection.refresh(),
          throwsA(isA<BackendAuthException>()),
        );
        expect(connection.state, BackendConnectionState.invalidated);
        expect(old.isActive, isFalse);
        expect(() => connection.session, throwsA(isA<SessionInvalidated>()));
        await connection.close();
      }
    },
  );

  test(
    'same app user in different projects has different owner and scope keys',
    () async {
      final a = _Harness(),
          b = _Harness()..next = _envelope(project: 'project-B');
      final ca = await a.connect(), cb = await b.connect(project: 'project-B');
      expect(ca.session.context.ownerKey, isNot(cb.session.context.ownerKey));
      expect(
        ca.scope('my_library').scopeKey,
        isNot(cb.scope('my_library').scopeKey),
      );
      await ca.close();
      await cb.close();
    },
  );

  test(
    'transient acquisition is bounded to three attempts with injected delays',
    () async {
      final h = _Harness()
        ..load = () async =>
            throw const BackendAuthException(BackendAuthFailure.unavailable);
      await expectLater(h.connect(), throwsA(isA<BackendAuthException>()));
      expect(h.loads, 3);
      expect(h.delays, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 1000),
      ]);
      expect(h.requests, isEmpty);
    },
  );

  test(
    'backend 401 or 403 invalidates while transient outage retains valid token',
    () async {
      for (final failure in BackendAuthFailure.values) {
        final h = _Harness();
        final connection = await h.connect();
        final old = connection.session;
        h.load = () async => throw BackendAuthException(failure);
        await expectLater(
          connection.refresh(),
          throwsA(isA<BackendAuthException>()),
        );
        if (failure == BackendAuthFailure.unavailable) {
          expect(old.isActive, isTrue);
          expect(connection.state, BackendConnectionState.unavailable);
          await old.listCollections();
          expect(h.dataRequests, hasLength(1));
          h.now = _start.add(const Duration(seconds: 301));
          await expectLater(
            old.listCollections(),
            throwsA(isA<BackendAuthException>()),
          );
          expect(h.dataRequests, hasLength(1));
        } else {
          expect(old.isActive, isFalse);
          expect(connection.state, BackendConnectionState.invalidated);
        }
        await connection.close();
      }
    },
  );

  test(
    'parallel expired requests join one renewal and never dispatch expired bearer',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      h.now = _start.add(const Duration(seconds: 301));
      h.next = _envelope(token: 'scoped-two', issued: h.now);
      final pending = Completer<ScopedTokenEnvelope>();
      h.load = () => pending.future;
      final first = connection.session.listCollections(),
          second = connection.session.listCollections();
      await Future<void>.delayed(Duration.zero);
      expect(h.loads, 2);
      expect(h.dataRequests, isEmpty);
      pending.complete(ScopedTokenEnvelope.fromJson(h.next));
      await Future.wait([first, second]);
      expect(h.dataRequests, hasLength(2));
      expect(
        h.dataRequests.map((r) => r.headers['Authorization']),
        everyElement('Bearer ${_token('scoped-two')}'),
      );
      await connection.close();
    },
  );

  test(
    'close cancels pending renewal immediately and fences late callback',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      final pending = Completer<ScopedTokenEnvelope>();
      h.load = () => pending.future;
      final renewal = connection.refresh();
      final failure = expectLater(renewal, throwsA(isA<OperationCanceled>()));
      await connection.close();
      await failure;
      pending.complete(ScopedTokenEnvelope.fromJson(_envelope(token: 'late')));
      await Future<void>.delayed(Duration.zero);
      expect(connection.state, BackendConnectionState.closed);
      expect(h.requests, hasLength(1));
    },
  );

  test('GET 401 recovers once; POST and 403 never replay or broaden', () async {
    final h = _Harness();
    final connection = await h.connect();
    h.next = _envelope(token: 'scoped-two');
    var calls = 0;
    h.data = (_) async => jsonResponse('{}', status: calls++ == 0 ? 401 : 200);
    await connection.session.listCollections();
    expect(h.loads, 2);
    expect(h.dataRequests, hasLength(2));
    h.data = (_) async => jsonResponse('{}', status: 401);
    await expectLater(
      connection.scope('my_library').search('query'),
      throwsA(isA<AuthException>()),
    );
    expect(h.dataRequests, hasLength(3));
    expect(h.loads, 2);
    h.next = _envelope(token: 'scoped-three');
    h.data = (_) async => jsonResponse('{}', status: 403);
    await expectLater(
      connection.session.listCollections(),
      throwsA(isA<ApiException>()),
    );
    expect(h.loads, 3); // Recovery before later request, never mutation replay.
    expect(h.dataRequests, hasLength(4));
    expect(connection.session.isActive, isTrue);
    await connection.close();
  });

  test(
    'stale 401 cannot revoke a replacement and uses it without another callback',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      final denied = Completer<VmodalResponse>();
      final started = Completer<void>();
      var calls = 0;
      h.data = (_) {
        if (calls++ == 0) {
          started.complete();
          return denied.future;
        }
        return Future.value(jsonResponse('{}'));
      };
      final read = connection.session.listCollections();
      await started.future;
      h.next = _envelope(token: 'scoped-two');
      await connection.refresh();
      denied.complete(jsonResponse('{}', status: 401));
      await read;
      expect(h.loads, 2);
      expect(
        h.dataRequests.last.headers['Authorization'],
        'Bearer ${_token('scoped-two')}',
      );
      await connection.close();
    },
  );

  test('acquisition timeout gates data and discards late envelope', () async {
    final h = _Harness();
    final pending = Completer<ScopedTokenEnvelope>();
    h.load = () => pending.future;
    await expectLater(
      h.connect(timeout: const Duration(milliseconds: 20)),
      throwsA(isA<BackendAuthException>()),
    );
    pending.complete(ScopedTokenEnvelope.fromJson(h.next));
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, isEmpty);
  });

  test(
    'near-expiry reads retain valid token while one proactive renewal runs',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      h.now = _start.add(const Duration(seconds: 250));
      h.next = _envelope(token: 'renewed', issued: h.now);
      final pending = Completer<ScopedTokenEnvelope>();
      h.load = () => pending.future;
      await Future.wait([
        connection.session.listCollections(),
        connection.session.listCollections(),
      ]);
      expect(h.loads, 2);
      expect(connection.state, BackendConnectionState.refreshing);
      expect(
        h.dataRequests.map((r) => r.headers['Authorization']),
        everyElement('Bearer ${_token('scoped-one')}'),
      );
      pending.complete(ScopedTokenEnvelope.fromJson(h.next));
      await connection.refresh();
      expect(connection.state, BackendConnectionState.ready);
      await connection.close();
    },
  );

  test('binary media gates expiry between URL grant and byte request', () async {
    final h = _Harness();
    final connection = await h.connect();
    var calls = 0;
    h.data = (_) async {
      switch (calls++) {
        case 0:
          return jsonResponse(
            '{"data":[{"asset_id":"a","filename":"a.mp4","playback_offset_ms":2300}]}',
          );
        case 1:
          h.now = _start.add(const Duration(seconds: 301));
          h.next = _envelope(token: 'renewed', issued: h.now);
          return jsonResponse(
            '{"found":true,"url_pre_signed":"https://objects.test/scoped"}',
          );
        default:
          return VmodalResponse(statusCode: 200, body: Stream.value([1, 2, 3]));
      }
    };
    final scope = connection.scope('my_library');
    final asset = (await scope.search('person')).assets.single;
    expect(await scope.imageBytes(asset), [1, 2, 3]);
    expect(h.loads, 2);
    expect(h.dataRequests.last.responseMode, VmodalResponseMode.bytes);
    expect(
      h.dataRequests.last.headers['Authorization'],
      'Bearer ${_token('renewed')}',
    );
    await connection.close();
  });

  test('second 401 exhausts read credential budget without looping', () async {
    final h = _Harness();
    final connection = await h.connect();
    h.next = _envelope(token: 'renewed');
    h.data = (_) async => jsonResponse('{}', status: 401);
    await expectLater(
      connection.session.listCollections(),
      throwsA(isA<AuthException>()),
    );
    expect(h.loads, 2);
    expect(h.dataRequests, hasLength(2));
    await connection.close();
  });

  test(
    'host cancellation is not retried and invalidates the active session',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      final active = connection.session;
      var observed = false;
      final subscription = connection.states.listen((state) {
        if (state == BackendConnectionState.invalidated) {
          observed = true;
          expect(active.isActive, isFalse);
        }
      });
      h.load = () async => throw const SessionInvalidated();
      await expectLater(
        connection.refresh(),
        throwsA(isA<OperationCanceled>()),
      );
      expect(h.loads, 2);
      expect(h.delays, isEmpty);
      expect(active.isActive, isFalse);
      expect(observed, isTrue);
      expect(connection.state, BackendConnectionState.invalidated);
      await subscription.cancel();
      await connection.close();
    },
  );

  test(
    'closed lifecycle event sees a retired guard and unavailable session',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      final active = connection.session;
      var observed = false;
      final subscription = connection.states.listen((state) {
        if (state == BackendConnectionState.closed) {
          observed = true;
          expect(active.isActive, isFalse);
          expect(() => connection.session, throwsA(isA<SessionInvalidated>()));
        }
      });
      await connection.close();
      expect(observed, isTrue);
      await subscription.cancel();
    },
  );

  test(
    'ordinary retry renews a snapshot that expired during retry delay',
    () async {
      final h = _Harness();
      final connection = await h.connect();
      var calls = 0;
      h.data = (_) async {
        if (calls++ == 0) {
          h.now = _start.add(const Duration(seconds: 301));
          h.next = _envelope(token: 'renewed', issued: h.now);
          return jsonResponse('{}', status: 503);
        }
        return jsonResponse('{}');
      };
      await connection.session.listCollections();
      expect(h.loads, 2);
      expect(h.dataRequests, hasLength(2));
      expect(
        h.dataRequests.last.headers['Authorization'],
        'Bearer ${_token('renewed')}',
      );
      await connection.close();
    },
  );

  test('lifecycle listeners can close reentrantly during renewal', () async {
    final h = _Harness();
    final connection = await h.connect();
    final pending = Completer<ScopedTokenEnvelope>();
    h.load = () => pending.future;
    final subscription = connection.states.listen((state) {
      if (state == BackendConnectionState.refreshing) {
        unawaited(connection.close());
      }
    });
    await expectLater(connection.refresh(), throwsA(isA<OperationCanceled>()));
    expect(connection.state, BackendConnectionState.closed);
    pending.complete(ScopedTokenEnvelope.fromJson(_envelope(token: 'late')));
    await subscription.cancel();
  });
}
