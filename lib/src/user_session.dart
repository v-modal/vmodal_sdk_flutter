import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_key_provider.dart';
import 'client.dart';
import 'collection_uploads.dart';
import 'config.dart';
import 'content_scope.dart';
import 'errors.dart';
import 'models.dart';
import 'session_guard.dart';
import 'transcode.dart';
import 'transport.dart';
import 'upload.dart';
import 'utils.dart';
import 'vmodal.dart';

/// Local permitted operations. These are client guardrails, not server grants.
enum UserAction {
  discover,
  search,
  upload,
  metadata,
  indexation,
  delete,
  media,
}

/// Explicit mapping representation; opaque selectors are never prefixed.
enum ScopeRepresentation { logical, opaque }

/// A live resource minted by a validated operation. It expires on session close.
final class SessionAsset {
  SessionAsset._(
    this._sessionId,
    this._scopeKey,
    this.assetId,
    this.fileName,
    this._media,
  );
  final String _sessionId;
  final String _scopeKey;
  final String? assetId;
  final String? fileName;
  final Map<String, Object?> _media;
}

/// Safe search data; media selectors and raw service capabilities stay private.
final class SessionSearchResponse extends SearchResponse {
  SessionSearchResponse._(super.raw, Iterable<SessionAsset> assets)
    : assets = List<SessionAsset>.unmodifiable(assets);
  final List<SessionAsset> assets;
}

/// Safe upload summary and its optional owner-bound asset handle.
final class SessionUploadResponse extends VideoUploadResponse {
  SessionUploadResponse._(super.raw, this.asset);
  final SessionAsset? asset;
}

/// Live job provenance, created or discovered within an exact allowed stream.
final class SessionJob extends IndexationSubmitResponse {
  SessionJob._(super.raw, this._sessionId, this._scopeKey, this._reference);
  final String _sessionId;
  final String _scopeKey;
  final DurableJobReference _reference;
  DurableJobReference toDurableReference() => _reference;
}

/// Serializable ownership metadata, never sufficient by itself to prove a job.
final class DurableJobReference {
  const DurableJobReference({
    required this.jobId,
    required this.ownerKey,
    required this.scopeKey,
    required this.policyRevision,
  });
  final String jobId;
  final String ownerKey;
  final String scopeKey;
  final String policyRevision;
}

/// A frozen host-authenticated mapping to one exact backend stream and mode.
final class ContentMapping {
  ContentMapping._({
    required this.representation,
    required this.collectionId,
    required this.streamName,
    required this.mode,
    required Set<UserAction> actions,
    required this.collectionWide,
    this.projectId,
    this.collectionName,
  }) : actions = Set<UserAction>.unmodifiable(actions);

  factory ContentMapping.logical({
    required String projectId,
    required String collectionName,
    required String streamName,
    String mode = 'vid_file',
    Set<UserAction> actions = const <UserAction>{UserAction.search},
    bool collectionWide = false,
  }) {
    final scope = ContentScope.create(projectId, collectionName, streamName);
    return ContentMapping._(
      representation: ScopeRepresentation.logical,
      collectionId: scope.backendCollectionName,
      projectId: scope.projectId,
      collectionName: scope.collectionName,
      streamName: scope.streamName,
      mode: strRequired(mode, 'mode'),
      actions: actions,
      collectionWide: collectionWide,
    );
  }

  factory ContentMapping.opaque({
    required String collectionId,
    required String streamName,
    String mode = 'vid_file',
    Set<UserAction> actions = const <UserAction>{UserAction.search},
    bool collectionWide = false,
  }) => ContentMapping._(
    representation: ScopeRepresentation.opaque,
    collectionId: strRequired(collectionId, 'collectionId'),
    streamName: strRequired(streamName, 'streamName'),
    mode: strRequired(mode, 'mode'),
    actions: actions,
    collectionWide: collectionWide,
  );

  final ScopeRepresentation representation;
  final String collectionId;
  final String streamName;
  final String mode;
  final String? projectId;
  final String? collectionName;
  final Set<UserAction> actions;
  final bool collectionWide;

  String get _selector => jsonEncode(<Object?>[
    representation.name,
    collectionId,
    streamName,
    mode,
  ]);

  List<Object?> get _policy => <Object?>[
    _selector,
    (actions.map((value) => value.name).toList()..sort()),
    collectionWide,
  ];
}

/// Identity and policy resolved by the host from its authenticated app user.
final class UserSessionPolicy {
  UserSessionPolicy({
    required this.tenantId,
    required this.appUserId,
    required Iterable<ContentMapping> allowedContentMapping,
    this.policyRevision,
  }) : allowedContentMapping = List<ContentMapping>.unmodifiable(
         allowedContentMapping,
       ) {
    strRequired(tenantId, 'tenantId');
    strRequired(appUserId, 'appUserId');
  }

  final String tenantId;
  final String appUserId;
  final List<ContentMapping> allowedContentMapping;
  final String? policyRevision;
}

