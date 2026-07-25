import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'src/example_session.dart';

/// Commerce organization based on a business domain, not an end user.
final class ProductCatalog {
  ProductCatalog({required ApiKeyProvider apiKeyProvider})
    : _session = ExampleSession(
        projectId: 'shopping_app',
        apiKeyProvider: apiKeyProvider,
      ) {
    catalog = _session.project.scope(
      collectionName: 'product_catalog',
      streamName: 'merchant_uploads',
    );
  }

  final ExampleSession _session;
  late final VModalScope catalog;

  Future<UserProfile> authenticate() => _session.authenticate();

  Future<List<String>> listCollections() => _session.listCollections();

  Future<IndexationJobsListResponse> listIndexJobs() => catalog.listIndexJobs();

  UploadTask<VideoUploadResponse> upload(UploadSource asset) =>
      catalog.upload(asset);

  Future<SearchResponse> search(String query) => catalog.search(query);

  Future<void> close() => _session.close();
}
