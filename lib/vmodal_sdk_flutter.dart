/// Typed Flutter client for uploading, indexing, and searching VModal media.
///
/// Configure one [VModalProject], create immutable [VModalScope] values, and
/// close the project when the app session ends. Authentication remains
/// separate from project, collection, and stream organization.
///
/// ```dart
/// final keys = MutableApiKeyProvider(runtimeApiKey);
/// final project = VModal.configure(
///   projectId: 'food_app',
///   apiKeyProvider: keys,
/// );
/// final favorites = project.scope(
///   collectionName: 'user_123',
///   streamName: 'favorites',
/// );
///
/// final groups = await project.listCollections();
/// final results = await favorites.search('a person entering the room');
///
/// await project.close();
/// keys.close();
/// ```
///
/// Long-running calls accept a [CancellationToken]. Media uploads return an
/// [UploadTask], whose [UploadTask.progress] stream is suitable for progress
/// indicators and whose [UploadTask.cancel] method stops pending work.
/// [VmodalClient] remains available as the advanced compatibility API.
// ignore: unnecessary_library_name
library vmodal_sdk_flutter;

export 'src/adaptive_upload.dart';
export 'src/api_key_provider.dart';
export 'src/client.dart';
export 'src/collection_uploads.dart';
export 'src/config.dart';
export 'src/errors.dart';
export 'src/models.dart';
export 'src/resources.dart';
export 'src/routes.dart' show RouteCategory, RouteSpec, Routes;
export 'src/transcode.dart';
export 'src/transport.dart'
    show
        CancellationToken,
        HttpVmodalTransport,
        VmodalFilePart,
        VmodalRequest,
        VmodalResponse,
        VmodalResponseMode,
        VmodalTransport,
        filePart,
        guessContentType,
        streamPart;
export 'src/upload.dart';
export 'src/vmodal.dart';