/// Immutable ownership. Stable keys deliberately exclude credential versions.
final class SessionContext {
  SessionContext._(this.serviceNamespace, UserSessionPolicy policy)
    : tenantId = policy.tenantId,
      appUserId = policy.appUserId,
      allowedContentMapping = policy.allowedContentMapping,
      policyRevision = policy.policyRevision ?? _revision(policy),
      ownerKey = jsonEncode(<String>[
        serviceNamespace,
        policy.tenantId,
        policy.appUserId,
      ]);

  final String serviceNamespace;
  final String tenantId;
  final String appUserId;
  final String policyRevision;
  final String ownerKey;
  final List<ContentMapping> allowedContentMapping;

  String scopeKey(ContentMapping mapping) => jsonEncode(<String>[
    ownerKey,
    mapping.representation.name,
    mapping.collectionId,
    mapping.streamName,
    mapping.mode,
  ]);

  /// Canonical connection namespace, including the normalized gateway path.
  static String serviceNamespaceFor(SdkConfig config) {
    final uri = Uri.parse(config.normalizedBaseUrl);
    if (uri.hasQuery || uri.hasFragment) {
      throw const ValidationException(
        'User-session service URLs cannot contain a query or fragment',
      );
    }
    return uri
        .replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
        .normalizePath()
        .toString();
  }

  static String _revision(UserSessionPolicy policy) {
    final mappings = policy.allowedContentMapping.map((m) => m._policy).toList()
      ..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    return sha256.convert(utf8.encode(jsonEncode(mappings))).toString();
  }
}

/// One active application identity flow using a shared tenant credential.
final class UserSessionManager {
  UserSessionManager({
    required SdkConfig config,
    required TenantCredentialSource credentialSource,
    VmodalTransport Function(SdkConfig config)? transportFactory,
    SignedUploadTransport Function(SdkConfig config)?
    signedUploadTransportFactory,
    UploadSessionStore? uploadSessionStore,
    this.onInvalidated,
  }) : _config = config,
       _credentials = credentialSource,
       _uploadSessionStore = uploadSessionStore,
       _transportFactory = transportFactory ?? HttpVmodalTransport.new,
       _signedFactory =
           signedUploadTransportFactory ??
           ((config) => IoSignedUploadTransport(config.timeout)) {
    if (config.normalizedMode != 'gateway') {
      throw const ValidationException('User sessions require gateway mode');
    }
    if (credentialSource.serviceNamespace !=
        SessionContext.serviceNamespaceFor(config)) {
      throw const ValidationException(
        'Credential service binding does not match',
      );
    }
  }

  final SdkConfig _config;
  final TenantCredentialSource _credentials;
  final UploadSessionStore? _uploadSessionStore;
  final VmodalTransport Function(SdkConfig) _transportFactory;
  final SignedUploadTransport Function(SdkConfig) _signedFactory;
  final void Function(UserSession session)? onInvalidated;
  static final Expando<bool> _usedTransports = Expando<bool>(
    'session transports',
  );
  final List<Object> _cleanupErrors = <Object>[];
  List<Object> get cleanupErrors => List<Object>.unmodifiable(_cleanupErrors);
  UserSession? _current;
  int _ticket = 0;
  bool _closed = false;
  Future<void>? _closeFuture;

  UserSession? get current => _current?.isActive == true ? _current : null;

  Future<UserSession> openUserSession({
    required String tenantId,
    required String appUserId,
    required Iterable<ContentMapping> allowedContentMapping,
    String? policyRevision,
  }) {
    final policy = UserSessionPolicy(
      tenantId: tenantId,
      appUserId: appUserId,
      allowedContentMapping: allowedContentMapping,
      policyRevision: policyRevision,
    );
    return openResolvedSession(() async => policy);
  }

