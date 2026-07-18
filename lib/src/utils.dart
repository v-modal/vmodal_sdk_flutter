import 'dart:convert';

import 'errors.dart';

const int jsonResponseLimitBytes = 8 * 1024 * 1024;
const int errorResponseLimitBytes = 1024 * 1024;
const int binaryResponseLimitBytes = 64 * 1024 * 1024;
const int checkpointJsonLimitBytes = 1024 * 1024;

String strRequired(String value, String fieldName) {
  final clean = value.trim();
  if (clean.isEmpty) {
    throw ValidationException('$fieldName is required');
  }
  return clean;
}

String strHeaderValue(String name, String value) {
  if (value.length > 4096 || value.runes.any(_isControl)) {
    throw ValidationException('$name contains invalid header characters');
  }
  return value;
}

String strMultipartValue(String name, String value, int maxLength) {
  if (value.isEmpty) {
    throw ValidationException('$name must not be blank');
  }
  if (value.length > maxLength) {
    throw ValidationException('$name is too long');
  }
  if (value.runes.any(_isControl)) {
    throw ValidationException('$name contains control characters');
  }
  return value;
}

bool _isControl(int value) => value < 32 || value == 127;

int intValue(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double doubleValue(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    return parsed != null && parsed.isFinite ? parsed : 0;
  }
  return 0;
}

Map<String, Object?> objectMap(Object? value) {
  if (value is! Map<Object?, Object?>) return <String, Object?>{};
  return value.map((Object? key, Object? item) => MapEntry('$key', item));
}

List<Map<String, Object?>> objectList(Object? value) {
  if (value is! List) return <Map<String, Object?>>[];
  return value
      .whereType<Map<Object?, Object?>>()
      .map(objectMap)
      .toList(growable: false);
}

List<String> stringList(Object? value) {
  if (value is! List) return <String>[];
  return value.map((Object? item) => '$item').toList(growable: false);
}

Object? jsonDecodeStrict(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    return jsonDecode(text);
  } on Object {
    throw const MalformedResponse();
  }
}
