import 'auth_adapter.dart';
import 'library_scope.dart';

class VmodalCredential {
  const VmodalCredential({
    required this.contractVersion,
    required this.sessionId,
    required this.issuedAt,
    required this.apiToken,
    required this.expiresAt,
    required this.firebaseUid,
    required this.vmodalUserId,
    required this.scopeId,
    required this.allowed,
    required this.permissions,
    this.tenantId,
    this.collectionWide = false,
  });
  final int? contractVersion;
  final String? sessionId, apiToken, firebaseUid, vmodalUserId, scopeId;
  final DateTime? issuedAt, expiresAt;
  final bool allowed;
  final Set<String> permissions;
  final String? tenantId;
  final bool collectionWide;

  /// Version 1 issuers used their VModal principal as the tenant binding.
  /// It never identifies the Firebase app user.
  String get tenantBinding => tenantId ?? vmodalUserId!;

  factory VmodalCredential.fromJson(Map<String, Object?> data) {
    final issued = data['issued_at'];
    final expires = data['expires_at'];
    final permissions = data['permissions'];
    return VmodalCredential(
      contractVersion: data['version'] is int ? data['version'] as int : null,
      sessionId: data['session_id'] is String
          ? data['session_id'] as String
          : null,
      issuedAt: issued is String ? DateTime.tryParse(issued)?.toUtc() : null,
      apiToken: data['api_token'] is String
          ? data['api_token'] as String
          : null,
      expiresAt: expires is String ? DateTime.tryParse(expires)?.toUtc() : null,
      firebaseUid: data['firebase_uid'] is String
          ? data['firebase_uid'] as String
          : null,
      vmodalUserId: data['vmodal_user_id'] is String
          ? data['vmodal_user_id'] as String
          : null,
      tenantId: data['tenant_id'] is String
          ? data['tenant_id'] as String
          : null,
      collectionWide: data['collection_wide'] == true,
      scopeId: data['scope_id'] is String ? data['scope_id'] as String : null,
      allowed: data['allowed'] == true,
      permissions: permissions is List
          ? permissions.whereType<String>().toSet()
          : <String>{},
    );
  }

  void validate(AppUser user, DateTime now, {VmodalCredential? previous}) {
    if (!allowed || !permissions.contains('library:read')) {
      throw const CredentialDenied();
    }
    try {
      validateLibraryScope(scopeId);
    } on InvalidLibraryScope {
      throw const CredentialContractError();
    }
    if (contractVersion != 1 ||
        sessionId == null ||
        sessionId!.trim().isEmpty ||
        issuedAt == null ||
        expiresAt == null ||
        !issuedAt!.toUtc().isBefore(expiresAt!.toUtc()) ||
        firebaseUid != user.uid ||
        vmodalUserId == null ||
        vmodalUserId!.trim().isEmpty ||
        apiToken == null ||
        apiToken!.trim().isEmpty ||
        (tenantId != null && tenantId!.trim().isEmpty) ||
        !expiresAt!.toUtc().isAfter(now.toUtc()) ||
        (previous != null &&
            (previous.vmodalUserId != vmodalUserId ||
                previous.tenantBinding != tenantBinding))) {
      throw const CredentialContractError();
    }
  }

  bool samePolicy(VmodalCredential other) =>
      scopeId == other.scopeId &&
      collectionWide == other.collectionWide &&
      permissions.length == other.permissions.length &&
      permissions.containsAll(other.permissions);
}

class CredentialDenied implements Exception {
  const CredentialDenied();
  @override
  String toString() => 'Access to this library is unavailable.';
}

class CredentialTransient implements Exception {
  const CredentialTransient();
}

class CredentialContractError implements Exception {
  const CredentialContractError();
}

/// Exchanges app identity for a scoped VMODAL credential.
///
/// Implementations report explicit policy denial as [CredentialDenied],
/// temporary network or issuer 5xx failures as [CredentialTransient], invalid
/// responses or configuration as [CredentialContractError], and rejected or
/// expired Firebase identity as [FirebaseIdentityExpired].
abstract interface class VmodalCredentialSource {
  Future<VmodalCredential> acquire(AppUser user, String? firebaseIdToken);
}

class MockVmodalCredentialSource implements VmodalCredentialSource {
  MockVmodalCredentialSource([List<VmodalCredential>? responses])
    : responses = responses ?? [];
  final List<VmodalCredential> responses;
  int calls = 0;
  @override
  Future<VmodalCredential> acquire(
    AppUser user,
    String? firebaseIdToken,
  ) async {
    calls++;
    if (responses.isEmpty) {
      return VmodalCredential.fromJson(
        Map<String, Object?>.from(emptyCredential),
      );
    }
    return responses.removeAt(0);
  }
}

const emptyCredential = <String, Object?>{
  'version': null,
  'session_id': null,
  'issued_at': null,
  'api_token': null,
  'expires_at': null,
  'firebase_uid': null,
  'vmodal_user_id': null,
  'scope_id': null,
  'allowed': false,
  'permissions': <String>[],
};
