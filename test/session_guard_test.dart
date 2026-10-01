// Verbose acceptance output is required by this SDK's agent rules.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/src/session_guard.dart';
import 'package:vmodal_sdk_flutter/src/transport.dart' show readBounded;
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

class DelayedSignedTransport implements SignedUploadTransport {
  final Completer<SignedUploadResult> pending = Completer<SignedUploadResult>();
  void Function(UploadProgress)? emit;
  int calls = 0;

  @override
  Future<SignedUploadResult> upload({
    required UploadSource source,
    required Uri url,
    String method = 'PUT',
    int offset = 0,
    int? length,
    Map<String, String> headers = const <String, String>{},
    Duration? timeout,
    required CancellationToken cancellation,
    void Function(UploadProgress)? onProgress,
  }) {
    calls++;
    emit = onProgress;
    return pending.future;
  }

  @override
  Future<void> close() async {}
}

class FailingCloseTransport extends FakeTransport {
  void Function()? onClose;

  @override
  Future<void> close() async {
    onClose?.call();
    await super.close();
    throw StateError('gateway close failed');
  }
}

class ReentrantHeaders extends MapBase<String, String> {
  ReentrantHeaders(this.onRead);
  final void Function() onRead;
  @override
  Iterable<String> get keys {
    onRead();
    return const <String>[];
  }

  @override
  String? operator [](Object? key) => null;
  @override
  void operator []=(String key, String value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  String? remove(Object? key) => throw UnsupportedError('read only');
}

void main() {
  test(
    'retained multipart sources cannot open after session invalidation',
    () async {
      print(
        '[session guard] captured multipart opener checks before file preparation',
      );
      final guard = SessionGuard('A-files');
      final api = FakeTransport()..addJson(<String, Object?>{});
      var opened = 0;
      final response = await GuardedVmodalTransport(guard, api).send(
        VmodalRequest(
          method: 'POST',
          uri: Uri.parse('https://gateway.test/upload'),
          files: [
            VmodalFilePart(
              fieldName: 'file',
              fileName: 'a.mp4',
              contentLength: 1,
              opener: () {
                opened++;
                return Stream.value([1]);
              },
            ),
          ],
        ),
      );
      await readBounded(response, 100);
      guard.invalidate();
      expect(
        () => api.requests.single.files.single.open(),
        throwsA(isA<OperationCanceled>()),
      );
      expect(opened, 0);
    },
  );

  test(
    'a completed response consumed after invalidation disposes its raw source',
    () async {
      final guard = SessionGuard('A-body');
      final body = StreamController<List<int>>();
      var disposed = false;
      body.onCancel = () => disposed = true;
      final api = FakeTransport()
        ..addResponse(VmodalResponse(statusCode: 200, body: body.stream));
      final response = await GuardedVmodalTransport(guard, api).send(
        VmodalRequest(
          method: 'GET',
          uri: Uri.parse('https://gateway.test/private'),
        ),
      );
      guard.invalidate();
      await expectLater(
        readBounded(response, 100),
        throwsA(isA<OperationCanceled>()),
      );
      expect(disposed, isTrue);
      await body.close();
    },
  );

  test(
    'original response is disposed when metadata callbacks invalidate delivery',
    () async {
      print(
        '[session guard] disposal reaches raw body after response metadata reentry',
      );
      final guard = SessionGuard('A-race');
      final pending = Completer<VmodalResponse>();
      final body = StreamController<List<int>>();
      var disposed = false;
      body.onCancel = () => disposed = true;
      final result =
          GuardedVmodalTransport(
            guard,
            HandlerTransport((_) => pending.future),
          ).send(
            VmodalRequest(
              method: 'GET',
              uri: Uri.parse('https://gateway.test/search'),
            ),
          );
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      pending.complete(
        VmodalResponse(
          statusCode: 200,
          body: body.stream,
          // Custom transport metadata is captured after the body is wrapped.
          // Reentry there must dispose the original body, not the closed wrapper.
          headers: ReentrantHeaders(guard.invalidate),
        ),
      );
      await canceled;
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isTrue);
      await body.close();
    },
  );

