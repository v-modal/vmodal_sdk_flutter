# VModal Flutter example

This application shows a complete VModal SDK evaluation workflow on Android or
iOS:

1. Authenticate with a runtime API key and stop if identity resolution fails.
2. List the collections visible to the authenticated user.
3. List the existing index jobs for the selected collection.
4. Reuse ready data, or upload the bundled 10-frame sample or another video.
5. Create an image index when needed and wait until it is ready.
6. Search the indexed collection and inspect result fields.

The runnable example is intentionally simple. It keeps its UI and SDK calls in
[`lib/main.dart`](lib/main.dart), so a beginner can follow the main flow in one
file. This guide also shows `jobsList()`, which an application can use to load
index jobs created during earlier runs.

## Beginner validation flow

After the app opens, validate one stage at a time:

```text
authentication
  -> existing collections
  -> existing index jobs
  -> existing ready data OR upload
  -> index ready
  -> search
```

Do not continue after a failed stage. An empty collection or index-job list is
not a failure; it means this account needs an upload or a new index before it
can search.

## What you need

Before starting, prepare:

- A macOS or Linux computer. The repository installer supports macOS on Intel
  and Apple Silicon, and Linux on x64.
- Git, Bash, `curl`, and either `unzip` or `tar`.
- Android Studio with an Android emulator, or a connected Android phone.
- For iOS, a Mac with Xcode and an iOS simulator or connected iPhone.
- A valid VModal runtime API key supplied by your authenticated application or
  VModal administrator.

You do not need to install Flutter globally. The repository can download and
use its reviewed Flutter version (`3.44.6`) from a user-owned cache.

> Never commit an API key, place it in Flutter assets, print it in logs, or
> include it directly in source code. This example asks for the key at runtime
> and keeps it in memory only.

## 1. Open the SDK directory

Run the following commands from the Flutter SDK directory—the directory that
contains `install.sh`, `run.sh`, and this `example/` folder.

From the VModal monorepo root:

```bash
cd uinterface/sdk_flutter
```

If you cloned the Flutter SDK as a standalone repository:

```bash
cd vmodal_sdk_flutter
```

## 2. Install the reviewed Flutter toolchain

```bash
bash install.sh install
```

This command:

- reads the required version from `.flutter-version`;
- uses an existing matching Flutter installation when available;
- otherwise downloads Flutter into `~/.cache/vmodal/flutter`;
- verifies the downloaded archive checksum; and
- downloads the Dart dependencies for the SDK package.

Check the installation at any time with:

```bash
bash install.sh check
```

The first installation can take several minutes because Flutter and package
dependencies must be downloaded.

## 3. Start a phone or emulator

Choose one of these options:

### Android emulator

1. Open Android Studio.
2. Open **Device Manager**.
3. Create a virtual device if none exists.
4. Start the virtual device and wait for its home screen.

For a physical Android phone, enable Developer options and USB debugging, then
connect the phone by USB and approve the computer on the phone.

### iOS simulator

1. Open Xcode once so it can finish installing its components.
2. Open **Xcode > Open Developer Tool > Simulator**.
3. Wait for the simulated iPhone home screen.

iOS development requires macOS. A physical iPhone may also require Apple code
signing; the simulator is usually easier for a first run.

## 4. Find the device ID

The project helper locates the reviewed Flutter binary for you:

```bash
flutter_bin="$(bash install.sh flutter_bin)"
"$flutter_bin" devices
```

Example output may include IDs such as:

```text
emulator-5554        android
iPhone 16 Pro        ios
```

Copy the device ID from the middle column. The exact name or ID on your
computer will be different.

If no mobile device appears, make sure the emulator or simulator has fully
started, then run the command again. Ignore Chrome because this SDK example
does not support Flutter Web.

## 5. Run the example

Replace `DEVICE_ID` with the ID shown by the previous command:

```bash
bash run.sh example --device DEVICE_ID
```

For example:

```bash
bash run.sh example --device emulator-5554
```

Flutter resolves the example's dependencies, builds the application, installs
it on the selected device, and opens it. The first Android or iOS build is
usually slower than later builds.

Keep this terminal open while developing:

- Press `r` for hot reload.
- Press `R` for a full hot restart.
- Press `q` to stop the app.

## 6. First validation: authenticate

When the application opens:

1. Paste a valid runtime API key into **Runtime API key**.
2. Tap **Configure client**.
3. Confirm that the status says:

   ```text
   Client configured. Resolve identity to load its collections.
   ```

4. Tap **Resolve auth.me**.
5. Do not continue until the app displays `Authenticated user type: ...`.

