import 'dart:convert';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import 'package:framebase/data/search_gateway.dart';

class QueueTransport implements VmodalTransport {
  QueueTransport([List<Map<String, Object?>>? responses])
    : responses = responses ?? [];
  final List<Map<String, Object?>> responses;
  final List<VmodalRequest> requests = [];
  bool closed = false;
  @override
  Future<VmodalResponse> send(VmodalRequest request) async {
    request.cancellation.throwIfCanceled();
    requests.add(request);
    final data = responses.isNotEmpty
        ? responses.removeAt(0)
        : <String, Object?>{
            'user_id': 'shared-principal',
            'data': <Object?>[],
            'job_id': 'job-ready',
            'status': 'queued',
          };
    return VmodalResponse(
      statusCode: data['__status'] as int? ?? 200,
      body: Stream.value(utf8.encode(jsonEncode(data))),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<UserSession> testSession({
  String scopeId = 'scope_7K3A',
  String appUserId = 'alice',
  VmodalTransport? transport,
  bool collectionWide = true,
}) async {
  final config = SdkConfig(maxRetries: 0);
  final source = TenantCredentialSource(
    serviceNamespace: SessionContext.serviceNamespaceFor(config),
    tenantId: 'shared-tenant',
    expectedPrincipal: 'shared-principal',
    initialKey: 'same-key',
  );
  final manager = UserSessionManager(
    config: config,
    credentialSource: source,
    transportFactory: (_) => transport ?? QueueTransport(),
  );
  return manager.openUserSession(
    tenantId: 'shared-tenant',
    appUserId: appUserId,
    allowedContentMapping: [
      ContentMapping.opaque(
        collectionId: scopeId,
        streamName: archiveStream,
        actions: UserAction.values.toSet(),
        collectionWide: collectionWide,
      ),
    ],
  );
}
