import 'config.dart';
import 'errors.dart';
import 'http.dart';
import 'models.dart';
import 'resources.dart';
import 'transport.dart';
import 'upload.dart';

const String vmodalSdkVersion = '1.0.0';

class VmodalClient {
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

  final SdkConfig config;
  final VmodalTransport transport;
  final SignedUploadTransport signedUploadTransport;
  late final VmodalHttp http;
  late final AuthResource auth;
  late final SearchesResource searches;
  late final CollectionsResource collections;
  late final IndexesResource indexes;
  late final AdminResource admin;
  late final R2Resource r2;
  late final ImagesResource images;
  final GDriveResource gdrive = GDriveResource();
  final SqlResource sql = SqlResource();
  bool _closed = false;

  Future<HealthResponse> health({CancellationToken? cancellation}) =>
      auth.health(cancellation: cancellation);

  Future<bool> authCheck({CancellationToken? cancellation}) =>
      auth.authCheck(cancellation: cancellation);

  static Future<VmodalClient> fromEnvironment(
    Map<String, String> env, {
    VmodalTransport? transport,
    SignedUploadTransport? signedUploadTransport,
    bool resolveIdentity = true,
    DelayStrategy? delay,
  }) async {
    final config = SdkConfig.fromEnvironment(env);
    var client = VmodalClient(
      config: config,
      transport: transport,
      signedUploadTransport: signedUploadTransport,
      delay: delay,
    );
    if (!resolveIdentity || config.normalizedUserId.isNotEmpty) return client;
    final profile = await client.auth.me();
    final userId = profile.userId?.trim() ?? '';
    if (userId.isEmpty) {
      await client.close();
      throw const AuthException('auth/me returned no user_id');
    }
    final resolved = config.copyWith(
      userId: userId,
      tenantId: profile.tenantId ?? '',
      email: profile.email ?? '',
    );
    client = VmodalClient(
      config: resolved,
      transport: transport,
      signedUploadTransport: signedUploadTransport,
      delay: delay,
    );
    return client;
  }

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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await transport.close();
    await signedUploadTransport.close();
  }
}
