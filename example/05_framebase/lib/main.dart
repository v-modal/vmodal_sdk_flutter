import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'data/archive_controller.dart';
import 'data/search_gateway.dart';

const paper = Color(0xFFECE9E2);
const ink = Color(0xFF252C29);
const green = Color(0xFFAA4F2D);
const secondary = Color(0xFF706F67);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: paper,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const FramebaseApp());
}

class FramebaseApp extends StatelessWidget {
  const FramebaseApp({super.key, this.controller});
  final ArchiveController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Framebase',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Instrument Sans',
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        surface: paper,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: paper,
      appBarTheme: const AppBarTheme(
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -.6,
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink),
        bodySmall: TextStyle(color: secondary),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFDDDFD6),
        thickness: .5,
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(Color(0xFFDFDCD4)),
        hintStyle: const WidgetStatePropertyAll(
          TextStyle(color: secondary, fontSize: 16),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: paper,
        showDragHandle: true,
        modalBarrierColor: Color(0x66000000),
      ),
    ),
    home: LibraryPage(controller: controller),
  );
}

String city(ArchiveClip clip) => clip.location.split(' · ').first;

/// Only the toolbar and overlays blur underlying content. The library itself is flat.
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.child,
    this.dark = false,
    this.radius = 0,
  });
  final Widget child;
  final bool dark;
  final double radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: ColoredBox(
        color: dark ? const Color(0xA6252C29) : const Color(0xDDECE9E2),
        child: child,
      ),
    ),
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.controller});
  final ArchiveController? controller;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final ArchiveController archive;
  @override
  void initState() {
    super.initState();
    archive = widget.controller ?? ArchiveController();
    unawaited(start());
  }

  Future<void> start() async {
    if (!archive.initialized) await archive.initialize();
  }

  @override
  void dispose() {
    if (widget.controller == null) archive.dispose();
    super.dispose();
  }

  void openSearch() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => SearchPage(archive: archive)),
  );

  Future<void> importVideo() async {
    if (archive.busy) return;
    VideoPlayerController? player;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'MP4 video',
            extensions: ['mp4'],
            mimeTypes: ['video/mp4'],
            uniformTypeIdentifiers: ['public.mpeg-4'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 100 * 1024 * 1024) {
        throw const FormatException();
      }
      player = VideoPlayerController.file(File(file.path));
      await player.initialize().timeout(const Duration(seconds: 15));
      await archive.importFile(
        file.path,
        player.value.duration.inMilliseconds / 1000,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Video added. Prepare it for search when you’re ready.',
            ),
          ),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a playable MP4 smaller than 100 MB.'),
          ),
        );
      }
    } finally {
      await player?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: archive,
    builder: (context, _) => Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandMark(),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'Framebase',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        flexibleSpace: const Frosted(child: SizedBox.expand()),
        actions: [
          IconButton(
            key: const Key('import'),
            tooltip: 'Add video',
            onPressed: archive.busy ? null : importVideo,
            icon: const Icon(Icons.add),
          ),
          PopupMenuButton<String>(
            key: const Key('library_menu'),
            tooltip: 'More options',
            onSelected: (value) {
              if (value == 'connection') showConnection(context, archive);
              if (value == 'history') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => HistoryPage(archive: archive),
                  ),
                );
              }
              if (value == 'prepare') prepareArchive(context, archive);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'connection',
                child: Text('Search settings'),
              ),
              PopupMenuItem(
                value: 'prepare',
                child: Text('Prepare videos for search'),
              ),
              PopupMenuItem(value: 'history', child: Text('Sync history')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 16,
          16,
          96,
        ),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Street footage',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${archive.clips.length} videos',
                style: const TextStyle(color: secondary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final clip in archive.clips)
            VideoRow(
              clip: clip,
              onTap: () => showRecording(context, archive, clip),
            ),
          if (archive.busy) ...[
            const SizedBox(height: 12),
            WorkStatus(archive: archive),
          ],
          if (archive.connected && !archive.ready && !archive.busy) ...[
            const SizedBox(height: 20),
            TextButton.icon(
              key: const Key('process'),
              onPressed: () => prepareArchive(context, archive),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Prepare videos for search'),
            ),
          ],
          if (archive.connected &&
              archive.ready &&
              archive.clips.any((c) => !c.bundled && !c.uploaded) &&
              !archive.busy)
            TextButton.icon(
              onPressed: () => prepareArchive(context, archive),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Prepare added videos'),
            ),
          if (archive.events.isNotEmpty && archive.events.first.error)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                archive.notice,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      extendBody: true,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SearchDock(onTap: openSearch),
        ),
      ),
    ),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 23,
    height: 23,
    child: CustomPaint(painter: _BrandPainter()),
  );
}

