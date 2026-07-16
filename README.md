# VModal Flutter SDK

Typed VModal access for Flutter applications on Android and iOS. Flutter Web is
not supported in this release. The package owns neither login UI nor credential
storage; inject an already-loaded runtime API key from the parent application.

```dart
final keys = MutableApiKeyProvider(runtimeKey);
final client = VmodalClient(
  config: SdkConfig(apiKeyProvider: keys),
);

final me = await client.auth.me();
final result = await client.searches.searchVideo(
  const SearchRequest(queryText: 'red bicycle'),
);
```

Gateway mode sends caller identity only through the bearer credential. Use
`VmodalClient.unsafeDirect` only inside a trusted private network. Rotate a key
with `keys.rotate(newKey)`; account switching requires canceling work, clearing
the provider and upload persistence, then creating a new client.

Signed single upload is the production default for every file size. Multipart
is experimental and requires explicit `VideoUploadOptions(multipart: true)`;
it fails with `FeatureDisabled` when the complete backend route family is not
available. The parent app owns file picking, private storage directories,
background scheduling, and lifecycle UI.

