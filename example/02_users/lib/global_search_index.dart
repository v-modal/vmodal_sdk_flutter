import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'src/example_session.dart';

/// Google Search-style organization with one shared application index.
final class GlobalSearchIndex {
  GlobalSearchIndex({required ApiKeyProvider apiKeyProvider})
    : _session = ExampleSession(
        projectId: 'video_search',
        apiKeyProvider: apiKeyProvider,
      ) {
    content = _session.project.scope(
      collectionName: 'global',
      streamName: 'uploads',
    );
  }

  final ExampleSession _session;
  late final VModalScope content;

  Future<UserProfile> authenticate() => _session.authenticate();

  Future<List<String>> listCollections() => _session.listCollections();

  Future<IndexationJobsListResponse> listIndexJobs() => content.listIndexJobs();

  UploadTask<VideoUploadResponse> upload(UploadSource video) =>
      content.upload(video);

  Future<SearchResponse> search([String query = 'red bicycle near a bridge']) =>
      content.search(query);

  Future<void> close() => _session.close();
}
