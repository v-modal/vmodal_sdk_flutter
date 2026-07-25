import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'src/example_session.dart';

/// One user collection divided by asset source or purpose.
final class UserStreams {
  UserStreams({
    required ApiKeyProvider apiKeyProvider,
    required String endUserId,
  }) : collectionName = exampleUserCollectionName(endUserId),
       _session = ExampleSession(
         projectId: 'food_app',
         apiKeyProvider: apiKeyProvider,
       ) {
    camera = _session.project.scope(
      collectionName: collectionName,
      streamName: 'camera',
    );
    favorites = _session.project.scope(
      collectionName: collectionName,
      streamName: 'favorites',
    );
    uploads = _session.project.scope(
      collectionName: collectionName,
      streamName: 'uploads',
    );
  }

  final String collectionName;
  final ExampleSession _session;
  late final VModalScope camera;
  late final VModalScope favorites;
  late final VModalScope uploads;

  Future<UserProfile> authenticate() => _session.authenticate();

  Future<List<String>> listCollections() => _session.listCollections();

  Future<IndexationJobsListResponse> listIndexJobs() => uploads.listIndexJobs();

  Future<void> close() => _session.close();
}