  test(
    'guard invalidates before preparation completes and blocks dispatch',
    () async {
      print('[session guard] switch during preparation blocks outgoing sends');
      final guard = SessionGuard('A-1');
      final preparation = Completer<void>();
      var sends = 0;
      final result = guard.run<int>((token) async {
        await preparation.future;
        guard.check();
        sends++;
        return 1;
      });
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      guard.invalidate();
      expect(guard.isActive, isFalse);
      await canceled;
      preparation.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sends, 0);
      await expectLater(
        guard.run<int>((_) async => 2),
        throwsA(isA<OperationCanceled>()),
      );
    },
  );

  test(
    'uncooperative late payload and sensitive error are never returned',
    () async {
      print(
        '[session guard] public cancellation does not wait for uncooperative I/O',
      );
      final guard = SessionGuard('A-1');
      final payload = Completer<String>();
      final error = Completer<String>();
      final first = guard.run<String>((_) => payload.future);
      final second = guard.run<String>((_) => error.future);
      final checks = <Future<void>>[
        expectLater(
          first,
          throwsA(
            isA<OperationCanceled>().having((e) => e.body, 'body', isNull),
          ),
        ),
        expectLater(
          second,
          throwsA(
            isA<OperationCanceled>().having(
              (e) => e.details,
              'details',
              isNull,
            ),
          ),
        ),
      ];
      guard.invalidate();
      await Future.wait(checks).timeout(const Duration(seconds: 1));
      payload.complete('A private result');
      error.completeError(
        const ApiException('A private error', body: 'A private body'),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('session cancellation never cancels a shared caller token', () async {
    print('[session guard] tokens are linked in one direction only');
    final a = SessionGuard('A-1');
    final b = SessionGuard('B-1');
    final caller = CancellationToken();
    final pending = Completer<int>();
    final result = a.run<int>((_) => pending.future, cancellation: caller);
    final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
    a.invalidate();
    await canceled;
    expect(caller.isCanceled, isFalse);
    expect(await b.run<int>((_) async => 3, cancellation: caller), 3);
    pending.complete(1);
  });

  test(
    'caller cancellation settles public work and detaches completed operations',
    () async {
      final guard = SessionGuard('A-1');
      final caller = CancellationToken();
      final pending = Completer<int>();
      final result = guard.run<int>(
        (_) => pending.future,
        cancellation: caller,
      );
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      caller.cancel();
      await canceled;
      expect(guard.isActive, isTrue);
      final operation = guard.register();
      expect(await operation.run<int>((_) async => 1), 1);
      guard.invalidate();
      expect(operation.token.isCanceled, isFalse);
      pending.complete(2);
    },
  );

  test(
    'all cancellation callbacks and operation cleanups run even if one throws',
    () async {
      print('[session guard] throwing callback cannot interrupt cleanup');
      final guard = SessionGuard('A-1');
      final first = guard.register();
      final second = guard.register();
      var attempted = 0;
      first.token.onCancel(() => throw StateError('callback failed'));
      first.token.onCancel(() => attempted++);
      second.token.onCancel(() => attempted++);
      guard.invalidate();
      guard.invalidate();
      expect(attempted, 2);
      expect(guard.cleanupErrors, hasLength(1));
      expect(second.token.isCanceled, isTrue);
    },
  );

  test(
    'guarded transport blocks every retry send after invalidation',
    () async {
      final guard = SessionGuard('A-1');
      final api = FakeTransport()..addJson(<String, Object?>{'owner': 'A'});
      final transport = GuardedVmodalTransport(guard, api);
      final request = VmodalRequest(
        method: 'GET',
        uri: Uri.parse('https://gateway.test/search'),
      );
      final response = await transport.send(request);
      expect(await readBounded(response, 100), isNotEmpty);
      guard.invalidate();
      await expectLater(
        transport.send(request),
        throwsA(isA<OperationCanceled>()),
      );
      expect(api.requests, hasLength(1));
      expect(request.cancellation.isCanceled, isFalse);
    },
  );

  test(
    'late response body is disposed after public transport cancellation',
    () async {
      final guard = SessionGuard('A-1');
      final pending = Completer<VmodalResponse>();
      final body = StreamController<List<int>>();
      var disposed = false;
      body.onCancel = () => disposed = true;
      final api = HandlerTransport((_) => pending.future);
      final result = GuardedVmodalTransport(guard, api).send(
        VmodalRequest(
          method: 'GET',
          uri: Uri.parse('https://gateway.test/search'),
        ),
      );
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      guard.invalidate();
      await canceled;
      pending.complete(VmodalResponse(statusCode: 200, body: body.stream));
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isTrue);
      await body.close();
    },
  );

  test(
    'paused stream and replaced handlers cannot deliver buffered A events',
    () async {
      print(
        '[session guard] delivery fence survives pause and handler replacement',
      );
      final guard = SessionGuard('A-1');
      final source = StreamController<int>(sync: true);
      final values = <int>[];
      final errors = <Object>[];
      final done = Completer<void>();
      final subscription = guard
          .guardStream(source.stream)
          .listen(values.add, onError: errors.add, onDone: done.complete);
      subscription.pause();
      source.add(7);
      subscription.onData(values.add);
      subscription.onError(errors.add);
      guard.invalidate();
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 1));
      expect(values, isEmpty);
      expect(errors, hasLength(1));
      expect(errors.single, isA<OperationCanceled>());
      await subscription.cancel();
      await source.close();
    },
  );

  test(
    'reentrant invalidation from a stream callback closes cleanly',
    () async {
      final guard = SessionGuard('A-1');
      final source = StreamController<int>(sync: true);
      final values = <int>[];
      final errors = <Object>[];
      final done = Completer<void>();
      guard
          .guardStream(source.stream)
          .listen(
            (value) {
              values.add(value);
              guard.invalidate();
            },
            onError: errors.add,
            onDone: done.complete,
          );
      source.add(1);
      source.add(2);
      await done.future.timeout(const Duration(seconds: 1));
      expect(values, <int>[1]);
      expect(errors.single, isA<OperationCanceled>());
      await source.close();
    },
  );

  test(
    'response consumption stops promptly if source stream never finishes',
    () async {
      final guard = SessionGuard('A-1');
      final source = StreamController<List<int>>();
      final api = FakeTransport()
        ..addResponse(VmodalResponse(statusCode: 200, body: source.stream));
      final response = await GuardedVmodalTransport(guard, api).send(
        VmodalRequest(
          method: 'GET',
          uri: Uri.parse('https://gateway.test/search'),
        ),
      );
      final result = readBounded(response, 100);
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      guard.invalidate();
      await canceled.timeout(const Duration(seconds: 1));
      await source.close();
    },
  );

  test(
    'signed PUT progress and completion are dropped after invalidation',
    () async {
      print('[session guard] signed storage uses same originating activation');
      final guard = SessionGuard('A-1');
      final signed = DelayedSignedTransport();
      final progress = <UploadProgress>[];
      final caller = CancellationToken();
      final source = UploadSource(
        fileName: 'a.mp4',
        contentLength: 1,
        opener: () => Stream<List<int>>.value(<int>[1]),
      );
      final transport = GuardedSignedUploadTransport(guard, signed);
      final result = transport.upload(
        source: source,
        url: Uri.parse('https://storage.test/signed'),
        cancellation: caller,
        onProgress: progress.add,
      );
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      guard.invalidate();
      await canceled;
      signed.emit!(const UploadProgress(1, 1));
      signed.pending.complete(const SignedUploadResult(statusCode: 200));
      await Future<void>.delayed(Duration.zero);
      expect(progress, isEmpty);
      expect(caller.isCanceled, isFalse);
      await expectLater(
        transport.upload(
          source: source,
          url: Uri.parse('https://storage.test/signed'),
          cancellation: caller,
        ),
        throwsA(isA<OperationCanceled>()),
      );
      expect(signed.calls, 1);
    },
  );

  test(
    'client attempts both transport closes and returns same cleanup Future',
    () async {
      final api = FailingCloseTransport();
      final signed = FakeSignedUploadTransport();
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'same-key'),
        transport: api,
        signedUploadTransport: signed,
      );
      Future<void>? reentrant;
      api.onClose = () => reentrant = client.close();
      final first = client.close();
      final second = client.close();
      expect(identical(first, second), isTrue);
      expect(identical(first, reentrant), isTrue);
      await expectLater(first, throwsA(isA<StateError>()));
      expect(api.closeCalls, 1);
      expect(signed.closeCalls, 1);
    },
  );
}
