import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'transport.dart';
import 'upload.dart';

/// One immutable activation lease shared by preparation, I/O and delivery.
///
/// This is an internal mechanism; restricted operations expose neither the
/// guard nor their underlying transports to applications.
class SessionGuard {
  SessionGuard(this.sessionId);

  final String sessionId;
  bool _active = true;
  final Set<SessionOperation> _operations = <SessionOperation>{};
  final List<Object> _cleanupErrors = <Object>[];

  bool get isActive => _active;
  List<Object> get cleanupErrors => List<Object>.unmodifiable(_cleanupErrors);

  void check() {
    if (!_active) throw const OperationCanceled();
  }

  /// Detaches all work before invoking cancellation callbacks, synchronously.
  void invalidate({void Function()? beforeCancel}) {
    if (!_active) return;
    _active = false;
    final operations = List<SessionOperation>.of(_operations);
    _operations.clear();
    // Internal ownership is retired before any transport/user cancellation
    // callback can reenter the manager or inspect a captured provider.
    try {
      beforeCancel?.call();
    } on Object {
      _cleanupErrors.add(const TransportException());
    }
    for (final operation in operations) {
      try {
        operation.token.cancel();
      } on Object {
        _cleanupErrors.add(const TransportException());
      } finally {
        operation.finish();
      }
    }
  }

  SessionOperation register({CancellationToken? cancellation}) {
    check();
    final operation = SessionOperation._(this);
    _operations.add(operation);
    operation._removeCaller = cancellation?.onCancel(operation.token.cancel);
    return operation;
  }

  Future<T> run<T>(
    Future<T> Function(CancellationToken cancellation) work, {
    CancellationToken? cancellation,
  }) {
    try {
      return register(cancellation: cancellation).run(work);
    } on Object catch (error, stack) {
      return Future<T>.error(error, stack);
    }
  }

  /// Checks at listener delivery, including events buffered while paused.
  Stream<T> guardStream<T>(
    Stream<T> source, {
    CancellationToken? cancellation,
  }) => _SessionStream<T>(this, source, cancellation);
}

/// Reserved synchronously, before constructing an eager upload task.
class SessionOperation {
  SessionOperation._(this._guard);

  final SessionGuard _guard;
  final CancellationToken token = CancellationToken();
  void Function()? _removeCaller;
  void Function()? _removeCancel;
  bool _finished = false;
  bool _started = false;

  void check() {
    _guard.check();
    token.throwIfCanceled();
  }

  /// Settles cancellation promptly even if [work] never cooperates.
  /// Late errors are observed; an optional disposer releases late results.
  Future<T> run<T>(
    Future<T> Function(CancellationToken cancellation) work, {
    void Function(T value)? disposeLate,
  }) {
    if (_started || _finished) {
      return Future<T>.error(const OperationCanceled());
    }
    _started = true;
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) result.completeError(const OperationCanceled());
      finish();
    }

    _removeCancel = token.onCancel(cancel);
    try {
      check();
      // No await or host callback between the lease check and invocation.
      final pending = work(token);
      unawaited(
        pending.then<void>(
          (T value) {
            if (result.isCompleted || !_guard.isActive || token.isCanceled) {
              try {
                disposeLate?.call(value);
              } on Object {
                _guard._cleanupErrors.add(const TransportException());
              }
              cancel();
              return;
            }
            result.complete(value);
            finish();
          },
          onError: (Object error, StackTrace stack) {
            if (!result.isCompleted) {
              if (!_guard.isActive || token.isCanceled) {
                result.completeError(const OperationCanceled());
              } else {
                result.completeError(error, stack);
              }
            }
            finish();
          },
        ),
      );
    } on Object catch (error, stack) {
      if (!result.isCompleted) {
        result.completeError(
          !_guard.isActive || token.isCanceled
              ? const OperationCanceled()
              : error,
          stack,
        );
      }
      finish();
    }
    return result.future;
  }

  /// Detaches all registry and caller-token listeners on every terminal path.
  void finish() {
    if (_finished) return;
    _finished = true;
    _removeCaller?.call();
    _removeCancel?.call();
    _guard._operations.remove(this);
  }
}

class _SessionStream<T> extends Stream<T> {
  _SessionStream(this.guard, this.source, this.cancellation);