The authentication request is:

```dart
final me = await client.auth.me();
```

The input is obscured, and the example clears the text field after creating
the client. The key remains only in `MutableApiKeyProvider` memory while the
application is running.

If authentication fails, stop here. Check that the key is valid, has not
expired, and belongs to the intended VModal environment. Upload, indexing, and
search are not useful checks until `auth.me()` succeeds.

## 7. List existing collections

A successful **Resolve auth.me** request automatically loads the existing
`vid_file` collections visible to that runtime API key. You can also tap
**Refresh collections** to run the collection check again:

```dart
final groups = await client.collections.listGroups(mode: 'vid_file');
```

Validate the result before continuing:

- `Loaded N video collection(s).` means collection access works. Select one of
  the names shown under **Available collections**.
- `No existing video collections...` is a valid empty-account result. Keep the
  suggested `flutter_example` name and continue to upload.
- An SDK error means this stage failed. Do not continue until authentication,
  environment selection, or collection access is fixed.

If the current Collection value is not in the returned list, the example
selects the first available collection. Refresh the list whenever uploads or
another client may have changed it.

The Collection field must contain a collection returned for the current API
key before search. Access is key-scoped: a name from another account or
environment returns HTTP 404 even when the route is healthy. `flutter_example`
is only a suggested name for a new upload; do not search it until refreshing
the list shows that it exists and its index is ready.

## 8. List existing index jobs

For an existing collection, check its index jobs before uploading or creating
another index:

```dart
const collectionName = 'your_collection_from_step_7';
final jobs = await client.indexes.jobsList(
  mode: 'vid_file',
  groupName: collectionName,
);

print('Index jobs: ${jobs.total}');
for (final job in jobs.data) {
  print(job);
}
```

The API exposes index jobs rather than a separate index catalog. Each job
records an indexing attempt and its state. Treat the result as follows:

- A completed state such as `success`, `completed`, `done`, or `ok` means the
  collection is a candidate for immediate search.
- A queued or running state means wait and check that job with
  `client.indexes.indexStatus(jobId)`.
- An empty list means no index job exists for that collection. Upload data if
  needed, then create an index.
- A failed state means inspect the job error and fix it before search.

The example screen displays the job created during the current run. Use
`jobsList()` in your application when you also need to show jobs from earlier
runs. If the account has no collections, skip this check and upload first.

## 9. Choose and upload a video when needed

If Step 8 found a completed index job and you want to search that existing
collection, skip to Step 11. Otherwise, upload a video and create its index.

The repository includes
[`asset/video_10frames.mp4`](asset/video_10frames.mp4), a one-second, 320 × 240
H.264 video with exactly 10 frames of moving colored zebra stripes. It is small
enough to use as a quick upload example.

At startup, the example reads this Flutter asset, copies it to the app's
temporary directory, and fills **App-accessible file path** with the copied
file's absolute path. This copy is necessary because the upload SDK accepts a
`File`, while a bundled Flutter asset is not directly exposed as a normal
mobile file.

To use the bundled sample:

1. Wait until the status says **Bundled 10-frame sample video is ready.**
2. Configure the client if you have not already done so.
3. Leave the pre-filled path unchanged.
4. Tap **Upload**.
5. Watch the progress bar and final status message.
6. Tap **Cancel** while an upload is running to test cancellation. The sample
   is very small, so it may finish before you can cancel it.

By default, the upload is stored under the Collection and Stream currently
shown in the app. On an account with no collections, the suggested new target
is:

```text
collection:     flutter_example
sub-collection: astream
```

To upload your own video, tap **Choose video**. Flutter's `file_selector`
adapter opens the Android or iOS native picker and places its app-readable path
in the path field. Canceling the picker leaves the current sample selected. A
path on your computer is normally not valid inside a phone or emulator; use
the picker, bundled asset, camera flow, download, or app-owned directory.

In a real application, pass the path returned by your chosen picker or camera
adapter to:

```dart
final task = client.collections.videoUpload(
  UploadSource.fromFile(File(path)),
  collectionName: 'flutter_example',
  subCollectionName: 'astream',
);
```

The SDK streams the file instead of loading the complete video into memory.
`task.progress` reports upload progress, `task.result` completes with the
server response, and `task.cancel()` cancels the operation.

## 10. Create and monitor the image index

After upload succeeds:

1. Tap **Create index**.
2. Note the displayed job ID and initial state.
3. Tap **Refresh status** periodically.
4. Continue when the state is `success`, `completed`, `done`, or `ok`.

The example creates the image-search index for the same collection and stream:

