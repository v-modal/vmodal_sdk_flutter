# Search application integration

Keep the client above individual pages so navigation does not close shared
network state. Before searching, confirm that the selected authenticated video
collection exists and use its latest advertised LanceDB version.

```dart
final groups = await client.collections.listGroups(mode: 'vid_file');
final group = groups.findGroup('agroup', mode: 'vid_file');
final version = group?.latestLancedbVersion;
if (version == null) throw StateError('Finish the image index first');

final result = await client.searches.searchVideo(
  SearchRequest(
    queryText: 'red bicycle',
    mode: 'vid_file',
    groupName: 'agroup',
    streamName: 'astream',
    searchSources: const ['image'],
    versionLancedb: version,
  ),
);
```

Search hits contain stored image coordinates, not public image URLs. Convert
each usable hit into one bulk lookup record with these fields:

```text
mode                 vid_file
group_name           selected authenticated collection
modality             image
stream_name          hit stream, or selected stream as fallback
filename             basename of the first supported filename/path field
ts_unix_13digits     normalized timestamp, when present
```

The supported filename fields, in order, are `filename`,
`filename_sanitized`, `video_filename`, `video`, `source_path`, and `path`.
Normalize timestamps from `ts_unix_13digits`, `ts_unix`, or `timestamp_ms`:
truncate values longer than 13 digits, multiply 10-digit seconds by 1000, and
left-pad other nonblank numeric values to 13 digits.

Send all candidate records in one request:

```dart
final candidates = exampleSearchCandidates(result, 'agroup', 'astream');
final resolved = candidates.isEmpty
    ? null
    : await client.images.getUrlBulk(
        candidates.map((candidate) => candidate.record).toList(),
      );
final images = resolved == null
    ? const <ExampleSearchImage>[]
    : exampleSearchImages(candidates, resolved);
```

Map each usable `url_pre_signed` back through `input_index`; do not join by
response order when an index is present. Accept numeric or parseable-string
indexes, reject negative/out-of-range values, keep the first usable duplicate,
and sort the final cards by candidate index. A missing index may use only its
bounded response-row position as a compatibility fallback.

Use a responsive `GridView.builder` with one page scroll owner. Show total
backend matches separately from resolved image count, and keep an image load
failure local to its card. A successful search may legitimately have matches
but no image-backed cards because filenames or URL records were unavailable.

Presigned image URLs are temporary capabilities. Keep them in current widget
state only, resolve fresh URLs for every search, and never log or persist them.
Download them directly with `NetworkImage`/`Image.network`; do not attach the
VModal Bearer token or identity headers to that image GET.

Capture a search generation plus the query/collection/stream snapshot before
awaiting network work. After both search and bulk resolution, check `mounted`
and that the generation/scope is still current before updating UI. Invalidate
old results when the client, query, collection, stream, or upload lifecycle
changes.

Render only safe `SdkException.toString()` output. It contains classification
and status metadata, never response bodies, URLs, keys, or identities. Cancel
an upload task when the user explicitly cancels it; do not close the shared
application client merely because a page was disposed.