  final SessionGuard guard;
  final Stream<T> source;
  final CancellationToken? cancellation;

  @override
  bool get isBroadcast => source.isBroadcast;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    SessionOperation operation;
    try {
      operation = guard.register(cancellation: cancellation);
    } on Object catch (error, stack) {
      // A response may have completed before invalidation but remained
      // unconsumed. Even this late listener must dispose its captured source.
      try {
        final discarded = source.listen((_) {}, onError: (Object _) {});
        unawaited(
          Future<void>.sync(discarded.cancel).catchError((Object _) {
            guard._cleanupErrors.add(const TransportException());
          }),
        );
      } on Object {
        guard._cleanupErrors.add(const TransportException());
      }
      return Stream<T>.error(error, stack).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    StreamSubscription<T>? upstream;
    var stopped = false;
    var canceledDelivered = false;
    void Function(T)? listenerData = onData;
    Function? listenerError = onError;
    void Function()? listenerDone = onDone;
    void Function() removeCancel = () {};
    late final StreamController<T> output;
    void stop() {
      if (stopped) return;
      stopped = true;
      removeCancel();
      operation.finish();
      final subscription = upstream;
      if (subscription != null) {
        unawaited(
          Future<void>.sync(subscription.cancel).catchError((Object error) {
            guard._cleanupErrors.add(const TransportException());
          }),
        );
      }
    }

    output = StreamController<T>(
      sync: true,
      onCancel: stop,
      onPause: () => upstream?.pause(),
      onResume: () => upstream?.resume(),
    );
    removeCancel = operation.token.onCancel(() {
      if (stopped) return;
      stop();
      // Invalidation may be reentrant from the user's onData callback.
      scheduleMicrotask(() {
        if (output.isClosed) return;
        output.addError(const OperationCanceled());
        unawaited(output.close());
      });
    });
    // A paused output may hold events accepted before invalidation. Checking
    // inside these callbacks ensures those events never reach the listener.
    // Ownership is transferred to the returned subscription wrapper.
    // ignore: cancel_subscriptions
    final downstream = output.stream.listen(
      (T value) {
        if (guard.isActive && !operation.token.isCanceled) {
          listenerData?.call(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        final stale = !guard.isActive || operation.token.isCanceled;
        if (stale && canceledDelivered) return;
        if (stale) canceledDelivered = true;
        final safe = stale ? const OperationCanceled() : error;
        final handler = listenerError;
        if (handler is void Function(Object, StackTrace)) {
          handler(safe, stack);
        } else if (handler is void Function(Object)) {
          handler(safe);
        } else {
          Zone.current.handleUncaughtError(safe, stack);
        }
      },
      onDone: () {
        removeCancel();
        stop();
        listenerDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    if (!stopped) {
      upstream = source.listen(
        (T value) {
          if (!stopped) output.add(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!stopped) output.addError(error, stack);
        },
        onDone: () {
          if (!stopped) unawaited(output.close());
        },
      );
      // A synchronous source/listener can invalidate during listen itself.
      if (stopped) {
        unawaited(
          Future<void>.sync(upstream.cancel).catchError((Object error) {
            guard._cleanupErrors.add(const TransportException());
          }),
        );
      }
    }
    return _SessionSubscription<T>(
      downstream,
      (handler) => listenerData = handler,
      (handler) => listenerError = handler,
      (handler) => listenerDone = handler,
    );
  }
}

// Keep the delivery fence when a caller changes a subscription's callbacks.
class _SessionSubscription<T> implements StreamSubscription<T> {
  _SessionSubscription(
    this.delegate,
    this.setData,
    this.setError,
    this.setDone,
  );

  final StreamSubscription<T> delegate;
  final void Function(void Function(T)?) setData;
  final void Function(Function?) setError;
  final void Function(void Function()?) setDone;

  @override
  Future<void> cancel() => delegate.cancel();
  @override
  bool get isPaused => delegate.isPaused;
  @override
  void pause([Future<void>? resumeSignal]) => delegate.pause(resumeSignal);
  @override
  void resume() => delegate.resume();
  @override
  void onData(void Function(T)? handleData) => setData(handleData);
  @override
  void onError(Function? handleError) => setError(handleError);
  @override
  void onDone(void Function()? handleDone) => setDone(handleDone);
  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final result = Completer<E>();
    onDone(() => result.complete(futureValue));
    onError((Object error, StackTrace stack) {
      unawaited(
        cancel().then(
          (_) => result.completeError(error, stack),
          onError: (Object _, StackTrace _) =>
              result.completeError(error, stack),
        ),
      );
    });
    return result.future;
  }
}

/// Fences every gateway attempt and both request and response byte streams.
class GuardedVmodalTransport implements VmodalTransport {
  GuardedVmodalTransport(this.guard, this.delegate);

  final SessionGuard guard;
  final VmodalTransport delegate;
  Future<void>? _closeFuture;

  @override
  Future<VmodalResponse> send(VmodalRequest request) {
    SessionOperation operation;
    try {
      operation = guard.register(cancellation: request.cancellation);
    } on Object catch (error, stack) {
      return Future<VmodalResponse>.error(error, stack);
    }
    VmodalResponse? originalResponse;
    return operation.run<VmodalResponse>((CancellationToken token) {
      final captured = VmodalRequest(
        method: request.method,
        uri: request.uri,
        headers: Map<String, String>.unmodifiable(request.headers),
        jsonBody: request.jsonBody,
        formFields: Map<String, Object?>.unmodifiable(request.formFields),
        files: List<VmodalFilePart>.unmodifiable(
          request.files.map(
            (part) => VmodalFilePart(
              fieldName: part.fieldName,
              fileName: part.fileName,
              contentLength: part.contentLength,
              contentType: part.contentType,
              opener: () {
                guard.check();
                token.throwIfCanceled();
                return guard.guardStream(part.open(), cancellation: token);
              },
            ),
          ),
        ),
        responseMode: request.responseMode,
        cancellation: token,
      );
      operation.check();
      return delegate.send(captured).then((VmodalResponse response) {
        originalResponse = response;
        if (!guard.isActive || token.isCanceled) {
          _discardResponse(response);
          throw const OperationCanceled();
        }
        return VmodalResponse(
          statusCode: response.statusCode,
          body: guard.guardStream(
            response.body,
            cancellation: request.cancellation,
          ),
          headers: Map<String, String>.unmodifiable(response.headers),
          contentLength: response.contentLength,
        );
      });
    }, disposeLate: (_) => _discardResponse(originalResponse!));
  }

  void _discardResponse(VmodalResponse response) {
    try {
      final subscription = response.body.listen((_) {}, onError: (Object _) {});
      unawaited(
        Future<void>.sync(subscription.cancel).catchError((Object _) {
          guard._cleanupErrors.add(const TransportException());
        }),
      );
    } on Object {
      guard._cleanupErrors.add(const TransportException());
    }
  }

  @override
  Future<void> close() {
    final pending = _closeFuture;
    if (pending != null) return pending;
    final result = Completer<void>();
    _closeFuture = result.future;
    unawaited(
      Future<void>.sync(
        delegate.close,
      ).then(result.complete, onError: result.completeError),
    );
    return result.future;
  }
}

/// Signed storage attempts never resolve a replacement session or credential.
class GuardedSignedUploadTransport implements SignedUploadTransport {
  GuardedSignedUploadTransport(this.guard, this.delegate);

  final SessionGuard guard;
  final SignedUploadTransport delegate;
  Future<void>? _closeFuture;

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
    void Function(UploadProgress progress)? onProgress,
  }) => guard.run((CancellationToken token) {
    final guardedSource = UploadSource(
      fileName: source.fileName,
      contentLength: source.contentLength,
      contentType: source.contentType,
      sourceId: source.sourceId,
      versionTag: source.versionTag,
      localFile: source.localFile,
      opener: () {
        guard.check();
        token.throwIfCanceled();
        return guard.guardStream(source.open(), cancellation: token);
      },
      rangeOpener: (int offset) {
        guard.check();
        token.throwIfCanceled();
        return guard.guardStream(
          source.open(offset: offset),
          cancellation: token,
        );
      },
    );
    final capturedHeaders = Map<String, String>.unmodifiable(headers);
    guard.check();
    token.throwIfCanceled();
    return delegate.upload(
      source: guardedSource,
      url: url,
      method: method,
      offset: offset,
      length: length,
      headers: capturedHeaders,
      timeout: timeout,
      cancellation: token,
      onProgress: (UploadProgress value) {
        if (guard.isActive && !token.isCanceled) onProgress?.call(value);
      },
    );
  }, cancellation: cancellation);

  @override
  Future<void> close() {
    final pending = _closeFuture;
    if (pending != null) return pending;
    final result = Completer<void>();
    _closeFuture = result.future;
    unawaited(
      Future<void>.sync(
        delegate.close,
      ).then(result.complete, onError: result.completeError),
    );
    return result.future;
  }
}

/// Single-isolate commit barrier shared by all owner adapters and controllers.
/// An accepted non-cancelable custom-store mutation holds the namespace closed
/// to subsequent writers/readers until it finishes. Cross-isolate/process use
/// requires a storage implementation with its own transactional lock.
class OwnerCommitCoordinator {
  OwnerCommitCoordinator._();
  static final OwnerCommitCoordinator shared = OwnerCommitCoordinator._();
  final Map<String, _OwnerCommitSlot> _slots = {};

