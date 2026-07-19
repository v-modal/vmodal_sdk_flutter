import 'dart:convert';

import 'errors.dart';

part 'routes.g.dart';

/// @nodoc
enum RouteCategory {
  active,
  usersApi,
  image,
  signedSingle,
  multipartExperimental,
  deprecated,
  disabled,
}

/// @nodoc
class RouteSpec {
  const RouteSpec(
    this.name,
    this.method,
    this.path,
    this.category,
    this.source,
  );

  final String name;
  final String method;
  final String path;
  final RouteCategory category;
  final String source;
}

/// @nodoc
abstract final class Routes {
  static String get prefix => _routeValue('prefix');
  static String get usersApiPrefix => _routeValue('usersApiPrefix');

  static String get health => _routeValue('health');
  static String get searchClient => _routeValue('searchClient');
  static String get groups => _routeValue('groups');
  static String get indexationJobs => _routeValue('indexationJobs');
  static String get indexationSubmit => _routeValue('indexationSubmit');
  static String get indexationStatus => _routeValue('indexationStatus');
  static String get indexationDelete => _routeValue('indexationDelete');
  static String get upload => _routeValue('upload');
  static String get uploadFolder => _routeValue('uploadFolder');
  static String get uploadGoogleDriveFolder =>
      _routeValue('uploadGoogleDriveFolder');
  static String get uploadMetadataJsonl => _routeValue('uploadMetadataJsonl');
  static String get collectionDescriptionUpdate =>
      _routeValue('collectionDescriptionUpdate');
  static String get collectionDelete => _routeValue('collectionDelete');
  static String get collectionAddAssets => _routeValue('collectionAddAssets');
  static String get adminUserStats => _routeValue('adminUserStats');
  static String get uploadMetadataItemParquetInternal =>
      _routeValue('uploadMetadataItemParquetInternal');

  static String get imageGetUrl => _routeValue('imageGetUrl');
  static String get imageGetUrlBulk => _routeValue('imageGetUrlBulk');
  static String get imageGetImage => _routeValue('imageGetImage');
  static String get imageGetImageBulk => _routeValue('imageGetImageBulk');

  static String get authMe => _routeValue('authMe');
  static String get adminUsage => _routeValue('adminUsage');
  static String get adminCacheStats => _routeValue('adminCacheStats');
  static String get r2Credentials => _routeValue('r2Credentials');
  static String get r2UploadFile => _routeValue('r2UploadFile');
  static String get r2UploadFolderVideo => _routeValue('r2UploadFolderVideo');

  static String get externalUploadGetSignedUrl =>
      _routeValue('externalUploadGetSignedUrl');
  static String get externalUploadDone => _routeValue('externalUploadDone');
  static String get externalUploadMultipartCreate =>
      _routeValue('externalUploadMultipartCreate');
  static String get externalUploadMultipartSignParts =>
      _routeValue('externalUploadMultipartSignParts');
  static String get externalUploadMultipartStatus =>
      _routeValue('externalUploadMultipartStatus');
  static String get externalUploadMultipartComplete =>
      _routeValue('externalUploadMultipartComplete');
  static String get externalUploadMultipartAbort =>
      _routeValue('externalUploadMultipartAbort');

  static List<RouteSpec> get specs => _routeSpecs;

  static String full(String path) => _addPrefix(path, prefix);
  static String usersFull(String path) => _addPrefix(path, usersApiPrefix);

  static String _addPrefix(String path, String valuePrefix) {
    if (Uri.tryParse(path)?.hasScheme ?? false) {
      throw const ValidationException(
        'absolute URLs are not allowed in the API route table',
      );
    }
    final clean = path.startsWith('/') ? path : '/$path';
    return '$valuePrefix$clean';
  }
}