```dart
final job = await client.indexes.createIndex(
  IndexationSubmitRequest(
    mode: 'vid_file',
    groupName: collectionName,
    streamName: streamName,
    indexType: 'vid_img_emb',
    modality: 'vid_img_emb',
    reProcess: true,
  ),
);
```

Indexing is asynchronous. The create call returning successfully means the job
was accepted, not that search data is ready. Use the visible refresh action or
`client.indexes.indexStatus(job.jobId)` until it reaches a terminal state.

## 11. Search and inspect results

1. Leave the default query, `red`, for the bundled colored sample or enter a
   visual description for your chosen video.
2. Tap **Search** after indexing succeeds.
3. Inspect up to five result cards showing the best available title/item ID,
   source modality, timestamp, and normalized score.

Search and upload use the same **Collection** and **Stream** fields. The example
refreshes the authenticated key's collection list before every search and
searches the ready image index selected or created in the earlier steps:

```dart
final result = await client.searches.searchVideo(
  SearchRequest(
    queryText: query,
    groupName: collectionName,
    streamName: streamName,
    searchSources: const ['image'],
  ),
);
```

A zero result count is still successful. Search is blocked locally when the
Collection value is not returned for the current key. If the collection exists
but has not been indexed, the server can return HTTP 404 even though the route
is working; the example reports that condition without displaying internal
server paths.

## 12. Stop and clean up

Press `q` in the terminal to stop `flutter run`.

The example's `dispose()` method demonstrates the cleanup expected when its
screen is removed:

- cancel an active upload;
- cancel the progress subscription;
- clear the in-memory API key;
- close the VModal HTTP client; and
- dispose the text controllers.

For logout or account switching in a production app, cancel active operations,
clear the credential provider, close the client, and create a new client for
the next identity.

## How the example is connected to the SDK

The example uses the SDK source from the parent directory rather than a
published package:

```yaml
dependencies:
  vmodal_sdk_flutter:
    path: ..
```

This line in [`pubspec.yaml`](pubspec.yaml) means changes made to the SDK's
`lib/` directory are immediately available to the example after Flutter
refreshes dependencies.

The main learning points in [`lib/main.dart`](lib/main.dart) are:

- `MutableApiKeyProvider` stores the current runtime credential in memory.
- `VmodalClient` provides typed SDK resources.
- `client.auth.me()` resolves the current identity.
- `client.searches.searchVideo()` performs natural-language video search.
- `client.collections.videoUpload()` creates a cancellable upload task.
- `openFile()` supplies an app-readable video path through `file_selector`.
- `client.indexes.createIndex()` and `indexStatus()` expose background work.
- Raw search rows are rendered as compact result cards.
- `rootBundle.load()` copies the bundled sample into a temporary `File`.
- `SdkException` provides SDK and API error details.

## Validate the example without a live API key

From the SDK directory, run:

```bash
bash build.sh pub_get
bash build.sh analyze
bash build.sh test
```

These commands install dependencies, analyze the SDK and example, and run their
offline tests. They do not require a live VModal API key.

To build the example without launching it:

```bash
bash build.sh example_android
```

On a configured Mac, build the iOS simulator application with:

```bash
bash build.sh example_ios
```

## Troubleshooting

### `Pinned Flutter 3.44.6 is not installed`

Run:

```bash
bash install.sh install
```

### No device is available

Start the emulator or simulator, unlock it, and check again:

```bash
flutter_bin="$(bash install.sh flutter_bin)"
"$flutter_bin" devices
```

For Android, also check that Android Studio has installed an Android SDK and
that a physical phone has approved USB debugging.

### `Configure the client first`

Enter the runtime API key and tap **Configure client** before using identity,
search, or upload actions.

### Authentication or network error

Check the status text at the bottom of the application. Confirm that:

- the key is valid and not expired;
- the device has internet access;
- the key belongs to the correct backend environment; and
- the VModal service is reachable from the device.

### `Select an app-accessible file first`

The path is empty, the file does not exist on the mobile device, or the app
cannot read it. Do not use a normal desktop path for a file that has not been
copied or selected inside the device environment.

### Dependency or generated-file errors

Refresh both the SDK and example dependencies:

```bash
bash build.sh pub_get
```

If old build output is causing a problem, clean and retry:

```bash
bash test.sh clean
bash build.sh pub_get
```

## Next steps

- Read the [SDK guide](../docs/sdk_doc.md).
- Learn how to [manage API keys](../docs/manage_api_key.md).
- Follow the [search application guide](../docs/search_app.md).
- Review the [SDK contract](../docs/sdk_contract.md).