  OwnerWriterLease open(String namespace, SessionGuard guard) {
    guard.check();
    final slot = _slots.putIfAbsent(namespace, _OwnerCommitSlot.new);
    final current = slot.writer;
    if (current != null &&
        identical(current.guard, guard) &&
        !current.retired) {
      return current;
    }
    current?.retire();
    final writer = OwnerWriterLease._(slot, guard);
    slot.writer = writer;
    return writer;
  }
}

class _OwnerCommitSlot {
  OwnerWriterLease? writer;
  Future<void> tail = Future<void>.value();
}

/// A fresh activation owns this namespace; returning to A retires old A writes.
class OwnerWriterLease {
  OwnerWriterLease._(this._slot, this.guard);
  final _OwnerCommitSlot _slot;
  final SessionGuard guard;
  bool retired = false;

  void retire() => retired = true;
  void check() {
    guard.check();
    if (retired || !identical(_slot.writer, this)) {
      throw const OperationCanceled();
    }
  }

  Future<T> run<T>(Future<T> Function() work) {
    try {
      check();
    } on Object catch (error, stack) {
      return Future<T>.error(error, stack);
    }
    final pending = _slot.tail.then((_) async {
      check();
      final value = await work();
      check();
      return value;
    });
    // Observe failures without hiding them from the initiating caller.
    _slot.tail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }
}

/// Stable owner/policy envelope around existing multipart checkpoint storage.
/// The key never includes tenant credentials or the runtime session identity.
class OwnerUploadSessionStore implements UploadSessionStore {
  OwnerUploadSessionStore({
    required SessionGuard guard,
    required this.ownerKey,
    required this.scopeKey,
    required this.policyRevision,
    UploadSessionStore? delegate,
  }) : _delegate = delegate ?? UploadSessionStores.memory,
       _writer = OwnerCommitCoordinator.shared.open(
         'multipart:$scopeKey',
         guard,
       );