  /// Invalidates the outgoing user before resolving any new identity or policy.
  Future<UserSession> openResolvedSession(
    Future<UserSessionPolicy> Function() resolve,
  ) async {
    if (_closed) throw const OperationCanceled();
    final ticket = ++_ticket;
    final old = _current;
    _current = null;
    if (old != null) _observeClose(old.close());
    _checkTicket(ticket);
    final policy = await resolve();
    _checkTicket(ticket);
    if (policy.tenantId != _credentials.tenantId) {
      throw const ValidationException(
        'Credential tenant binding does not match',
      );
    }
    final context = SessionContext._(
      SessionContext.serviceNamespaceFor(_config),
      policy,
    );
    final selectors = <String>{};
    for (final mapping in context.allowedContentMapping) {
      if (!selectors.add(mapping._selector)) {
        throw const ValidationException('Duplicate content mapping');
      }
    }
    final id = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    final guard = SessionGuard(id);
    final provider = _credentials.createProvider(
      isActive: () => guard.isActive,
    );
    final config = SdkConfig(
      baseUrl: _config.baseUrl,
      timeout: _config.timeout,
      idleTimeout: _config.idleTimeout,
      maxRetries: _config.maxRetries,
      apiKeyProvider: provider,
    );
    VmodalTransport? gateway;
    SignedUploadTransport? signed;
    try {
      gateway = _transportFactory(config);
      if (_usedTransports[gateway] == true) {
        gateway = null;
        throw const ValidationException('Session transports must be distinct');
      }
      _usedTransports[gateway] = true;
      _checkTicket(ticket);
      signed = _signedFactory(config);
      if (_usedTransports[signed] == true) {
        signed = null;
        throw const ValidationException('Session transports must be distinct');
      }
      _usedTransports[signed] = true;
      _checkTicket(ticket);
      final client = VmodalClient(
        config: config,
        transport: GuardedVmodalTransport(guard, gateway),
        signedUploadTransport: GuardedSignedUploadTransport(guard, signed),
      );
      final session = UserSession._(
        context,
        _credentials.expectedPrincipal,
        guard,
        provider,
        client,
        _uploadSessionStore,
        (session) {
          if (identical(_current, session) && ticket == _ticket) {
            _current = null;
          }
          onInvalidated?.call(session);
        },
      );
      _checkTicket(ticket);
      _current = session;
      return session;
    } on Object {
      guard.invalidate();
      provider.close();
      if (gateway != null) _observeClose(Future<void>.sync(gateway.close));
      if (signed != null) _observeClose(Future<void>.sync(signed.close));
      rethrow;
    }
  }

  Future<void> logout() {
    ++_ticket;
    final old = _current;
    _current = null;
    return old?.close() ?? Future<void>.value();
  }

  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    final done = Completer<void>();
    _closeFuture = done.future;
    _closed = true;
    unawaited(logout().then(done.complete, onError: done.completeError));
    return done.future;
  }

  void _checkTicket(int ticket) {
    if (_closed || ticket != _ticket) throw const OperationCanceled();
  }

  void _observeClose(Future<void> future) {
    unawaited(
      future.catchError((Object _) {
        _cleanupErrors.add(const TransportException());
      }),
    );
  }
}

/// Private resources and a fresh runtime lease for one app-user activation.
final class UserSession {
  UserSession._(
    this.context,
    this._expectedPrincipal,
    this._guard,
    this._provider,
    this._client,
    this._uploadStore,
    this._onInvalidated,
  );

  final SessionContext context;
  final String _expectedPrincipal;
  final SessionGuard _guard;
  final MutableApiKeyProvider _provider;
  final VmodalClient _client;
  final void Function(UserSession) _onInvalidated;
  final UploadSessionStore? _uploadStore;
  final Set<SessionAsset> _assets = <SessionAsset>{};
  final Set<SessionJob> _jobs = <SessionJob>{};
  final List<Object> _cleanupErrors = <Object>[];
  List<Object> get cleanupErrors => List<Object>.unmodifiable(_cleanupErrors);
  Future<void>? _closeFuture;

  String get sessionId => _guard.sessionId;
  bool get isActive => _guard.isActive;

  /// Resolves the tenant principal without turning it into app-user identity.
  Future<void> verifyPrincipal(
    String expectedPrincipal, {
    CancellationToken? cancellation,
  }) => _run((token) async {
    if (expectedPrincipal != _expectedPrincipal) {
      throw const ValidationException(
        'Tenant principal binding does not match',
      );
    }
    final profile = await _client.auth.me(cancellation: token);
    _guard.check();
    if (profile.userId != _expectedPrincipal) {
      throw const ValidationException('Tenant principal does not match');
    }
  }, cancellation: cancellation);

  /// Discovery returns mapping selectors only, with no tenant metadata or count.
  Future<List<ContentMapping>> listCollections({
    CancellationToken? cancellation,
  }) {
    _guard.check();
    final mapped = context.allowedContentMapping
        .where((m) => m.actions.contains(UserAction.discover))
        .toList();
    return _run((token) async {
      final response = await _client.collections.listGroups(
        cancellation: token,
      );
      _guard.check();
      return List<ContentMapping>.unmodifiable(
        mapped.where(
          (mapping) => response.data.any(
            (row) =>
                row.groupName == mapping.collectionId &&
                row.mode == mapping.mode,
          ),
        ),
      );
    }, cancellation: cancellation);
  }

  Future<T> _run<T>(
    Future<T> Function(CancellationToken) work, {
    CancellationToken? cancellation,
  }) => _guard.run(
    (token) => _safeWork(() => work(token)),
    cancellation: cancellation,
  );

  UserScope scope(ContentMapping requested) {
    _guard.check();
    final allowed = context.allowedContentMapping.where(
      (m) => m._selector == requested._selector,
    );
    if (allowed.isEmpty) {
      throw const ValidationException('Scope is not allowed');
    }
    return UserScope._(this, allowed.first);
  }

