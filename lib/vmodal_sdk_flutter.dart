/// Typed Flutter client for uploading, indexing, and searching VModal media.
///
/// Create one [VmodalClient] for the active signed-in session and share its
/// resource objects across the app. The SDK does not own login UI or persist
/// credentials; supply the current key through [MutableApiKeyProvider] and
/// close the client when the session ends.
///
/// ```dart
/// final keys = MutableApiKeyProvider(runtimeApiKey);
/// final vmodal = VmodalClient(config: SdkConfig(apiKeyProvider: keys));
///
/// final groups = await vmodal.collections.listGroups();
/// final results = await vmodal.searches.searchVideo(
///   const SearchRequest(queryText: 'a person entering the room'),
/// );
///
/// await vmodal.close();
/// keys.close();
/// ```
///
/// Long-running calls accept a [CancellationToken]. Media uploads return an
/// [UploadTask], whose [UploadTask.progress] stream is suitable for progress
/// indicators and whose [UploadTask.cancel] method stops pending work.
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
export 'src/transport.dart'
    show
        CancellationToken,
        VmodalFilePart,
        VmodalRequest,
        VmodalResponse,
        VmodalResponseMode,
        VmodalTransport,
        filePart,
        guessContentType,
        streamPart;
export 'src/upload.dart';
