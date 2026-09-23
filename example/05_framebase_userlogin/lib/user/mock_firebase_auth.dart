import 'dart:async';

import 'auth_adapter.dart';

/// The default fixture is the intentionally empty app-defined auth response.
const emptyAuthResponse = <String, Object?>{
  'user': null,
  'id_token': null,
  'vmodal': <String, Object?>{
    'api_token': null,
    'expires_at': null,
    'firebase_uid': null,
    'vmodal_user_id': null,
    'collection_user_id': null,
    'allowed': false,
    'permissions': <String>[],
  },
};

class MockFirebaseAuth implements FirebaseAuthAdapter {
  MockFirebaseAuth({AppUser? initial, Map<String, AppUser>? accounts})
    : _user = initial,
      accounts = accounts ?? {} {
    scheduleMicrotask(() => _changes.add(_user));
  }

  final Map<String, AppUser> accounts;
  final StreamController<AppUser?> _changes = StreamController.broadcast(
    sync: true,
  );
  AppUser? _user;
  @override
  Stream<AppUser?> get users => _changes.stream;

  void setUser(AppUser? user) {
    _user = user;
    _changes.add(user);
  }

  @override
  Future<void> signIn(String email, String password) async {
    final user = accounts[email];
    if (user == null || password.isEmpty) {
      throw StateError('Sign-in is unavailable in the offline example.');
    }
    setUser(user);
  }

  @override
  Future<void> signOut() async => setUser(null);

  @override
  Future<String?> idToken(AppUser user) async => null;

  @override
  Future<void> close() => _changes.close();
}
