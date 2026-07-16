# Search application integration

Keep the client above individual pages so navigation does not close shared
network state. Pages await typed futures and check `mounted` before changing UI.

```dart
final result = await client.searches.searchVideo(
  const SearchRequest(
    queryText: 'red bicycle',
    mode: 'vid_file',
    groupName: 'agroup',
  ),
);
```

Render only safe `SdkException.toString()` output. It contains classification
and status metadata, never response bodies, URLs, keys, or identities. Cancel an
upload task when the user explicitly cancels it; do not close the application
client merely because a page was disposed.

