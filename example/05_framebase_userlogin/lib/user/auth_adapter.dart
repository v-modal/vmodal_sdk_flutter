/// The host application owns Firebase identity. The offline implementation
/// emits the same nullable user state without loading Firebase packages.
class AppUser {
  const AppUser(this.uid, {this.email, this.label});
  final String uid;
  final String? email, label;
  String get displayName => label ?? email ?? uid;
}

abstract interface class FirebaseAuthAdapter {
  Stream<AppUser?> get users;
  Future<void> signIn(String email, String password);
  Future<void> signOut();
  Future<String?> idToken(AppUser user);
  Future<void> close();
}
