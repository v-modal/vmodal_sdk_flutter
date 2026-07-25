import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import 'package:vmodal_user_examples/user_examples.dart';

void main() {
  test('P1 global search uses one shared application scope', () async {
    final example = GlobalSearchIndex(
      apiKeyProvider: MutableApiKeyProvider('runtime-key'),
    );
    addTearDown(example.close);

    expect(example.content.projectId, 'video_search');
    expect(example.content.collectionName, 'global');
    expect(example.content.streamName, 'uploads');
    expect(example.authenticate, isA<Future<UserProfile> Function()>());
    expect(example.listCollections, isA<Future<List<String>> Function()>());
    expect(
      example.listIndexJobs,
      isA<Future<IndexationJobsListResponse> Function()>(),
    );
    expect(
      example.upload,
      isA<UploadTask<VideoUploadResponse> Function(UploadSource)>(),
    );
  });

  test('P2 private index maps one application user to one scope', () async {
    final example = PrivateUserIndex(
      apiKeyProvider: MutableApiKeyProvider('runtime-key'),
      endUserId: ' 123 ',
    );
    addTearDown(example.close);

    expect(example.collectionName, 'user_123');
    expect(example.personal.projectId, 'food_app');
    expect(example.personal.collectionName, 'user_123');
    expect(example.personal.streamName, 'personal_videos');
  });

  test('P2 private index rejects missing or invalid user names locally', () {
    expect(
      () => PrivateUserIndex(
        apiKeyProvider: MutableApiKeyProvider('runtime-key'),
        endUserId: ' ',
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => PrivateUserIndex(
        apiKeyProvider: MutableApiKeyProvider('runtime-key'),
        endUserId: 'invalid-user',
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => PrivateUserIndex(
        apiKeyProvider: MutableApiKeyProvider('runtime-key'),
        endUserId: 'invalid__user',
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => PrivateUserIndex(
        apiKeyProvider: MutableApiKeyProvider('runtime-key'),
        endUserId: List<String>.filled(66, 'a').join(),
      ),
      throwsA(isA<ValidationException>()),
    );
  });

  test('P3 user streams share one collection and keep distinct streams', () {
    final example = UserStreams(
      apiKeyProvider: MutableApiKeyProvider('runtime-key'),
      endUserId: '123',
    );
    addTearDown(example.close);

    expect(example.collectionName, 'user_123');
    expect(
      <String>{
        example.camera.projectId,
        example.favorites.projectId,
        example.uploads.projectId,
      },
      <String>{'food_app'},
    );
    expect(
      <String>{
        example.camera.collectionName,
        example.favorites.collectionName,
        example.uploads.collectionName,
      },
      <String>{'user_123'},
    );
    expect(
      <String>{
        example.camera.streamName,
        example.favorites.streamName,
        example.uploads.streamName,
      },
      <String>{'camera', 'favorites', 'uploads'},
    );
  });

  test('P4 product catalog uses a user-independent business scope', () {
    final example = ProductCatalog(
      apiKeyProvider: MutableApiKeyProvider('runtime-key'),
    );
    addTearDown(example.close);

    expect(example.catalog.projectId, 'shopping_app');
    expect(example.catalog.collectionName, 'product_catalog');
    expect(example.catalog.streamName, 'merchant_uploads');
  });
}
