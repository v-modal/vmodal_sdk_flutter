import 'errors.dart';

abstract interface class ApiKeyProvider {
  String current();
}

class MutableApiKeyProvider implements ApiKeyProvider {
  MutableApiKeyProvider(String initialKey) : _key = strApiKey(initialKey);

  String? _key;
  bool _closed = false;

  void rotate(String newKey) {
    final valid = strApiKey(newKey);
    if (_closed) throw const AuthException('API key is unavailable');
    _key = valid;
  }

  void clear() {
    _key = null;
  }

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