class _BrandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = green
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(2, 9)
        ..lineTo(2, 2)
        ..lineTo(9, 2)
        ..moveTo(14, 2)
        ..lineTo(21, 2)
        ..lineTo(21, 9)
        ..moveTo(21, 14)
        ..lineTo(21, 21)
        ..lineTo(14, 21)
        ..moveTo(9, 21)
        ..lineTo(2, 21)
        ..lineTo(2, 14),
      paint,
    );
    canvas.drawLine(const Offset(9, 8), const Offset(15, 12), paint);
    canvas.drawLine(const Offset(15, 12), const Offset(9, 16), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SearchDock extends StatelessWidget {
  const SearchDock({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      boxShadow: const [
        BoxShadow(
          color: Color(0x30212A24),
          blurRadius: 22,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: Frosted(
      dark: true,
      radius: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Colors.white.withValues(alpha: .28),
            width: .8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('open_search'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
              child: Row(
                children: [
                  const Icon(Icons.search, color: Colors.white, size: 23),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Search your videos',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6A17F),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(
                      Icons.arrow_forward,
                      color: ink,
                      size: 21,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class VideoRow extends StatelessWidget {
  const VideoRow({super.key, required this.clip, required this.onTap});
  final ArchiveClip clip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Semantics(
      button: true,
      label: 'Play ${clip.title}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: 1.8,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipPoster(clip),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [.4, 1],
                    colors: [Colors.transparent, Color(0xD919201C)],
                  ),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: TimeBadge(seconds: clip.duration),
              ),
              Positioned(
                left: 16,
                bottom: 16,
                right: 70,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clip.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.4,
                        height: 1.12,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      city(clip),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFDFE5DF),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Frosted(
                  dark: true,
                  radius: 13,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .3),
                        width: .7,
                      ),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(onTap: onTap),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ClipPoster extends StatelessWidget {
  const ClipPoster(this.clip, {super.key});
  final ArchiveClip clip;
  @override
  Widget build(BuildContext context) => clip.poster.isNotEmpty
      ? Image.asset(
          clip.poster,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const MissingFrame(),
        )
      : const MissingFrame(icon: Icons.movie_outlined);
}

class MissingFrame extends StatelessWidget {
  const MissingFrame({
    super.key,
    this.icon = Icons.image_not_supported_outlined,
  });
  final IconData icon;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFE0E3DA),
    child: Center(child: Icon(icon, color: secondary, size: 28)),
  );
}

class TimeBadge extends StatelessWidget {
  const TimeBadge({super.key, required this.seconds});
  final double seconds;
  @override
  Widget build(BuildContext context) => Frosted(
    dark: true,
    radius: 6,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      child: Text(
        timeLabel(seconds),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
  );
}

/// Keep relevance order, but collapse nearby frames of the same recording.
Map<String, List<FrameMatch>> groupMoments(List<FrameMatch> hits) {
  final groups = <String, List<FrameMatch>>{};
  for (final hit in hits) {
    final moments = groups.putIfAbsent(hit.filename, () => []);
    final t = hit.seconds;
    if (moments.any(
      (m) => t != null && m.seconds != null && (t - m.seconds!).abs() < 6,
    )) {
      continue;
    }
    moments.add(hit);
  }
  return groups;
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.archive});
  final ArchiveController archive;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final query = TextEditingController();
  bool broad = false;
  final expandedVideos = <String>{};
  ArchiveController get archive => widget.archive;
  @override
  void initState() {
    super.initState();
    query.text = archive.activeQuery;
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> search([String? text]) async {
    expandedVideos.clear();
    if (text != null) query.text = text;
    FocusManager.instance.primaryFocus?.unfocus();
    if (query.text.trim().isEmpty) return;
    if (archive.connecting) return;
    if (!archive.connected) {
      await showConnection(context, archive);
      if (!mounted || !archive.connected) return;
    }
    if (!archive.ready) {
      await prepareArchive(context, archive);
      return;
    }
    await archive.search(query.text, maxDistance: broad ? 1.5 : .85);
  }

  void options() => showModalBottomSheet<void>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, update) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('Include looser matches'),
              subtitle: const Text(
                'Useful if the first search misses something.',
              ),
              value: broad,
              onChanged: (v) {
                setState(() => broad = v);
                update(() {});
                archive.invalidateSearch();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Search details'),
              onTap: () {
                Navigator.pop(ctx);
                showSearchDetails(context, archive);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: archive,
    builder: (context, _) {
      final batch = archive.batch;
      final groups = groupMoments(batch?.matches ?? []);
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 80,
          titleSpacing: 8,
          title: SearchBar(
            controller: query,
            hintText: 'Describe a moment',
            leading: IconButton(
              tooltip: 'Back to videos',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            onChanged: (_) => archive.invalidateSearch(),
            onSubmitted: (_) => search(),
            trailing: [
              IconButton(
                key: const Key('run_search'),
                tooltip: archive.searching ? 'Cancel search' : 'Search',
                icon: Icon(archive.searching ? Icons.close : Icons.search),
                onPressed: archive.searching
                    ? archive.invalidateSearch
                    : () => search(),
              ),
            ],
          ),
          actions: [
            IconButton(
              key: const Key('search_options'),
              tooltip: 'Search options',
              onPressed: options,
              icon: const Icon(Icons.more_vert),
            ),
          ],
        ),
        body: Column(
          children: [
            if (archive.searching || archive.connecting)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  if (archive.busy) WorkStatus(archive: archive),
                  if (batch == null && !archive.searching) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Try a search',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    for (final example in [
                      'People crossing the street',
                      'A bus on a city street',
                      'Cars at an intersection',
                    ])
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.search, size: 20),
                        title: Text(
                          example,
                          style: const TextStyle(fontSize: 15),
                        ),
                        trailing: const Icon(Icons.north_west, size: 18),
                        onTap: () => search(example),
                      ),
                  ],
                  if (batch != null && groups.isEmpty) ...[
                    const SizedBox(height: 56),
                    const Text(
                      'No matching moments',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Try a different description.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: secondary),
                    ),
                    if (!broad)
                      Center(
                        child: TextButton(
                          onPressed: () {
                            setState(() => broad = true);
                            search();
                          },
                          child: const Text('Include looser matches'),
                        ),
                      ),
                  ],
                  if (groups.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '${groups.length} ${groups.length == 1 ? 'video' : 'videos'}',
                        style: const TextStyle(color: secondary),
                      ),
                    ),
                    for (final entry in groups.entries) ...[
                      Text(
                        archive.clipFor(entry.key)?.title ?? entry.key,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        archive.clipFor(entry.key) == null
                            ? 'Not stored on this device'
                            : city(archive.clipFor(entry.key)!),
                        style: const TextStyle(color: secondary, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final count = constraints.maxWidth >= 600 ? 3 : 2;
                          return GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: count,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 16 / 10,
                                ),
                            itemCount: expandedVideos.contains(entry.key)
                                ? entry.value.length
                                : entry.value.length.clamp(0, 2),
                            itemBuilder: (_, i) => MomentTile(
                              key: Key('moment_${entry.key}_$i'),
                              hit: entry.value[i],
                              onTap: () {
                                final clip = archive.clipFor(entry.key);
                                if (clip != null) {
                                  showRecording(
                                    context,
                                    archive,
                                    clip,
                                    match: entry.value[i],
                                    moments: entry.value,
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'This video is not stored on this device.',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          );
                        },
                      ),
                      if (entry.value.length > 2)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: Key('expand_${entry.key}'),
                            onPressed: () => setState(() {
                              if (!expandedVideos.add(entry.key)) {
                                expandedVideos.remove(entry.key);
                              }
                            }),
                            child: Text(
                              expandedVideos.contains(entry.key)
                                  ? 'Show fewer moments'
                                  : 'Show ${entry.value.length - 2} more moments',
                            ),
                          ),
                        ),
                      const SizedBox(height: 28),
                    ],
                  ],
                  if (archive.notice.isNotEmpty &&
                      archive.events.isNotEmpty &&
                      archive.events.first.error)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        archive.notice,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class MomentTile extends StatelessWidget {
  const MomentTile({super.key, required this.hit, required this.onTap});
  final FrameMatch hit;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label:
        'Play at ${hit.seconds == null ? 'unknown time' : timeLabel(hit.seconds!)}',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hit.imageBytes != null)
            Image.memory(
              hit.imageBytes!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const MissingFrame(),
            )
          else if (hit.imageUrl != null)
            Image.network(
              hit.imageUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const MissingFrame(),
            )
          else
            const MissingFrame(),
          if (hit.seconds != null)
            Positioned(
              bottom: 7,
              right: 7,
              child: TimeBadge(seconds: hit.seconds!),
            ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> showRecording(
  BuildContext context,
  ArchiveController archive,
  ArchiveClip clip, {
  FrameMatch? match,
  List<FrameMatch> moments = const [],
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => RecordingSheet(
    archive: archive,
    clip: clip,
    match: match,
    moments: moments,
  ),
);

class RecordingSheet extends StatefulWidget {
  const RecordingSheet({
    super.key,
    required this.archive,
    required this.clip,
    this.match,
    this.moments = const [],
  });
  final ArchiveController archive;
  final ArchiveClip clip;
  final FrameMatch? match;
  final List<FrameMatch> moments;
  @override
  State<RecordingSheet> createState() => _RecordingSheetState();
}

class _RecordingSheetState extends State<RecordingSheet> {
  VideoPlayerController? player;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    VideoPlayerController? next;
    try {
      final file = await widget.archive.localFile(widget.clip);
      next = VideoPlayerController.file(file);
      await next.initialize().timeout(const Duration(seconds: 20));
      if (!mounted) {
        await next.dispose();
        return;
      }
      final seconds = widget.match?.seconds;
      if (seconds != null &&
          seconds <= next.value.duration.inMilliseconds / 1000) {
        await next.seekTo(Duration(milliseconds: (seconds * 1000).round()));
      }
      if (!mounted) {
        await next.dispose();
        return;
      }
      next.addListener(refresh);
      setState(() => player = next);
    } on Object {
      await next?.dispose();
      if (mounted) setState(() => error = 'This video could not be opened.');
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    player?.removeListener(refresh);
    unawaited(player?.dispose() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = player;
    final length = p?.value.duration.inMilliseconds.toDouble() ?? 0;
    final position = (p?.value.position.inMilliseconds.toDouble() ?? 0).clamp(
      0.0,
      length,
    );
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.clip.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          city(widget.clip),
                          style: const TextStyle(color: secondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close recording',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: p?.value.aspectRatio ?? 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (p != null)
                        VideoPlayer(p)
                      else
                        ClipPoster(widget.clip),
                      if (p == null && error == null)
                        const Center(child: CircularProgressIndicator()),
                      if (p != null)
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: PlaybackControls(player: p),
                        ),
                    ],
                  ),
                ),
              ),
              if (error != null)
                Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
              if (p != null) ...[
                if (widget.moments.length > 1) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Other moments',
                    style: TextStyle(color: secondary),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 86,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.moments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final hit = widget.moments[i];
                        final active =
                            hit.seconds != null &&
                            (position / 1000 - hit.seconds!).abs() < 3;
                        return Container(
                          width: 118,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(
                              color: active ? green : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: MomentTile(
                            hit: hit,
                            onTap: () {
                              if (hit.seconds != null) {
                                p.seekTo(
                                  Duration(
                                    milliseconds: (hit.seconds! * 1000).round(),
                                  ),
                                );
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class PlaybackControls extends StatelessWidget {
  const PlaybackControls({super.key, required this.player});
  final VideoPlayerController player;
  @override
  Widget build(BuildContext context) {
    final value = player.value;
    final length = value.duration.inMilliseconds.toDouble();
    final position = value.position.inMilliseconds.toDouble().clamp(
      0.0,
      length,
    );
    return Frosted(
      dark: true,
      radius: 12,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Row(
          children: [
            IconButton(
              key: const Key('play_pause'),
              tooltip: value.isPlaying ? 'Pause' : 'Play',
              onPressed: () => value.isPlaying ? player.pause() : player.play(),
              icon: Icon(
                value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: const Color(0xFFF2B28F),
                  inactiveTrackColor: Colors.white30,
                  thumbColor: Colors.white,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  value: position,
                  max: length > 0 ? length : 1,
                  semanticFormatterCallback: (v) => timeLabel(v / 1000),
                  onChanged: (v) =>
                      player.seekTo(Duration(milliseconds: v.round())),
                ),
              ),
            ),
            Text(
              '${timeLabel(position / 1000)} / ${timeLabel(length / 1000)}',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showConnection(BuildContext context, ArchiveController archive) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ConnectionSheet(archive: archive),
    );

class ConnectionSheet extends StatefulWidget {
  const ConnectionSheet({super.key, required this.archive});
  final ArchiveController archive;
  @override
  State<ConnectionSheet> createState() => _ConnectionSheetState();
}

class _ConnectionSheetState extends State<ConnectionSheet> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    final value = input.text.trim();
    if (value.isEmpty) return;
    input.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    final ok = await widget.archive.connect(value);
    if (mounted && ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.archive,
    builder: (context, _) => SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Search settings',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            Text(
              widget.archive.connected
                  ? 'Connected to the search service.'
                  : 'Connect to search inside your videos.',
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('api_key'),
              controller: input,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              onSubmitted: (_) => connect(),
              decoration: const InputDecoration(
                labelText: 'API key',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (widget.archive.notice.isNotEmpty && !widget.archive.connected)
              Text(widget.archive.notice),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.archive.connected)
                  TextButton(
                    onPressed: widget.archive.busy || widget.archive.connecting
                        ? null
                        : () async {
                            await widget.archive.disconnect();
                            if (context.mounted) Navigator.pop(context);
                          },
                    child: const Text('Disconnect'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('connect_button'),
                  onPressed: widget.archive.busy || widget.archive.connecting
                      ? null
                      : connect,
                  child: Text(
                    widget.archive.connecting ? 'Connecting…' : 'Connect',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> prepareArchive(
  BuildContext context,
  ArchiveController archive,
) async {
  if (archive.busy) return;
  if (!archive.connected) {
    await showConnection(context, archive);
    if (!context.mounted || !archive.connected) return;
  }
  if (archive.pendingJob.isNotEmpty) {
    unawaited(archive.resumeIndex());
    return;
  }
  final count = archive.clips.where((c) => !c.uploaded).length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Prepare videos for search?'),
      content: Text(
        count == 0
            ? 'Rebuild the visual index for these videos?'
            : '$count videos will be uploaded to the search service. This can take a minute.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Prepare'),
        ),
      ],
    ),
  );
  if (confirmed == true) unawaited(archive.uploadAndIndex());
}

class WorkStatus extends StatelessWidget {
  const WorkStatus({super.key, required this.archive});
  final ArchiveController archive;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        LinearProgressIndicator(value: archive.progress, minHeight: 3),
        Row(
          children: [
            Expanded(
              child: Text(archive.phase, style: const TextStyle(fontSize: 13)),
            ),
            TextButton(
              onPressed: archive.stopWork,
              child: Text(
                archive.pendingJob.isEmpty ? 'Cancel' : 'Stop waiting',
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.archive});
  final ArchiveController archive;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: archive,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Sync history')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (archive.busy)
            Padding(
              padding: const EdgeInsets.all(16),
              child: WorkStatus(archive: archive),
            ),
          if (archive.events.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No uploads or searches yet.'),
            ),
          for (final event in archive.events)
            ListTile(
              leading: Icon(
                event.error ? Icons.error_outline : Icons.check,
                size: 20,
              ),
              title: Text(event.title),
              subtitle: Text(event.detail),
            ),
        ],
      ),
    ),
  );
}

Future<void> showSearchDetails(
  BuildContext context,
  ArchiveController archive,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) {
    final batch = archive.batch;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Search details', style: TextStyle(fontSize: 22)),
            const SizedBox(height: 16),
            if (batch == null)
              const Text('Run a search first.')
            else ...[
              Text(
                'Server results: ${batch.total}\nWithin distance filter: ${batch.matches.length}\n'
                'Search request: ${batch.roundTripMs} ms\nServer execution: ${batch.serverMs.toStringAsFixed(0)} ms\n'
                'Frame retrieval: ${batch.imageMs} ms',
              ),
              const SizedBox(height: 16),
              const Text(
                'Nearby frames from the same video are combined in the results. Distance is similarity, not confidence.',
              ),
            ],
          ],
        ),
      ),
    );
  },
);