  /// Invalidates synchronously; callbacks and asynchronous disposal follow.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    final done = Completer<void>();
    _closeFuture = done.future;
    _guard.invalidate(
      beforeCancel: () {
        _provider.close();
        _assets.clear();
        _jobs.clear();
      },
    );
    _cleanupErrors.addAll(_guard.cleanupErrors);
    // Initiate captured resource disposal before notifying the host. The
    // callback may synchronously open a newer session or reenter close().
    final closing = Future<void>.sync(_client.close);
    try {
      _onInvalidated(this);
    } on Object {
      _cleanupErrors.add(
        const SdkException('Session notification cleanup failed'),
      );
    }
    unawaited(
      closing.then(
        done.complete,
        onError: (Object _, StackTrace _) {
          const failure = TransportException();
          _cleanupErrors.add(failure);
          done.completeError(failure);
        },
      ),
    );
    return done.future;
  }
}

/// An owner-bound host storage barrier, retired by logout or host deactivation.
/// Host code must capture its path/payload and check before publishing files.
final class SessionStorageLease {
  SessionStorageLease._(this._writer);
  final OwnerWriterLease _writer;
  String get sessionId => _writer.guard.sessionId;
  void check() => _writer.check();
  void retire() => _writer.retire();
  Future<T> run<T>(Future<T> Function() work) =>
      _writer.guard.run((_) => _writer.run(work));
}

/// Restricted operations bound to a frozen mapping and originating session.
final class UserScope {
  UserScope._(this._session, this.mapping);

  final UserSession _session;
  final ContentMapping mapping;
  late final OwnerUploadSessionStore _uploadStore = OwnerUploadSessionStore(
    guard: _session._guard,
    ownerKey: _session.context.ownerKey,
    scopeKey: scopeKey,
    policyRevision: _session.context.policyRevision,
    delegate: _session._uploadStore,
  );
  String get sessionId => _session.sessionId;
  String get scopeKey => _session.context.scopeKey(mapping);

  /// A captured owner barrier for host archive writes. It shares the session
  /// lifetime and never exposes a transport, credential or mutable guard.
  SessionStorageLease get storageLease {
    _session._guard.check();
    return SessionStorageLease._(
      OwnerCommitCoordinator.shared.open(
        'archive:${jsonEncode([_session.context.ownerKey, mapping.collectionId])}',
        _session._guard,
      ),
    );
  }

  void _allow(UserAction action, String mode) {
    _session._guard.check();
    if (!mapping.actions.contains(action) || mode != mapping.mode) {
      throw const ValidationException('Action or mode is not allowed');
    }
  }

  bool _matches(Map<String, Object?> row, {required bool requireSelectors}) {
    for (final field in <String, String>{
      'group_name': mapping.collectionId,
      'stream_name': mapping.streamName,
      'mode': mapping.mode,
    }.entries) {
      if (!row.containsKey(field.key)) {
        if (requireSelectors) return false;
      } else if (row[field.key] != field.value) {
        return false;
      }
    }
    return true;
  }

  SessionAsset _asset(Map<String, Object?> row) {
    _session._guard.check();
    final file =
        stringValueOrNull(row['video_filename']) ??
        stringValueOrNull(row['filename_sanitized']) ??
        stringValueOrNull(row['filename']) ??
        stringValueOrNull(row['file_name']);
    final safeFile =
        file != null &&
            !file.contains('/') &&
            !file.contains('\\') &&
            file != '.' &&
            file != '..'
        ? file
        : null;
    final asset = SessionAsset._(
      sessionId,
      scopeKey,
      stringValueOrNull(row['asset_id']),
      safeFile,
      _fields(row, const <String>{
        'modality',
        'ts_unix_13digits',
        'playback_offset_ms',
        'video_time_seconds',
        'timestamp_seconds',
      }),
    );
    _session._assets.add(asset);
    return asset;
  }

  SessionJob _job(Map<String, Object?> row) {
    _session._guard.check();
    final id = strRequired('${row['job_id'] ?? ''}', 'job_id');
    final job = SessionJob._(
      _fields(row, _jobFields),
      sessionId,
      scopeKey,
      DurableJobReference(
        jobId: id,
        ownerKey: _session.context.ownerKey,
        scopeKey: scopeKey,
        policyRevision: _session.context.policyRevision,
      ),
    );
    _session._jobs.add(job);
    return job;
  }

  void _checkAsset(SessionAsset asset) {
    _session._guard.check();
    if (asset._sessionId != sessionId ||
        asset._scopeKey != scopeKey ||
        !_session._assets.contains(asset)) {
      throw const ValidationException('Asset provenance does not match');
    }
  }

