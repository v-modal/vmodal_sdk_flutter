import 'errors.dart';

enum RouteCategory {
  active,
  usersApi,
  image,
  signedSingle,
  multipartExperimental,
  deprecated,
  disabled,
}

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

abstract final class Routes {
  static const String prefix = '/api/external/v1';
  static const String usersApiPrefix = '/api/v1';

  static const String health = '/health';
  static const String searchClient = '/search';
  static const String groups = '/collection/groups';
  static const String indexationJobs = '/indexation/jobs';
  static const String indexationSubmit = '/indexation/job/create';
  static const String indexationStatus = '/indexation/job/{job_id}';
  static const String indexationDelete = '/indexation/index/delete';
  static const String upload = '/collection/upload';
  static const String uploadFolder = '/upload/folder';
  static const String uploadGoogleDriveFolder =
      '/collection/upload/google_drive';
  static const String uploadMetadataJsonl = '/collection/upload/metadata';
  static const String collectionDescriptionUpdate =
      '/collection/description/update';
  static const String collectionDelete = '/collection/delete';
  static const String collectionAddAssets =
      '/collection/{collection_id}/assets/create';
  static const String adminUserStats = '/admin/user-stats';
  static const String uploadMetadataItemParquetInternal =
      '/api/internal/v1/collection/upload/metadata';

  static const String imageGetUrl = '/image/get_url';
  static const String imageGetUrlBulk = '/image/get_url_bulk';
  static const String imageGetImage = '/image/get_image';
  static const String imageGetImageBulk = '/image/get_image_bulk';

  static const String authMe = '/auth/me';
  static const String adminUsage = '/admin/usage';
  static const String adminCacheStats = '/admin/cache/stats';
  static const String r2Credentials = '/get_r2_credentials/';
  static const String r2UploadFile = '/upload_file/';
  static const String r2UploadFolderVideo = '/upload_folder_video/';

  static const String externalUploadGetSignedUrl =
      '/collections/external_upload_get_signed_url';
  static const String externalUploadDone = '/collection/upload/done';
  static const String externalUploadMultipartCreate =
      '/collections/external_upload_multipart/create';
  static const String externalUploadMultipartSignParts =
      '/collections/external_upload_multipart/sign_parts';
  static const String externalUploadMultipartStatus =
      '/collections/external_upload_multipart/status';
  static const String externalUploadMultipartComplete =
      '/collections/external_upload_multipart/complete';
  static const String externalUploadMultipartAbort =
      '/collections/external_upload_multipart/abort';

  static const List<RouteSpec> specs = <RouteSpec>[
    RouteSpec('auth.health', 'GET', health, RouteCategory.active, 'upstream'),
    RouteSpec(
      'auth.auth_check',
      'GET',
      health,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'searches.search_video',
      'POST',
      searchClient,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.list_groups',
      'GET',
      groups,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.upload_file',
      'POST',
      upload,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.upload_metadata_jsonl',
      'POST',
      uploadMetadataJsonl,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.update_description',
      'POST',
      collectionDescriptionUpdate,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.delete',
      'DELETE',
      collectionDelete,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.add_assets',
      'POST',
      collectionAddAssets,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'indexes.jobs_list',
      'GET',
      indexationJobs,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'indexes.create_index',
      'POST',
      indexationSubmit,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'indexes.index_status',
      'GET',
      indexationStatus,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'indexes.delete_index',
      'DELETE',
      indexationDelete,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'admin.user_stats',
      'GET',
      adminUserStats,
      RouteCategory.active,
      'upstream',
    ),
    RouteSpec(
      'collections.upload_google_drive_folder',
      'POST',
      uploadGoogleDriveFolder,
      RouteCategory.deprecated,
      'upstream',
    ),
    RouteSpec(
      'collections.upload_folder',
      'POST',
      uploadFolder,
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'indexes.embedding_models',
      'GET',
      '/indexes/embedding_models',
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'collections.auto_index_get',
      'GET',
      '/collection/auto_index',
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'collections.auto_index_set',
      'POST',
      '/collection/auto_index',
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'gdrive.private_auth_url',
      'POST',
      '/gdrive/private/auth-url',
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'gdrive.private_download',
      'POST',
      '/gdrive/private/folder/download',
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'sql.query',
      'POST',
      '/sql/query',
      RouteCategory.disabled,
      'upstream',
    ),
    RouteSpec(
      'collections.create',
      'NONE',
      '',
      RouteCategory.disabled,
      'sdk_contract',
    ),
    RouteSpec(
      'collections.edit',
      'NONE',
      '',
      RouteCategory.disabled,
      'sdk_contract',
    ),
    RouteSpec(
      'images.get_url',
      'POST',
      imageGetUrl,
      RouteCategory.image,
      'apionly_serve_img.py',
    ),
    RouteSpec(
      'images.get_url_bulk',
      'POST',
      imageGetUrlBulk,
      RouteCategory.image,
      'apionly_serve_img.py',
    ),
    RouteSpec(
      'images.get_image_from_url',
      'POST',
      imageGetImage,
      RouteCategory.image,
      'apionly_serve_img.py',
    ),
    RouteSpec(
      'images.get_image_bulk_from_urls',
      'POST',
      imageGetImageBulk,
      RouteCategory.image,
      'apionly_serve_img.py',
    ),
    RouteSpec('auth.me', 'GET', authMe, RouteCategory.usersApi, 'users_api'),
    RouteSpec(
      'admin.usage',
      'GET',
      adminUsage,
      RouteCategory.usersApi,
      'users_api',
    ),
    RouteSpec(
      'admin.cache_stats',
      'GET',
      adminCacheStats,
      RouteCategory.usersApi,
      'users_api',
    ),
    RouteSpec(
      'r2.credentials',
      'GET',
      r2Credentials,
      RouteCategory.usersApi,
      'users_api',
    ),
    RouteSpec(
      'r2.presign_upload_file',
      'GET',
      r2UploadFile,
      RouteCategory.usersApi,
      'users_api',
    ),
    RouteSpec(
      'r2.presign_upload_folder_video',
      'POST',
      r2UploadFolderVideo,
      RouteCategory.usersApi,
      'users_api',
    ),
    RouteSpec(
      'collections.video_upload.presign',
      'POST',
      externalUploadGetSignedUrl,
      RouteCategory.signedSingle,
      'sdk_python',
    ),
    RouteSpec(
      'collections.video_upload.done',
      'POST',
      externalUploadDone,
      RouteCategory.signedSingle,
      'sdk_python',
    ),
    RouteSpec(
      'multipart.create',
      'POST',
      externalUploadMultipartCreate,
      RouteCategory.multipartExperimental,
      'sdk_python',
    ),
    RouteSpec(
      'multipart.sign_parts',
      'POST',
      externalUploadMultipartSignParts,
      RouteCategory.multipartExperimental,
      'sdk_python',
    ),
    RouteSpec(
      'multipart.status',
      'GET',
      externalUploadMultipartStatus,
      RouteCategory.multipartExperimental,
      'sdk_python',
    ),
    RouteSpec(
      'multipart.complete',
      'POST',
      externalUploadMultipartComplete,
      RouteCategory.multipartExperimental,
      'sdk_python',
    ),
    RouteSpec(
      'multipart.abort',
      'POST',
      externalUploadMultipartAbort,
      RouteCategory.multipartExperimental,
      'sdk_python',
    ),
    RouteSpec(
      'metadata.internal_fallback',
      'POST',
      uploadMetadataItemParquetInternal,
      RouteCategory.active,
      'sdk_python',
    ),
  ];

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
