import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/src/errors.dart';
import 'package:vmodal_sdk_flutter/src/session_guard.dart';
import 'package:vmodal_sdk_flutter/src/upload.dart';

class DelayedStore extends MemoryUploadSessionStore {
  final started = Completer<void>();
  final release = Completer<void>();
  bool block = true;
  @override
  Future<void> save(String key, Map<String, Object?> value) async {
    if (block) {
      block = false;
      started.complete();
      await release.future;
    }
    await super.save(key, value);
  }
}

void main() {
  OwnerUploadSessionStore store(
    SessionGuard guard,
    String owner,
    UploadSessionStore delegate, {
    String policy = 'p1',
  }) => OwnerUploadSessionStore(
    guard: guard,
    ownerKey: owner,
    scopeKey: jsonEncode([owner, 'same-scope']),
    policyRevision: policy,
    delegate: delegate,
  );

  test(
    'identical upload contracts are owner partitioned and policy checked',
    () async {
      final backend = MemoryUploadSessionStore();
      final a = SessionGuard('a');
      final b = SessionGuard('b');
      final sa = store(a, 'owner-a', backend);
      final sb = store(b, 'owner-b', backend);
      final data = <String, Object?>{
        'parts': <Object?>[1],
      };
      final save = sa.save('same-contract', data);
      (data['parts'] as List).add(2);
      await save;
      expect(await sa.load('same-contract'), {
        'parts': [1],
      });
      expect(await sb.load('same-contract'), isNull);
      await sb.remove('same-contract');
      expect(await sa.load('same-contract'), isNotNull);
      a.invalidate();
      final narrowed = store(
        SessionGuard('new-a'),
        'owner-a',
        backend,
        policy: 'p2',
      );
      expect(await narrowed.load('same-contract'), isNull);
    },
  );

  test(
    'new A readers and writers fence accepted old A custom-store commit',
    () async {
      final backend = DelayedStore();
      final a = SessionGuard('old-a');
      final old = store(a, 'race-owner', backend);
      final oldWrite = old.save('contract', {'value': 'old'});
      final rejected = expectLater(oldWrite, throwsA(isA<OperationCanceled>()));
      await backend.started.future;
      a.invalidate();
      final fresh = store(SessionGuard('new-a'), 'race-owner', backend);
      var readFinished = false;
      final read = fresh.load('contract').then((value) {
        readFinished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      final latest = fresh.save('contract', {'value': 'new'});
      backend.release.complete();
      await rejected;
      expect(await read, {'value': 'old'});
      await latest;
      expect(await fresh.load('contract'), {'value': 'new'});
      await expectLater(
        old.remove('contract'),
        throwsA(isA<OperationCanceled>()),
      );
      expect(await fresh.load('contract'), {'value': 'new'});
    },
  );

  test(
    'queued retired save/remove cannot overwrite newer activation',
    () async {
      final backend = DelayedStore();
      final a = SessionGuard('queued-old');
      final old = store(a, 'queued-owner', backend);
      final first = old.save('contract', {'value': 1});
      final firstFailure = expectLater(
        first,
        throwsA(isA<OperationCanceled>()),
      );
      await backend.started.future;
      final queued = old.remove('contract');
      final queuedFailure = expectLater(
        queued,
        throwsA(isA<OperationCanceled>()),
      );
      final fresh = store(SessionGuard('queued-new'), 'queued-owner', backend);
      final latest = fresh.save('contract', {'value': 2});
      backend.release.complete();
      await Future.wait([firstFailure, queuedFailure, latest]);
      expect(await fresh.load('contract'), {'value': 2});
    },
  );

  test(
    'checkpoint namespace survives fresh generation with unchanged policy',
    () async {
      final backend = MemoryUploadSessionStore();
      final a = SessionGuard('restart-a');
      await store(a, 'stable-owner', backend).save('contract', {
        'parts': [1, 2],
      });
      a.invalidate();
      final restored = store(
        SessionGuard('restart-new-a'),
        'stable-owner',
        backend,
      );
      expect(await restored.load('contract'), {
        'parts': [1, 2],
      });
    },
  );
}
