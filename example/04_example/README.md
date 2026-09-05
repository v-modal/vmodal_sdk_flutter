# Sightline

Search inside video by describing what you are looking for. 

Two demos of the
[VModal Flutter SDK](https://github.com/v-modal/vmodal_sdk_flutter) in one app,
running on iOS and Android from the same codebase.



## The two demos

**Traffic camera — find the moment in one video.** A fixed camera films the same
junction for a long time. Describe what you are looking for and get the frames
back with the time in the clip. "pedestrians on a zebra crossing" returns the
crowd mid-crossing at 00:13.

**Find the correct video — which clip has it.** Several clips in one collection.
Search once and see which clip holds the shot, and where. Results group by clip,
each with a strip of matching frames. You can search with a picture instead of
words.

## Running it

```bash
flutter pub get
flutter run
```

You need your own VModal API key: request one at
[v-modal.com/contact](https://www.v-modal.com/contact).

On first launch each tab asks for the key and a collection name. The collection
is inside your own account and is created on first upload, so any name works.
Then **Upload and index** sends the bundled clips, and search unlocks when
indexing finishes.

The key is held in memory for the session. The setup sheet can keep it on the
device if you switch that on, in a plain JSON file in the app's documents
directory. That is a demo convenience: a real app should use the platform
keychain.

`tool/dev_run.sh` builds, installs and launches on a booted iOS simulator.

## Screenshots and tests

`integration_test/` drives each tab end to end and hands off to `tool/shoot.sh`,
which captures the device screen. One command regenerates a whole set:

```bash
OUT=shots tool/shoot.sh &
flutter drive --driver test_driver/integration_test.dart \
  --target integration_test/traffic_walkthrough_test.dart -d <device>
```

## What testing the SDK turned up

Worth knowing if you build on it. All measured against the live API, not guessed.

- **A video search row carries no `filename`.** It has `title`, and sometimes
  that is empty too. The image lookup needs a name, so the only remaining source
  is `item_id`, which reads `astream-<name>-<13-digit-ts>`. Without that fallback
  results silently vanish: a clip uploaded from the device ranked top for every
  query and showed nothing.
- **`/image/get_image` needs `ts_unix_13digits` even when the frame time is all
  zeros.** Leave it out and it answers `ts_unix_13digits required for video modes`.
- **`modality` must be `vid_img` for `mode=vid_file`.** The backend says so.
- **`textEmbScoreMin` does not filter.** 0.9, 0.5 and 0.0 return identical results.
- **`score` is a distance, so lower is better**, which the name implies backwards.
  `score_ui` is that distance normalised inside the returned batch, so the top hit
  always reads 1.0. It is not a confidence and this app does not show it as one.
- **The score does not measure whether the subject is present.** `a person` scores
  0.875 on a clip full of people; `a giraffe` scores 0.877 on the same clip with
  none. So the relevance cut-offs in `lib/scene.dart` are tuned against the bundled
  footage and may need different numbers for yours.
- **Frame count follows visual change, not length.** A 26 second clip of a bird
  indexed to 22 frames; a 60 second clip of ocean waves indexed to 1. Long static
  shots are the worst case.
- **`image_query` takes base64 image bytes.** Undocumented, and the SDK's own
  example never uses it. It works well.
- **There is no endpoint that lists a collection's contents**, so the uploaded list
  in this app is built from names the server returns in search results.

## Footage

All stock footage, free to use, downscaled to 720p with audio stripped. Three
links are still to be added; open an issue if you need a source before then.

| File | Source |
| --- | --- |
| `assets/footage/traffic_01.mp4` | Pexels video 15643210 |
| `assets/footage/cat_01.mp4` | Pexels video 149552 |
| `assets/footage/bird_01.mp4` | Pexels, link pending |
| `assets/footage/ocean_01.mp4` | Pexels, link pending |
| `assets/footage/peppers_01.mp4` | Pexels, link pending |
| `assets/queries/bird.jpg` | Pexels photo 3491309 |
| `assets/queries/sunset.jpg` | Pexels photo 656967 |
| `assets/queries/clouds.jpg` | Pixabay photo 7050884 |

## Licence

MIT. See [LICENSE](LICENSE).
