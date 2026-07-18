import 'config.dart';
import 'errors.dart';
import 'http.dart';
import 'models.dart';
import 'resources.dart';
import 'transport.dart';
import 'upload.dart';

/// Version of the Dart SDK contract represented by this package.
const String vmodalSdkVersion = '1.0.0';

/// Owns configuration, transports, and feature resources for one app session.
///
/// Reuse a client while the same identity is active. Call [close] when the
/// identity changes or the app no longer needs the SDK; closing is idempotent.
class VmodalClient {
  /// Creates a client from validated [config].
  ///
  /// Custom transports are primarily useful for testing and platform-specific
  /// integrations. The client owns every supplied transport and closes it from
  /// [close].
  VmodalClient({
    required this.config,
    VmodalTransport? transport,
    SignedUploadTransport? signedUploadTransport,
    DelayStrategy? delay,
  }) : transport = transport ?? HttpVmodalTransport(config),
       signedUploadTransport =
           signedUploadTransport ?? IoSignedUploadTransport(config.timeout) {
    http = VmodalHttp(config, this.transport, delay: delay);
    auth = AuthResource(http);
    searches = SearchesResource(http);
    collections = CollectionsResource(http, this.signedUploadTransport);
    indexes = IndexesResource(http);
    admin = AdminResource(http);
    r2 = R2Resource(http);
    images = ImagesResource(http);
  }

  /// Immutable configuration used by all resources.
  final SdkConfig config;

  /// Transport used for typed SDK operations.
  final VmodalTransport transport;

  /// Transport used after the SDK obtains permission to upload media bytes.
  final SignedUploadTransport signedUploadTransport;

  /// @nodoc
  late final VmodalHttp http;

  /// Authentication and identity operations.
  late final AuthResource auth;

  /// Multimodal search operations.
  late final SearchesResource searches;

  /// Collection management and upload operations.
  late final CollectionsResource collections;

  /// Index creation, status, and deletion operations.
  late final IndexesResource indexes;

  /// Usage and service-statistics operations.
  late final AdminResource admin;

  /// Advanced signed object-upload operations.
  late final R2Resource r2;

  /// Image lookup and download operations.
  late final ImagesResource images;

  /// Compatibility surface whose methods currently throw [FeatureDisabled].
  final GDriveResource gdrive = GDriveResource();

  /// Compatibility surface whose methods currently throw [FeatureDisabled].
  final SqlResource sql = SqlResource();
  bool _closed = false;

  /// Checks service health and returns version/dependency information.
  Future<HealthResponse> health({CancellationToken? cancellation}) =>
      auth.health(cancellation: cancellation);

  /// Returns `true` when an authenticated health request succeeds.
  ///
  /// Authentication, transport, and cancellation failures are surfaced as
  /// typed [SdkException] subclasses.
  Future<bool> authCheck({CancellationToken? cancellation}) =>
      auth.authCheck(cancellation: cancellation);

  /// Creates a client from the supported environment map.
  ///
  /// Unless [resolveIdentity] is false or a user ID is already configured, the
  /// factory resolves the active profile and rebuilds the client with that
  /// identity. A profile without a user ID throws [AuthException].
  static Future<VmodalClient> fromEnvironment(
    Map<String, String> env, {
    VmodalTransport? transport,
    SignedUploadTransport? signedUploadTransport,
    bool resolveIdentity = true,
    DelayStrategy? delay,
  }) async {
    final config = SdkConfig.fromEnvironment(env);
    final client = VmodalClient(
      config: config,
      transport: transport,
      signedUploadTransport: signedUploadTransport,
      delay: delay,
    );
    if (!resolveIdentity || config.normalizedUserId.isNotEmpty) return client;
    try {
      final profile = await client.auth.me();
      final userId = profile.userId?.trim() ?? '';
      if (userId.isEmpty) {
        throw const AuthException('auth/me returned no user_id');
      }
      final resolved = config.copyWith(
        userId: userId,
        tenantId: profile.tenantId ?? '',
        email: profile.email ?? '',
      );
      return VmodalClient(
        config: resolved,
        transport: client.transport,
        signedUploadTransport: client.signedUploadTransport,
        delay: delay,
      );
    } on Object {
      await client.close();
      rethrow;
    }
  }

  /// Creates a direct-mode client for controlled development integrations.
  ///
  /// Most mobile apps should use the default gateway configuration instead.
  factory VmodalClient.unsafeDirect({
    required String baseUrl,
    required String userId,
    String tenantId = '',
    String email = '',
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 1,
    VmodalTransport? transport,
    SignedUploadTransport? signedUploadTransport,
    DelayStrategy? delay,
  }) {
    final config = SdkConfig(
      baseUrl: baseUrl,
      userId: userId,
      tenantId: tenantId,
      email: email,
      timeout: timeout,
      mode: 'direct',
      maxRetries: maxRetries,
    );
    return VmodalClient(
      config: config,
      transport: transport,
      signedUploadTransport: signedUploadTransport,
      delay: delay,
    );
  }

  /// Closes both owned transports. Repeated calls have no effect.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await transport.close();
    await signedUploadTransport.close();
  }
}
