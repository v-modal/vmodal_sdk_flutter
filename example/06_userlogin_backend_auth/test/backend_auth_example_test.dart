import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_backend_auth_example/backend_auth_example.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test('host HTTP classifications preserve identity and temporary failure', () {
    for (final entry in <int, BackendAuthFailure>{
      401: BackendAuthFailure.identityRejected,
      403: BackendAuthFailure.accessDenied,
      429: BackendAuthFailure.unavailable,
      503: BackendAuthFailure.unavailable,
      422: BackendAuthFailure.invalidResponse,
      200: BackendAuthFailure.invalidResponse,
    }.entries) {
      expect(
        () => parseBackendResponse(entry.key, null),
        throwsA(
          isA<BackendAuthException>().having(
            (error) => error.failure,
            'classified host failure',
            entry.value,
          ),
        ),
      );
    }
  });

  test('temporary throttle retains safe bounded retry information', () {
    expect(
      () => parseBackendResponse(
        429,
        null,
        retryAfter: const Duration(seconds: 2),
      ),
      throwsA(
        isA<BackendAuthException>().having(
          (error) => error.retryAfter,
          'retry-after',
          const Duration(seconds: 2),
        ),
      ),
    );
  });

  test('reference issuer contract rejection is not a temporary outage', () {
    expect(
      () => parseBackendResponse(502, {'code': 'issuer_contract_rejected'}),
      throwsA(
        isA<BackendAuthException>().having(
          (error) => error.failure,
          'issuer contract rejection',
          BackendAuthFailure.invalidResponse,
        ),
      ),
    );
    expect(
      () => parseBackendResponse(502, null),
      throwsA(
        isA<BackendAuthException>().having(
          (error) => error.failure,
          'unclassified gateway outage',
          BackendAuthFailure.unavailable,
        ),
      ),
    );
  });

  test('owner close is repeatable and retains no active connection', () async {
    final owner = BackendSessionOwner();
    await owner.close();
    await owner.close();
    expect(owner.current, isNull);
  });

  test(
    'host logout fences a callback still acquiring initial authorization',
    () async {
      final owner = BackendSessionOwner();
      final started = Completer<void>();
      final token = Completer<ScopedTokenEnvelope>();
      final opening = owner.activate(
        appUserId: 'app_user',
        projectId: 'project',
        loadToken: () {
          if (!started.isCompleted) started.complete();
          return token.future;
        },
      );
      final denied = expectLater(opening, throwsA(isA<SessionInvalidated>()));
      await started.future;
      await owner.close();
      final issued = DateTime.now().toUtc();
      token.complete(
        ScopedTokenEnvelope.fromJson({
          'version': 1,
          'auth_mode': 'developer_backend',
          'access_token': 'header.payload.signature',
          'token_type': 'Bearer',
          'expires_in': 300,
          'issued_at': issued.toIso8601String(),
          'expires_at': issued
              .add(const Duration(seconds: 300))
              .toIso8601String(),
          'principal_id': 'principal',
          'tenant_id': 'tenant',
          'project_id': 'project',
          'app_user_id': 'app_user',
          'policy_revision': 'policy',
          'delegation_revision': 1,
          'grants': [
            {
              'grant_id': 'library',
              'collection_id': 'library',
              'stream_name': 'stream',
              'mode': 'vid_file',
              'actions': ['search'],
              'collection_wide': false,
            },
          ],
        }),
      );
      await denied;
      expect(owner.current, isNull);
    },
  );
}
