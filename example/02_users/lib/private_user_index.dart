import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'src/example_session.dart';

/// One isolated searchable collection for an application end user.
final class PrivateUserIndex {
  PrivateUserIndex({
    required ApiKeyProvider apiKeyProvider,
    required String endUserId,
  }) : collectionName = exampleUserCollectionName(endUserId),
       _session = ExampleSession(
         projectId: 'food_app',
         apiKeyProvider: apiKeyProvider,
       ) {
    personal = _session.project.scope(
      collectionName: collectionName,
      streamName: 'personal_videos',
    );
  }

  final String collectionName;
  final ExampleSession _session;
  late final VModalScope personal;

  Future<UserProfile> authenticate() => _session.authenticate();

  Future<List<String>> listCollections() => _session.listCollections();

  Future<IndexationJobsListResponse> listIndexJobs() =>
      personal.listIndexJobs();

  UploadTask<VideoUploadResponse> upload(UploadSource video) =>
      personal.upload(video);

  Future<SearchResponse> search([String query = 'pasta recipe']) =>
      personal.search(query);

  Future<void> close() => _session.close();
}