  /// Every batch member must come from this exact live scope before dispatch.
  Future<CollectionAddAssetsResponse> addAssets(
    List<SessionAsset> assets, {
    ScopedAddAssetsOptions options = const ScopedAddAssetsOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.metadata, options.mode);
    final captured = List<SessionAsset>.of(assets);
    for (final asset in captured) {
      _checkAsset(asset);
      if (asset.assetId == null) {
        throw const ValidationException('Asset has no stable identifier');
      }
    }
    return _session._run(
      (token) async => CollectionAddAssetsResponse(
        _fields(
          (await _session._client.collections.addAssets(
            collectionId: mapping.collectionId,
            assetIds: captured.map((a) => a.assetId!).toList(),
            mode: mapping.mode,
            groupName: mapping.collectionId,
            streamName: mapping.streamName,
            cancellation: token,
          )).raw,
          const <String>{'status', 'added', 'updated'},
        ),
      ),
      cancellation: cancellation,
    );
  }

  /// Mutates a filename minted by a scoped search or completed upload.
  Future<CollectionDescriptionUpdateResponse> updateAsset(
    SessionAsset asset, {
    required ScopedAssetChanges changes,
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.metadata, changes.mode);
    _checkAsset(asset);
    if (asset.fileName == null) {
      throw const FeatureDisabled('This asset has no validated filename');
    }
    final tags = changes.tags == null
        ? null
        : List<String>.unmodifiable(changes.tags!);
    return _session._run(
      (token) async => CollectionDescriptionUpdateResponse(
        _fields(
          (await _session._client.collections.updateDescription(
            groupName: mapping.collectionId,
            mode: mapping.mode,
            streamName: mapping.streamName,
            filenameSanitized: asset.fileName!,
            description: changes.description,
            tag: tags,
            cancellation: token,
          )).raw,
          const <String>{'status', 'updated'},
        ),
      ),
      cancellation: cancellation,
    );
  }

  /// The URL grant remains private and bytes are fenced through each phase.
  Future<Uint8List> imageBytes(
    SessionAsset asset, {
    int? maxBytes,
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.media, mapping.mode);
    _checkAsset(asset);
    if (asset.fileName == null) {
      throw const FeatureDisabled('This asset has no validated media selector');
    }
    final modality = switch (mapping.mode) {
      'img_file' => 'img_raw',
      'vid_file' || 'vid_stream_day' => 'vid_img',
      _ => throw const FeatureDisabled('Media is unavailable for this mode'),
    };
    final reported = asset._media['modality'];
    if (reported != null && reported != modality) {
      throw const ValidationException(
        'Media modality does not match the scope',
      );
    }
    Object? timestamp = asset._media['ts_unix_13digits'];
    // File-video frames are relative to their source video. Day-stream media
    // requires its real epoch timestamp and cannot use this offset fallback.
    if (timestamp == null && mapping.mode == 'vid_file') {
      timestamp = VideoSearchHit(asset._media).playbackOffsetMs;
    }
    String? ts13;
    if (timestamp != null) {
      final value = '$timestamp';
      if (!RegExp(r'^\d{1,13}$').hasMatch(value)) {
        throw const ValidationException('Media timestamp is invalid');
      }
      ts13 = value.padLeft(13, '0');
    }
    if (mapping.mode != 'img_file' && ts13 == null) {
      throw const FeatureDisabled(
        'This video asset has no validated frame time',
      );
    }
    return _session._run((token) async {
      final result = await _session._client.images.getUrl(
        mode: mapping.mode,
        groupName: mapping.collectionId,
        streamName: mapping.streamName,
        modality: modality,
        filename: asset.fileName!,
        tsUnix13digits: ts13,
        cancellation: token,
      );
      _session._guard.check();
      token.throwIfCanceled();
      if (!result.found || result.urlPreSigned.isEmpty) {
        throw const FeatureDisabled('Media is unavailable');
      }
      return _session._client.images.getImageFromUrl(
        result.urlPreSigned,
        maxBytes: maxBytes,
        cancellation: token,
      );
    }, cancellation: cancellation);
  }

  /// Tenant job lists are filtered by all selectors before minting provenance.
  Future<List<SessionJob>> listIndexJobs({
    ScopedIndexJobsOptions options = const ScopedIndexJobsOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.indexation, options.mode ?? mapping.mode);
    return _session._run((token) async {
      final response = await _session._client.indexes.jobsList(
        status: options.status,
        mode: mapping.mode,
        groupName: mapping.collectionId,
        limit: options.limit,
        cancellation: token,
      );
      _session._guard.check();
      return List<SessionJob>.unmodifiable(
        objectList(response.raw['data'])
            .where(
              (row) =>
                  _matches(row, requireSelectors: true) &&
                  stringValueOrNull(row['job_id']) != null,
            )
            .map(_job),
      );
    }, cancellation: cancellation);
  }

  Future<IndexationStatusResponse> indexStatus(
    SessionJob job, {
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.indexation, mapping.mode);
    if (job._sessionId != sessionId ||
        job._scopeKey != scopeKey ||
        !_session._jobs.contains(job)) {
      throw const ValidationException('Job provenance does not match');
    }
    return _session._run((token) async {
      final response = await _session._client.indexes.indexStatus(
        job.jobId,
        cancellation: token,
      );
      if (response.jobId != job.jobId ||
          !_matches(response.raw, requireSelectors: false)) {
        throw const MalformedResponse('Job result does not match');
      }
      return IndexationStatusResponse(_fields(response.raw, _jobFields));
    }, cancellation: cancellation);
  }

