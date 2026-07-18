import 'errors.dart';

/// Supplies the API key used immediately before each SDK request.
///
/// Implementations should return only an in-memory credential and throw
/// [AuthException] when it is unavailable.
abstract interface class ApiKeyProvider {
  /// Returns the current validated credential.
  String current();
}

/// In-memory credential provider supporting rotation and explicit clearing.
///
/// [close] permanently disables the provider. Values are redacted from
/// [toString] and are never persisted by this class.
class MutableApiKeyProvider implements ApiKeyProvider {
  /// Creates a provider after validating [initialKey].
  MutableApiKeyProvider(String initialKey) : _key = strApiKey(initialKey);

  String? _key;
  bool _closed = false;

  /// Replaces the active key, or throws [AuthException] after [close].
  void rotate(String newKey) {
    final valid = strApiKey(newKey);
    if (_closed) throw const AuthException('API key is unavailable');
    _key = valid;
  }

  /// Removes the current key without permanently closing the provider.
  void clear() {
    _key = null;
  }

  /// Clears the key and permanently disables [current] and [rotate].
  void close() {
    _closed = true;
    clear();
  }

  @override
  String current() {
    final value = _key;
    if (_closed || value == null) {
      throw const AuthException('API key is unavailable');
    }
    return value;
  }

  @override
  String toString() => 'MutableApiKeyProvider([REDACTED])';
}

/// @nodoc
String strApiKey(String value) {
  final key = value.trim();
  if (key.isEmpty) throw const ValidationException('API key must not be blank');
  if (key.length > 8192) {
    throw const ValidationException('API key is too long');
  }
  if (key.runes.any((int value) => value < 32 || value == 127)) {
    throw const ValidationException('API key contains invalid characters');
  }
  return key;
}
