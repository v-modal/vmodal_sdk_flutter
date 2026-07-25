import 'errors.dart';

const String _separator = '__';
const int _nameMax = 80;
final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_]+$');

/// Internal normalized content organization.
///
/// This file is intentionally not exported from the package library.
final class ContentScope {
  ContentScope._(this.projectId, this.collectionName, this.streamName)
    : backendCollectionName = '$projectId$_separator$collectionName';

  final String projectId;
  final String collectionName;
  final String streamName;
  final String backendCollectionName;

  static String project(String value) =>
      _normalize(value, 'projectId', reservedSeparator: true);

  static ContentScope create(
    String projectId,
    String collectionName,
    String streamName,
  ) {
    final project = ContentScope.project(projectId);
    final collection = _normalize(
      collectionName,
      'collectionName',
      reservedSeparator: true,
    );
    final stream = _normalize(streamName, 'streamName');
    if (project.length + _separator.length + collection.length > _nameMax) {
      throw const ValidationException(
        'projectId and collectionName must encode to at most 80 characters',
      );
    }
    return ContentScope._(project, collection, stream);
  }

  static String? decodeCollection(String projectId, String backendName) {
    final prefix = '$projectId$_separator';
    if (!backendName.startsWith(prefix)) return null;
    try {
      final collection = _normalize(
        backendName.substring(prefix.length),
        'collectionName',
        reservedSeparator: true,
      );
      if (backendName.length > _nameMax) {
        throw const ValidationException(
          'projectId and collectionName must encode to at most 80 characters',
        );
      }
      return collection;
    } on ValidationException {
      throw const MalformedResponse(
        'collection listing returned an invalid collectionName',
      );
    }
  }

  static String _normalize(
    String value,
    String field, {
    bool reservedSeparator = false,
  }) {
    final clean = value.trim();
    if (clean.isEmpty) {
      throw ValidationException('$field is required');
    }
    if (clean.length > _nameMax) {
      throw ValidationException('$field must be at most 80 characters');
    }
    if (!_namePattern.hasMatch(clean)) {
      throw ValidationException(
        '$field must contain only letters, digits, and underscore',
      );
    }
    if (reservedSeparator && clean.contains(_separator)) {
      throw ValidationException(
        '$field must not contain the reserved separator "$_separator"',
      );
    }
    return clean;
  }
}