  /// Rebinding needs current policy and a fresh exact scoped discovery record.
  Future<SessionJob> rebindJob(
    DurableJobReference reference, {
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.indexation, mapping.mode);
    if (reference.ownerKey != _session.context.ownerKey ||
        reference.scopeKey != scopeKey ||
        reference.policyRevision != _session.context.policyRevision) {
      throw const ValidationException('Durable job ownership does not match');
    }
    return _session._run((token) async {
      final jobs = await listIndexJobs(
        options: ScopedIndexJobsOptions(mode: mapping.mode, limit: 1000),
        cancellation: token,
      );
      _session._guard.check();
      final matches = jobs.where((job) => job.jobId == reference.jobId);
      if (matches.isEmpty) {
        throw const FeatureDisabled(
          'Job has no current scoped ownership proof',
        );
      }
      return matches.first;
    }, cancellation: cancellation);
  }

  /// Backend index deletion affects the collection, including other streams.
  Future<IndexationDeleteResponse> deleteIndex(
    String version, {
    ScopedDeleteIndexOptions options = const ScopedDeleteIndexOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.delete, options.mode);
    if (!mapping.collectionWide) {
      throw const ValidationException('Collection-wide access is required');
    }
    final request = IndexationDeleteRequest(
      mode: mapping.mode,
      groupName: mapping.collectionId,
      version: version,
      modality: options.modality,
      dryRun: options.dryRun,
      confirm: options.confirm,
    );
    return _session._run(
      (token) async => IndexationDeleteResponse(
        _fields(
          (await _session._client.indexes.deleteIndex(
            request,
            cancellation: token,
          )).raw,
          const <String>{'status', 'deleted', 'dry_run'},
        ),
      ),
      cancellation: cancellation,
    );
  }

  /// Aggregate versions require collection-wide access or an exact stream row.
  Future<GroupItem?> collectionInfo({CancellationToken? cancellation}) {
    _allow(UserAction.discover, mapping.mode);
    return _session._run((token) async {
      final response = await _session._client.collections.listGroups(
        mode: mapping.mode,
        cancellation: token,
      );
      _session._guard.check();
      for (final row in response.data) {
        if (row.groupName != mapping.collectionId || row.mode != mapping.mode) {
          continue;
        }
        if (!mapping.collectionWide &&
            row.raw['stream_name'] != mapping.streamName) {
          continue;
        }
        return GroupItem(
          _fields(row.raw, const <String>{
            'group_name',
            'mode',
            'stream_name',
            'lancedb_versions',
          }),
        );
      }
      return null;
    }, cancellation: cancellation);
  }

  Future<int?> latestVersion({CancellationToken? cancellation}) =>
      _session._run(
        (token) async =>
            (await collectionInfo(cancellation: token))?.latestLancedbVersion,
        cancellation: cancellation,
      );

  Future<SessionSearchResponse> search(
    String query, {
    ScopedSearchOptions options = const ScopedSearchOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.search, options.mode);
    final request = SearchRequest(
      queryText: query,
      queryMetadata: options.queryMetadata == null
          ? null
          : _snapshot(options.queryMetadata!) as Map<String, Object?>,
      queryMetadataText: options.queryMetadataText,
      imageQuery: options.imageQuery,
      mode: mapping.mode,
      groupName: mapping.collectionId,
      streamName: mapping.streamName,
      searchSources: List<String>.unmodifiable(options.searchSources),
      searchCombineMode: options.searchCombineMode,
      startDate: options.startDate,
      endDate: options.endDate,
      offset: options.offset,
      limit: options.limit,
      textEmbScoreMin: options.textEmbScoreMin,
      imageEmbScoreMin: options.imageEmbScoreMin,
      versionLancedb: options.versionLancedb,
    );
    return _session._run((token) async {
      final result = await _session._client.searches.searchVideo(
        request,
        cancellation: token,
      );
      _session._guard.check();
      final rows = objectList(result.raw['data'])
          .where((row) => _matches(row, requireSelectors: false))
          .map((row) => _fields(row, _searchFields))
          .toList();
      final assets = rows.map(_asset).toList();
      return SessionSearchResponse._(
        _snapshot(<String, Object?>{
              'data': rows,
              'cnt_actual': rows.length,
              'cnt_total': rows.length,
            })
            as Map<String, Object?>,
        assets,
      );
    }, cancellation: cancellation);
  }