  final String ownerKey, scopeKey, policyRevision;
  final UploadSessionStore _delegate;
  final OwnerWriterLease _writer;

  String _key(String contractKey) => jsonEncode([scopeKey, contractKey]);

  Map<String, Object?> _snapshot(Map<String, Object?> value) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

  @override
  Future<Map<String, Object?>?> load(String key) => _writer.run(() async {
    final value = await _delegate.load(_key(key));
    _writer.check();
    if (value == null ||
        value['ownerKey'] != ownerKey ||
        value['scopeKey'] != scopeKey ||
        value['policyRevision'] != policyRevision ||
        value['contractKey'] != key ||
        value['checkpoint'] is! Map) {
      return null;
    }
    return _snapshot(Map<String, Object?>.from(value['checkpoint'] as Map));
  });

  @override
  Future<void> save(String key, Map<String, Object?> value) {
    final snapshot = _snapshot(value);
    return _writer.run(
      () => _delegate.save(_key(key), {
        'ownerKey': ownerKey,
        'scopeKey': scopeKey,
        'policyRevision': policyRevision,
        'contractKey': key,
        'checkpoint': snapshot,
      }),
    );
  }

  @override
  Future<void> remove(String key) =>
      _writer.run(() => _delegate.remove(_key(key)));
}
