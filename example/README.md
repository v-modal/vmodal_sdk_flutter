# VModal Flutter example

This small application shows the basic VModal SDK workflow on Android or iOS:

1. Create a client with a runtime API key.
2. Confirm which user is authenticated.
3. Search videos with a natural-language query.
4. Upload the bundled 10-frame sample video while displaying progress.
5. Cancel an upload if needed.

The example is intentionally simple. It keeps all UI and SDK calls in
[`lib/main.dart`](lib/main.dart), so a beginner can follow the complete flow in
one file.

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

## 6. Configure the VModal client

When the application opens:

1. Paste a valid runtime API key into **Runtime API key**.
2. Tap **Configure client**.
3. Check the status message at the bottom of the screen.

The expected status is:

```text
Client configured. Resolve identity or search next.
```

The input is obscured, and the example clears the text field after creating
the client. The key remains only in `MutableApiKeyProvider` memory while the
application is running.

## 7. Confirm authentication

Tap **Resolve auth.me**.

The example calls:

```dart
final me = await client.auth.me();
```

A successful request displays the authenticated user type. If you receive an
SDK error instead, check that the key is valid, has not expired, and belongs to
the intended VModal environment.

## 8. Run a search

1. Leave the default query, `red bicycle`, or enter your own description.
2. Tap **Search**.
3. Read the result count in the status area.

The example sends:

```dart
final result = await client.searches.searchVideo(
  SearchRequest(queryText: query),
);
```

A result count of zero is still a successful request; it only means the user's
current video collection has no matching items.

## 9. Upload the bundled sample video

The repository includes
[`asset/video_10frames.mp4`](asset/video_10frames.mp4), a one-second, 320 × 240
H.264 video with exactly 10 frames of moving colored zebra stripes. It is small
enough to use as a quick upload example.

At startup, the example reads this Flutter asset, copies it to the app's
temporary directory, and fills **App-accessible file path** with the copied
file's absolute path. This copy is necessary because the upload SDK accepts a
`File`, while a bundled Flutter asset is not directly exposed as a normal
mobile file.

To try it:

1. Wait until the status says **Bundled 10-frame sample video is ready.**
2. Configure the client if you have not already done so.
3. Leave the pre-filled path unchanged.
4. Tap **Upload**.
5. Watch the progress bar and final status message.
6. Tap **Cancel** while an upload is running to test cancellation. The sample
   is very small, so it may finish before you can cancel it.

The upload is stored under:

```text
collection:     flutter_example
sub-collection: astream
```

To upload your own video instead, replace the pre-filled value with an absolute
path returned by a file picker, camera flow, downloaded file, or app-owned
documents/cache directory. A path on your computer is normally not valid
inside an Android emulator, Android phone, iOS simulator, or iPhone. The mobile
app must be able to read the file in its own environment.

This example does not include a file-picker package because file picking
belongs to the parent application.

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

## 10. Stop and clean up

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