  Future<MetadataParquetUploadResponse> uploadMetadata(
    VmodalFilePart part, {
    ScopedMetadataOptions options = const ScopedMetadataOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.metadata, options.mode);
    return _session._run((token) async {
      // Existing metadata records must bind to live scoped asset provenance.
      // A bounded immutable snapshot prevents the opener changing after validation.
      final bytes = await readBounded(
        VmodalResponse(
          statusCode: 200,
          contentLength: part.contentLength,
          body: _session._guard.guardStream(part.open(), cancellation: token),
        ),
        8 * 1024 * 1024,
        cancellation: token,
      );
      _session._guard.check();
      token.throwIfCanceled();
      final lines = utf8
          .decode(bytes)
          .split('\n')
          .where((line) => line.trim().isNotEmpty);
      if (lines.isEmpty) throw const ValidationException('Metadata is empty');
      for (final line in lines) {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, Object?>) {
          throw const ValidationException('Metadata row must be an object');
        }
        const fields = <String>{
          'filename',
          'filename_sanitized',
          'asset_id',
          'description',
          'metadata_text',
          'tags',
          'tag',
        };
        if (decoded.keys.any((key) => !fields.contains(key))) {
          throw const ValidationException('Unsupported metadata field');
        }
        final id = stringValueOrNull(decoded['asset_id']);
        final filename =
            stringValueOrNull(decoded['filename_sanitized']) ??
            stringValueOrNull(decoded['filename']);
        if (id == null && filename == null) {
          throw const ValidationException('Metadata needs a proven asset');
        }
        final proven = _session._assets.any(
          (asset) =>
              asset._sessionId == sessionId &&
              asset._scopeKey == scopeKey &&
              (id == null || asset.assetId == id) &&
              (filename == null || asset.fileName == filename),
        );
        if (!proven ||
            decoded['filename'] != null &&
                decoded['filename_sanitized'] != null &&
                decoded['filename'] != decoded['filename_sanitized']) {
          throw const ValidationException(
            'Metadata asset provenance does not match',
          );
        }
        for (final value in decoded.values) {
          if (value is! String &&
              value is! List<String> &&
              !(value is List && value.every((v) => v is String))) {
            throw const ValidationException('Unsupported metadata value');
          }
        }
      }
      final captured = VmodalFilePart.bytes(
        fieldName: part.fieldName,
        fileName: part.fileName,
        contentType: part.contentType,
        bytes: bytes,
      );
      return MetadataParquetUploadResponse(
        _fields(
          (await _session._client.collections.uploadMetadataJsonl(
            captured,
            mode: mapping.mode,
            groupName: mapping.collectionId,
            streamName: mapping.streamName,
            writeMode: options.writeMode,
            allowOverlap: options.allowOverlap,
            cancellation: token,
          )).raw,
          const <String>{'status', 'accepted', 'written', 'uploaded'},
        ),
      );
    }, cancellation: cancellation);
  }

  UploadTask<SessionUploadResponse> upload(
    UploadSource source, {
    ScopedUploadOptions options = const ScopedUploadOptions(),
  }) {
    _allow(UserAction.upload, options.mode);
    if (options.uploadOptions.sessionStore != null) {
      throw const ValidationException(
        'Use only session-owned upload checkpoints',
      );
    }
    if (options.uploadOptions.transcoder.runtimeType !=
        PassthroughVideoTranscoder) {
      throw const ValidationException(
        'Custom transcoders are not session-owned',
      );
    }
    final captured = options.uploadOptions.copyWith(
      sessionStore: _uploadStore,
      metadataTags: options.uploadOptions.metadataTags == null
          ? null
          : List<String>.unmodifiable(options.uploadOptions.metadataTags!),
    );
    final operation = _session._guard.register();
    return _SessionUploadTask<SessionUploadResponse>(_session._guard, (
      cancel,
      emit,
    ) async {
      final remove = cancel.onCancel(operation.token.cancel);
      return operation.run(
        (token) => _safeWork(() async {
          final task = _session._client.collections.videoUpload(
            source,
            collectionName: mapping.collectionId,
            subCollectionName: mapping.streamName,
            mode: mapping.mode,
            modality: options.modality,
            ttl: options.ttl,
            options: captured,
          );
          final detach = token.onCancel(task.cancel);
          final subscription = _session._guard
              .guardStream(task.progress, cancellation: token)
              .listen(emit, onError: (Object _) {});
          try {
            final result = await task.result;
            operation.check();
            final done = objectMap(result.raw['upload_done']);
            if (!_matches(done, requireSelectors: false)) {
              throw const MalformedResponse(
                'Upload result scope does not match',
              );
            }
            final safe = _fields(<String, Object?>{
              ...result.raw,
              if (done['asset_id'] is String) 'asset_id': done['asset_id'],
            }, _uploadFields);
            final asset =
                stringValueOrNull(safe['asset_id']) != null ||
                    stringValueOrNull(safe['filename']) != null
                ? _asset(safe)
                : null;
            return SessionUploadResponse._(safe, asset);
          } finally {
            detach();
            remove();
            await subscription.cancel();
          }
        }),
      );
    });
  }

  Future<SessionJob> createIndex({
    ScopedCreateIndexOptions options = const ScopedCreateIndexOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.indexation, options.mode);
    final request = IndexationSubmitRequest(
      mode: mapping.mode,
      groupName: mapping.collectionId,
      streamName: mapping.streamName,
      indexType: options.indexType,
      modality: options.modality,
      insertMode: options.insertMode,
      createIndex: options.createIndex,
      version: options.version,
      startDate: options.startDate,
      endDate: options.endDate,
      embeddingModel: options.embeddingModel,
      reProcess: options.reProcess,
      dryRun: options.dryRun,
    );
    return _session._run((token) async {
      final result = await _session._client.indexes.createIndex(
        request,
        cancellation: token,
      );
      _session._guard.check();
      if (!_matches(result.raw, requireSelectors: false)) {
        throw const MalformedResponse('Index result scope does not match');
      }
      return _job(result.raw);
    }, cancellation: cancellation);
  }

  Future<DeleteCollectionResponse> deleteCollection({
    ScopedDeleteCollectionOptions options =
        const ScopedDeleteCollectionOptions(),
    CancellationToken? cancellation,
  }) {
    _allow(UserAction.delete, options.mode);
    if (!mapping.collectionWide) {
      throw const ValidationException('Collection-wide access is required');
    }
    return _session._run(
      (token) async => DeleteCollectionResponse(
        _fields(
          (await _session._client.collections.delete(
            groupName: mapping.collectionId,
            mode: mapping.mode,
            scope: options.scope,
            dryRun: options.dryRun,
            confirm: options.confirm,
            cancellation: token,
          )).raw,
          const <String>{'status', 'deleted', 'dry_run'},
        ),
      ),
      cancellation: cancellation,
    );
  }
}

