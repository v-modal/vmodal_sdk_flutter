# Manage API keys

Retrieve credentials in the parent application's authenticated service, load
them into memory, then inject `MutableApiKeyProvider`. The SDK never stores a key.

```dart
final provider = MutableApiKeyProvider(await authService.currentApiKey());
final project = VModal.configure(
  projectId: 'food_app',
  apiKeyProvider: provider,
);
```

`rotate` validates the complete new key before replacing the old one. A request
reads one snapshot; rotation affects the next request. `clear` and `close` fail
closed. Logout/account switch order is: cancel active work, clear upload state,
clear the provider, close the project, authenticate the next account, then
create a new provider, project, and immutable scopes. Key rotation is not an
identity, project, collection, or stream switch.

Keep `projectId` separate from the authenticated end-user ID. If content is
isolated per user, express the app-owned normalized identifier through a fresh
`collectionName` scope after account switch.

Do not commit keys, put them in assets, log them, add them to presigned requests,
or use compile-time `--dart-define` values as production mobile credential storage.
