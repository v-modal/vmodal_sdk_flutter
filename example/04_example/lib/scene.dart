import 'package:flutter/material.dart';

import 'theme.dart';

/// One bundled clip, with the attribution it must carry.
@immutable
class FootageClip {
  const FootageClip({
    required this.asset,
    required this.label,
    required this.credit,
  });

  final String asset;

  /// Shown in the UI, e.g. a camera name or a clip title.
  final String label;

  /// Source and licence. Every clip in this app is CC0 stock.
  final String credit;

  String get fileName => asset.split('/').last;
}

/// A complete demo: the story, the footage, the queries and the look.
@immutable
class Scene {
  const Scene({
    required this.id,
    required this.tabLabel,
    required this.tabIcon,
    required this.title,
    required this.strapline,
    required this.sourceLabel,
    required this.suggestedCollection,
    required this.footage,
    this.exampleQueries = const <String>[],
    required this.searchHint,
    this.relevanceWindow = 0.03,
    this.relevanceCeiling = 0.87,
    required this.explainer,
    required this.steps,
    required this.palette,
  });

  final String id;
  final String tabLabel;
  final IconData tabIcon;
  final String title;
  final String strapline;

  /// Label above the footage card: the camera, or the reel.
  final String sourceLabel;

  /// Suggested collection name, offered in the setup sheet. The one actually
  /// used is whatever the user types, since a collection belongs to their key.
  final String suggestedCollection;

  final List<FootageClip> footage;

  /// Tappable queries, where the demo benefits from suggesting a few. Each one
  /// must have an obvious hit in the bundled clips, or the demo undersells the
  /// SDK. Leave empty for a scene that reads better without them.
  final List<String> exampleQueries;

  final String searchHint;

  /// How far past the best frame's distance to keep others. Tight suits one
  /// camera, where the number of moments should mean something. Loose suits an
  /// archive, where the question is which clips hold the shot at all and
  /// cutting to the single best clip answers the wrong question.
  final double relevanceWindow;

  /// Absolute distance past which nothing is shown, whatever the best match
  /// was. Stops an absurd query returning a confident-looking page.
  final double relevanceCeiling;

  /// What this demo is for, in two sentences. Shown in the info panel so a
  /// screenshot of it explains the tab on its own.
  final String explainer;

  /// Three short steps shown before the first search, so the empty screen
  /// explains the demo instead of looking unfinished.
  final List<String> steps;

  final Palette palette;
}

/// Traffic camera: an hour of junction footage, find the moment that matters.
const Scene trafficScene = Scene(
  id: 'traffic',
  tabLabel: 'Traffic',
  tabIcon: Icons.videocam_outlined,
  title: 'Traffic camera',
  strapline: 'Describe the moment. Go straight to the frame.',
  sourceLabel: 'Camera feed',
  suggestedCollection: 'traffic_camera',
  footage: <FootageClip>[
    FootageClip(
      asset: 'assets/footage/traffic_01.mp4',
      label: 'CAM 04 — CITY JUNCTION',
      credit: 'Pexels video 15643210, free to use — see README',
    ),
  ],
  // Verified against the bundled clip: each of these returns frames that
  // visibly contain what was asked for. Short object nouns do not work well —
  // describe the moment, not the object.
  exampleQueries: <String>[
    'pedestrians on a zebra crossing',
    'a bus waiting at the junction',
    'a taxi',
  ],
  searchHint: 'Describe what you are looking for',
  explainer: 'One camera. Hours of footage. Find the moment.',
  steps: <String>['Upload a clip', 'Describe the moment', 'Open the frame'],
  palette: consolePalette,
);

/// Archive: many clips, and no idea which one holds the shot you want.
const Scene archiveScene = Scene(
  id: 'archive',
  tabLabel: 'Archive',
  tabIcon: Icons.video_library_outlined,
  title: 'Find the correct video',
  strapline: 'Which clip has the shot you need?',
  sourceLabel: 'Archive',
  suggestedCollection: 'media_archive',
  // Several clips indexed together. Results say which clip each frame is from,
  // which is the job here: find the clip, not the moment.
  // The junction clip is the same file the traffic tab uses, indexed here as
  // one of several rather than on its own.
  footage: <FootageClip>[
    FootageClip(
      asset: 'assets/footage/traffic_01.mp4',
      label: 'City junction',
      credit: 'Pexels video 15643210, free to use — see README',
    ),
    FootageClip(
      asset: 'assets/footage/ocean_01.mp4',
      label: 'Ocean',
      credit: 'Pexels, free to use — see README',
    ),
    FootageClip(
      asset: 'assets/footage/peppers_01.mp4',
      label: 'Cutting peppers',
      credit: 'Pexels, free to use — see README',
    ),
    FootageClip(
      asset: 'assets/footage/bird_01.mp4',
      label: 'Bird',
      credit: 'Pexels, free to use — see README',
    ),
    FootageClip(
      asset: 'assets/footage/cat_01.mp4',
      label: 'Cat',
      credit: 'Pexels, free to use — see README',
    ),
  ],
  searchHint: 'Describe a shot in the archive',
  // Measured across these five clips. Clips that genuinely hold the subject
  // score 0.70 to 0.87; clips that do not start at 0.885. So the ceiling sits
  // at 0.88: it keeps the ocean clip for "clouds" at 0.870, and drops the
  // junction clip for "animal" at 0.906, which a looser 0.92 let through.
  relevanceWindow: 0.15,
  relevanceCeiling: 0.88,
  explainer: 'Many clips. One search. Find which one.',
  steps: <String>[
    'Upload your clips',
    'Describe it, or use a picture',
    'See which clip has it',
  ],
  palette: galleryPalette,
);

const List<Scene> scenes = <Scene>[trafficScene, archiveScene];

/// Pictures shipped for trying the image search, published to the device's
/// files alongside the footage so the picker can see them.
const List<String> queryImages = <String>[
  'assets/queries/bird.jpg',
  'assets/queries/sunset.jpg',
  'assets/queries/clouds.jpg',
];
