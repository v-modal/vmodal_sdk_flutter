# User and business index organization

These compile-checked Flutter examples show four ways an application can
organize searchable content with the immutable `VModal` project, collection,
and stream facade.

The SDK does not create or manage application user accounts. Your application
authenticates its user, obtains a VModal runtime API key, and maps its stable
user identifier to a collection name. The examples keep that content mapping
separate from VModal bearer-token identity.

## Progressive flow

Every example starts in the same order:

```text
runtime API key
  -> authenticate with auth.me()
  -> list this project's collections
  -> list index jobs for the selected collection
  -> upload, index, or search
```

Stop after an authentication failure. Empty collection and index-job lists are
valid for a new account; upload content and create an index before searching.

## Four cases

| Case | Class | Project / collection / stream |
|---|---|---|
| Shared search | `GlobalSearchIndex` | `video_search / global / uploads` |
| Private user index | `PrivateUserIndex` | `food_app / user_<id> / personal_videos` |
| User streams | `UserStreams` | `food_app / user_<id> / camera, favorites, uploads` |
| Product catalog | `ProductCatalog` | `shopping_app / product_catalog / merchant_uploads` |

Import all four examples from:

```dart
import 'package:vmodal_user_examples/user_examples.dart';
```

## Private index per application user

Supply the API key at runtime. Never embed it in source, assets, logs, or build
arguments.

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import 'package:vmodal_user_examples/user_examples.dart';

Future<void> openUserLibrary(
  String runtimeApiKey,
  String authenticatedUserId,
) async {
  final keys = MutableApiKeyProvider(runtimeApiKey);
  final user = PrivateUserIndex(
    apiKeyProvider: keys,
    endUserId: authenticatedUserId,
  );

  try {
    final profile = await user.authenticate();
    final collections = await user.listCollections();
    final jobs = await user.listIndexJobs();

    print('Authenticated type: ${profile.type}');
    print('Project collections: ${collections.length}');
    print('Index jobs: ${jobs.total}');

    // Keep UploadTask when uploading so the UI can observe progress or cancel:
    // final task = user.upload(UploadSource.fromFile(videoFile));
    // final uploaded = await task.result;

    final results = await user.search('pasta recipe');
    print('Matches: ${results.cntActual}');
  } finally {
    keys.clear();
    await user.close();
  }
}
```

Only call `listIndexJobs()` after authentication. For a new user collection,
the request may return an empty list until content is uploaded and indexed.

## Multiple streams for one user

Use one collection when all content belongs to the same application user, then
select a stream by source or purpose:

```dart
final user = UserStreams(
  apiKeyProvider: keys,
  endUserId: authenticatedUserId,
);

final cameraTask = user.camera.upload(UploadSource.fromFile(cameraVideo));
final favoriteResults = await user.favorites.search('birthday dinner');
final uploadJobs = await user.uploads.listIndexJobs();
```

`camera`, `favorites`, and `uploads` all map to the same user collection. A
collection deletion therefore affects every stream in that collection.

## Global and business-domain collections

Use `GlobalSearchIndex` when all application content belongs in one shared
search index. Use `ProductCatalog` when the collection is owned by a business
domain rather than by an end user.

Both expose the same progressive methods as `PrivateUserIndex`:

```dart
await example.authenticate();
await example.listCollections();
await example.listIndexJobs();
final task = example.upload(source);
final uploaded = await task.result;
final results = await example.search(query);
await example.close();
```

## Naming contract

`VModal` encodes the public project and collection into the backend collection:

```text
<projectId>__<collectionName>
```

The double underscore is reserved for this encoding. Do not include `__` in
either public value. For example, application user `123` becomes logical
collection `user_123`, which project `food_app` encodes internally as
`food_app__user_123`.

The application owns this mapping. The source user ID must:

- remain stable for that user;
- contain only letters, digits, and underscores after the `user_` prefix;
- fit the SDK's 80-character encoded-name limit; and
- never be lossy-sanitized in a way that can map two users to one collection.

Invalid mappings throw `ValidationException` locally before a network request.

## Verify all four cases

From `uinterface/sdk_flutter`:

```bash
bash build.sh pub_get
bash build.sh format
bash build.sh analyze
bash build.sh test
```

The standard SDK checks resolve, format, analyze, and test this package
together with the main SDK and `example/01_full_app`.
