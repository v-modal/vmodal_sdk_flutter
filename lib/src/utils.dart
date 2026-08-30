import 'dart:convert';

import 'errors.dart';

const int jsonResponseLimitBytes = 8 * 1024 * 1024;
const int errorResponseLimitBytes = 1024 * 1024;
const int binaryResponseLimitBytes = 64 * 1024 * 1024;
const int checkpointJsonLimitBytes = 1024 * 1024;

final List<RegExp> _serverPathPatterns = <RegExp>[
  RegExp(r'file:(?:/{2,3}|\\{2})[^\r\n"<>|,;)}\]]+', caseSensitive: false),
  RegExp(r'(^|[\s"(\[{:=>])([A-Za-z]:[\\/][^\r\n"<>|,;)}\]]+)'),
  RegExp(r'(^|[\s"(\[{:=>])(\\{2}[^\r\n"<>|,;)}\]]+)'),
  RegExp(r'(^|[\s"(\[{:=>])(/(?!/)[^\r\n"<>|,;)}\]]+)'),
];

String strRedactServerPaths(String value) {
  var out = value;
  for (final pattern in _serverPathPatterns) {
    out = out.replaceAllMapped(
      pattern,
      (Match match) =>
          '${match.groupCount > 1 ? match.group(1) ?? '' : ''}****',
    );
  }
  return out;
}

Object? objRedactServerDetails(Object? value) {
  if (value is String) return strRedactServerPaths(value);
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(objRedactServerDetails));
  }
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((Object? key, Object? item) {
      out[strRedactServerPaths('$key')] = objRedactServerDetails(item);
    });
    return Map<String, Object?>.unmodifiable(out);
  }
  return value;
}

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

/// Validates the additive CCTV upload fields shared by direct and signed paths.
void validateCctvUpload({
  required String mode,
  required String sourceFileName,
  String? videoFilename,
  String? startDatetimeUser,
}) {
  if ((videoFilename != null || startDatetimeUser != null) &&
      mode != 'vid_file') {
    throw const ValidationException(
      'video_filename and start_datetime_user require mode vid_file',
    );
  }
  if (videoFilename != null) {
    final name = videoFilename.trim();
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) {
      throw const ValidationException(
        'video_filename must be a nonblank bare filename',
      );
    }
    final sourceExt = _fileExtension(sourceFileName);
    final publicExt = _fileExtension(name);
    if (sourceExt.isNotEmpty &&
        publicExt.isNotEmpty &&
        sourceExt.toLowerCase() != publicExt.toLowerCase()) {
      throw const ValidationException(
        'video_filename extension must match the uploaded file extension',
      );
    }
  }
  if (startDatetimeUser != null) {
    final value = startDatetimeUser.trim();
    if (value.isEmpty ||
        !RegExp(r'(?:[zZ]|[+-]\d{2}:\d{2})$').hasMatch(value)) {
      throw const ValidationException(
        'start_datetime_user must be nonblank and include Z or an explicit UTC offset',
      );
    }
  }
}

/// Resolves the canonical public CCTV filename without changing timestamps.
String? strCctvVideoFilename(
  String sourceFileName,
  String? videoFilename,
  String? startDatetimeUser,
) => videoFilename ?? (startDatetimeUser == null ? null : sourceFileName);

String _fileExtension(String value) {
  final name = value.split(RegExp(r'[/\\]')).last;
  final index = name.lastIndexOf('.');
  return index <= 0 || index == name.length - 1 ? '' : name.substring(index);
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
