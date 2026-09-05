import 'dart:convert';
import 'dart:io';

/// What the app needs from the user: a key, and a collection name per demo.
///
/// Saving is opt in. When it is off nothing touches the disk and the key lives
/// only in memory for the session, which is how the SDK itself treats it.
class Settings {
  Settings({
    this.apiKey = '',
    Map<String, String>? collections,
    this.remember = false,
  }) : collections = collections ?? <String, String>{};

  String apiKey;

  /// Collection name per scene id.
  final Map<String, String> collections;

  /// Whether to keep these on the device between launches.
  bool remember;

  static File get _file =>
      File('${Directory.systemTemp.parent.path}/Documents/sightline.json');

  /// Reads saved settings, or empty ones when nothing was saved.
  static Settings load() {
    try {
      final File file = _file;
      if (!file.existsSync()) return Settings();
      final Object? raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return Settings();
      return Settings(
        apiKey: '${raw['apiKey'] ?? ''}',
        collections: <String, String>{
          for (final MapEntry<Object?, Object?> e
              in (raw['collections'] as Map? ?? <Object?, Object?>{}).entries)
            '${e.key}': '${e.value}',
        },
        remember: raw['remember'] == true,
      );
    } on Object {
      return Settings();
    }
  }

  void save() {
    try {
      if (!remember) {
        forget();
        return;
      }
      _file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'apiKey': apiKey,
          'collections': collections,
          'remember': true,
        }),
      );
    } on FileSystemException {
      // Saving is a convenience; failing to save is not worth an error.
    }
  }

  void forget() {
    try {
      if (_file.existsSync()) _file.deleteSync();
    } on FileSystemException {
      // Nothing to do.
    }
  }
}

/// The SDK's rule for collection and stream names.
String? validateCollection(String value) {
  final String name = value.trim();
  if (name.isEmpty) return 'Give the collection a name.';
  if (name.length > 80) return 'Keep it under 80 characters.';
  if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(name)) {
    return 'Letters, digits and underscore only.';
  }
  if (name.contains('__')) return 'Two underscores in a row are reserved.';
  return null;
}