// Fence the public task's stream too: its controller may buffer events while
// the caller pauses, after the upstream guarded subscription accepted them.
final class _SessionUploadTask<T> extends UploadTask<T> {
  _SessionUploadTask(this._guard, UploadRunner<T> runner) : super.start(runner);
  final SessionGuard _guard;
  late final Future<T> _guardedResult = _guard.run(
    (_) => super.result,
    cancellation: cancellation,
  );
  @override
  Future<T> get result => _guardedResult;
  @override
  Stream<UploadProgress> get progress =>
      _guard.guardStream(super.progress, cancellation: cancellation);
}

Object? _snapshot(Object? value) {
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const ValidationException('Structured input keys must be strings');
    }
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _snapshot(v))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_snapshot));
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw const ValidationException('Structured input must contain JSON values');
}

const _searchFields = <String>{
  'asset_id',
  'filename',
  'filename_sanitized',
  'file_name',
  'video_filename',
  'title',
  'description',
  'metadata_text',
  'tags',
  'playback_offset_ms',
  'video_time_seconds',
  'timestamp_seconds',
  'distance',
  'score',
  'ts_unix_13digits',
  'modality',
};
const _uploadFields = <String>{
  'asset_id',
  'filename',
  'size_bytes',
  'uploaded',
  'upload_strategy',
  'part_size_bytes',
  'part_count',
  'parts_uploaded',
  'resumed',
  'attempt_count',
  'video_filename',
  'start_datetime_user',
  'start_ts_unix_user_ms',
  'timestamp_source',
  'reduce_size',
  'source_size_bytes',
  'temporary_file_deleted',
  'temporary_file_reused',
};
const _jobFields = <String>{'job_id', 'status', 'version', 'progress'};

// Only documented scalar display fields or homogeneous scalar lists survive.
// Extension maps and nested records never inherit the outer row's provenance.
Map<String, Object?> _fields(Map<String, Object?> row, Set<String> allowed) {
  final safe = <String, Object?>{};
  for (final key in allowed) {
    final value = row[key];
    if (value is String || value is num || value is bool) {
      safe[key] = value;
    } else if (value is List &&
        value.every((v) => v is String || v is num || v is bool)) {
      safe[key] = List<Object?>.unmodifiable(value);
    }
  }
  return Map<String, Object?>.unmodifiable(safe);
}

// Restricted errors carry no raw tenant-wide body, signed grant or cause.
Future<T> _safeWork<T>(Future<T> Function() work) async {
  try {
    return await work();
  } on OperationCanceled {
    rethrow;
  } on FeatureDisabled {
    throw const FeatureDisabled('Operation is unavailable in this scope');
  } on ValidationException {
    throw const ValidationException('Operation validation failed');
  } on AuthException {
    throw const TenantAuthException();
  } on ApiException catch (error) {
    throw ApiException('Scoped operation failed', statusCode: error.statusCode);
  } on ResponseTooLarge catch (error) {
    throw ResponseTooLarge(error.limitBytes, error.observedBytes);
  } on MalformedResponse {
    throw const MalformedResponse();
  } on FormatException {
    throw const ValidationException('Structured input is malformed');
  } on Object {
    throw const TransportException();
  }
}
