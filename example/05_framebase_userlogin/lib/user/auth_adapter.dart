/// The host application owns Firebase identity. The offline implementation
/// emits the same nullable user state without loading Firebase packages.
class AppUser {
  const AppUser(this.uid, {this.email, this.label});
  final String uid;
  final String? email, label;
  String get displayName => label ?? email ?? uid;
}

/// The Firebase identity cannot be renewed without authenticating again.
class FirebaseIdentityExpired implements Exception {
  const FirebaseIdentityExpired();
}

/// Firebase token acquisition failed because of a temporary provider issue.
class FirebaseIdentityTransient implements Exception {
  const FirebaseIdentityTransient();
}

/// App implementations must translate provider-specific token failures into
/// [FirebaseIdentityExpired] or [FirebaseIdentityTransient].
abstract interface class FirebaseAuthAdapter {
  Stream<AppUser?> get users;
  Future<void> signIn(String email, String password);
  Future<void> signOut();
  Future<String?> idToken(AppUser user);
  Future<void> close();
}
