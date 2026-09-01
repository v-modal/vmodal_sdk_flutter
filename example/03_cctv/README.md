# CCTV upload and absolute-time search

This compile-checked example demonstrates the Flutter SDK CCTV input contract.
It keeps the footage timestamp supplied by the camera, a caller-selected public
video filename, searchable metadata text, and every metadata tag.

## Progressive flow

Run operations in this order:

```text
runtime API key
  -> authenticate with auth.me()
  -> list project collections
  -> list index jobs for the camera collection
  -> upload timestamped CCTV footage
  -> create and wait for the frame index
  -> search metadata within an absolute time range
```

## New CCTV upload format

```dart
final input = CctvUploadInput(
  file: File('/camera/incoming/segment_001.mp4'),
  videoFilename: 'entrance_20260730_091500.mp4',
  startDatetimeUser: '2026-07-30T09:15:00+09:00',
  metadataText: 'Entrance camera during opening hours',
  metadataTags: const <String>['cctv', 'entrance', 'camera_01'],
  reProcess: false,
);

final task = example.upload(input);
final uploaded = await task.result;

print(uploaded.videoFilename);
print(uploaded.startDatetimeUser);
print(uploaded.startTsUnixUserMs);
print(uploaded.timestampSource);
```

`startDatetimeUser` must contain `Z` or an explicit UTC offset. The SDK sends
the original string, while the backend returns the canonical UTC epoch value in
`startTsUnixUserMs`. Tags are transmitted as repeated `metadata_tags` values.

## Absolute-time metadata search

After creating the index, search with paired inclusive-start and exclusive-end
bounds:

```dart
final found = await example.search(
  const CctvSearchInput(
    visualQuery: 'a person entering the building',
    metadataQuery: 'entrance',
    startDate: '2026-07-30T09:15:00+09:00',
    endDate: '2026-07-30T09:16:00+09:00',
  ),
);

print('matches=${found.cntActual}');
```

UTC-equivalent bounds such as `2026-07-30T00:15:00Z` address the same footage.

## Run the complete example

From `uinterface/sdk_flutter`:

```bash
bash build.sh pub_get
export VMODAL_API_KEY='your-runtime-api-key'
cd example/03_cctv
dart run bin/main.dart \
  /camera/incoming/segment_001.mp4 \
  entrance_20260730_091500.mp4 \
  2026-07-30T09:15:00+09:00 \
  2026-07-30T09:16:00+09:00
```

The command performs real upload, indexation, and search operations. Use a test
collection and a runtime key supplied by your application; do not embed keys in
source code or assets.
