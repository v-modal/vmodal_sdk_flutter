import 'auth_adapter.dart';
import 'user_collection.dart';

class VmodalCredential {
  const VmodalCredential({
    required this.apiToken,
    required this.expiresAt,
    required this.firebaseUid,
    required this.vmodalUserId,
    required this.collectionUserId,
    required this.allowed,
    required this.permissions,
  });
  final String? apiToken, firebaseUid, vmodalUserId, collectionUserId;
  final DateTime? expiresAt;
  final bool allowed;
  final Set<String> permissions;

  factory VmodalCredential.fromJson(Map<String, Object?> data) {
    final raw = data['expires_at'];
    return VmodalCredential(
      apiToken: data['api_token'] as String?,
      expiresAt: raw is String ? DateTime.tryParse(raw)?.toUtc() : null,
      firebaseUid: data['firebase_uid'] as String?,
      vmodalUserId: data['vmodal_user_id'] as String?,
      collectionUserId: data['collection_user_id'] as String?,
      allowed: data['allowed'] == true,
      permissions: (data['permissions'] as List? ?? [])
          .whereType<String>()
          .toSet(),
    );
  }

  void validate(AppUser user, DateTime now, {VmodalCredential? previous}) {
    if (!allowed) throw const CredentialDenied();
    if (firebaseUid != user.uid ||
        vmodalUserId == null ||
        vmodalUserId!.isEmpty ||
        collectionUserId == null ||
        apiToken == null ||
        apiToken!.trim().isEmpty ||
        expiresAt == null ||
        !expiresAt!.isAfter(now.toUtc()) ||
        (previous != null &&
            (previous.vmodalUserId != vmodalUserId ||
                previous.collectionUserId != collectionUserId))) {
      throw const CredentialDenied();
    }
    userCollection(collectionUserId!);
    if (!permissions.contains('library:read')) {
      throw const CredentialDenied();
    }
  }
}

class CredentialDenied implements Exception {
  const CredentialDenied();
  @override
  String toString() => 'Access to this library is unavailable.';
}

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
  'api_token': null,
  'expires_at': null,
  'firebase_uid': null,
  'vmodal_user_id': null,
  'collection_user_id': null,
  'allowed': false,
  'permissions': <String>[],
};
