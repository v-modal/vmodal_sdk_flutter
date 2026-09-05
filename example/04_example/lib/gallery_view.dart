import 'dart:io';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'scene.dart';
import 'theme.dart';
import 'widgets.dart';

/// Gallery view: pale ground, serif headings, results as a grid of frames.
class GalleryView extends StatefulWidget {
  const GalleryView({required this.controller, required this.scene, super.key});

  final SightlineController controller;
  final Scene scene;

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  final TextEditingController _query = TextEditingController();

  Palette get _p => widget.scene.palette;
  SceneState get _state => widget.controller.stateOf(widget.scene);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = _p;
    final SceneState s = _state;
    final bool searchable = s.stage == FootageStage.ready;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 36),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('SIGHTLINE ARCHIVE', style: p.label()),
            const Spacer(),
            _KeyState(
              controller: widget.controller,
              scene: widget.scene,
              palette: p,
            ),
            const SizedBox(width: 14),
            IconAction(
              icon: Icons.info_outline,
              palette: p,
              tooltip: 'How it works',
              onTap: () => HowItWorks.open(context, widget.scene),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(widget.scene.title, style: p.display(size: 31)),
        const SizedBox(height: 14),
        Text(
          widget.scene.strapline,
          style: TextStyle(color: p.inkMuted, fontSize: 16, height: 1.5),
        ),
        const SizedBox(height: 26),
        _ReelRow(
          controller: widget.controller,
          scene: widget.scene,
          collapsed: s.hasSearched,
        ),
        const SizedBox(height: 26),
        _SearchBar(
          controller: _query,
          palette: p,
          enabled: searchable,
          hint: searchable
              ? widget.scene.searchHint
              : 'Index some footage first',
          onSubmit: (String value) =>
              widget.controller.search(widget.scene, value),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: searchable
                ? () async {
                    final ({File? file, String? error}) picked =
                        await pickImage();
                    if (picked.error != null) {
                      widget.controller.reportProblem(
                        widget.scene,
                        picked.error!,
                      );
                    } else if (picked.file != null) {
                      _query.clear();
                      await widget.controller.searchByImage(
                        widget.scene,
                        picked.file!,
                      );
                    }
                  }
                : null,
            icon: const Icon(Icons.image_search_outlined, size: 18),
            label: const Text('Search by image'),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.accent,
              side: BorderSide(color: p.border),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: p.corner),
            ),
          ),
        ),
        const SizedBox(height: 30),
        if (s.searching)
          ThinProgress(value: 0, palette: p)
        else if (s.searchMessage.isNotEmpty)
          Text(
            s.searchMessage,
            style: TextStyle(color: p.accent, fontSize: 13.5),
          )
        else if (s.hasSearched)
          Row(
            children: <Widget>[
              if (s.queryImage != null) ...<Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    s.queryImage!,
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Text('${_byClip(s.hits).length}', style: p.display(size: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.queryImage != null
                      ? (_byClip(s.hits).length == 1
                            ? 'clip matches this picture'
                            : 'clips match this picture')
                      : (_byClip(s.hits).length == 1
                            ? 'clip has "${s.query}"'
                            : 'clips have "${s.query}"'),
                  style: TextStyle(color: p.inkMuted, fontSize: 14),
                ),
              ),
              Text(
                '${s.elapsedMs.toStringAsFixed(0)} ms',
                style: p.mono(size: 11, color: p.inkMuted),
              ),
            ],
          ),
        const SizedBox(height: 18),
        for (final (String clip, List<SearchHit> hits) in _byClip(s.hits))
          _ClipStrip(
            title: clipNameFor(widget.scene, clip),
            hits: hits,
            palette: p,
            matched: s.framesPerClip[clip] ?? hits.length,
          ),
      ],
    );
  }
}

/// Whether a key is loaded, and a way to enter or drop one.
class _KeyState extends StatelessWidget {
  const _KeyState({
    required this.controller,
    required this.scene,
    required this.palette,
  });

  final SightlineController controller;
  final Scene scene;
  final Palette palette;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => controller.isConnected
        ? controller.signOut()
        : SetupSheet.show(context, controller, scene),
    child: Text(
      controller.isConnected ? 'Key active' : 'No key',
      style: TextStyle(
        color: controller.isConnected ? readyGreen : palette.accent,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// A clip's friendly name where the app happens to bundle it, otherwise the
/// name the server gave.
String clipNameFor(Scene scene, String title) =>
    scene.footage
        .where((FootageClip c) => c.fileName.startsWith('$title.'))
        .map((FootageClip c) => c.label)
        .firstOrNull ??
    title;

/// One video's matches: a title line, then a row of frames that scrolls
/// sideways. Sideways so several videos fit on screen at once, which is the
/// whole point of this tab.
class _ClipStrip extends StatelessWidget {
  const _ClipStrip({
    required this.title,
    required this.hits,
    required this.palette,
    required this.matched,
  });

  final String title;
  final List<SearchHit> hits;
  final Palette palette;

  /// Frames this clip returned before the relevance cut.
  final int matched;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: palette.display(size: 17),
              ),
            ),
            Text(
              '${hits.length}/$matched frames',
              style: palette.mono(size: 11, color: palette.inkMuted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: hits.length,
            separatorBuilder: (BuildContext _, int _) =>
                const SizedBox(width: 10),
            itemBuilder: (BuildContext context, int i) =>
                _FrameTile(hit: hits[i], palette: palette),
          ),
        ),
      ],
    ),
  );
}

/// One frame in a strip, with the time it was captured sitting on it.
class _FrameTile extends StatelessWidget {
  const _FrameTile({required this.hit, required this.palette});

  final SearchHit hit;
  final Palette palette;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => FrameDetail.open(context, hit, palette),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(10),
      // Two and a half across, so it is obvious the row keeps going.
      child: SizedBox(
        width: 136,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            FrameImage(hit: hit, palette: palette),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
                child: Text(
                  hit.timeLabel,
                  style: palette.mono(size: 12, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Groups hits by the clip they came from, keeping the clips in the order
/// their best frame was ranked. That ordering is the point of this demo: the
/// clip most likely to hold the shot comes first.
List<(String, List<SearchHit>)> _byClip(List<SearchHit> hits) {
  final Map<String, List<SearchHit>> grouped = <String, List<SearchHit>>{};
  for (final SearchHit hit in hits) {
    grouped.putIfAbsent(hit.fileName, () => <SearchHit>[]).add(hit);
  }
  return grouped.entries
      .map((MapEntry<String, List<SearchHit>> e) => (e.key, e.value))
      .toList();
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.palette,
    required this.hint,
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final Palette palette;
  final String hint;
  final bool enabled;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: palette.border),
    ),
    padding: const EdgeInsets.only(left: 20, right: 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            textInputAction: TextInputAction.search,
            style: TextStyle(color: palette.ink, fontSize: 16),
            decoration: InputDecoration(
              hintText: hint,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 18),
            ),
            onSubmitted: onSubmit,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
            color: enabled ? palette.accent : palette.border,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? () => onSubmit(controller.text) : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.arrow_forward,
                  color: palette.onAccent,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ReelRow extends StatelessWidget {
  const _ReelRow({
    required this.controller,
    required this.scene,
    this.collapsed = false,
  });

  final SightlineController controller;
  final Scene scene;

  /// After a search the results matter more than the inventory, so the card
  /// shrinks to a line rather than pushing them off the screen.
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final Palette p = scene.palette;
    final SceneState s = controller.stateOf(scene);
    final bool ready = s.stage == FootageStage.ready;
    final List<String> uploaded = controller.uploadedClips(scene);
    if (collapsed && uploaded.isNotEmpty) {
      return Row(
        children: <Widget>[
          Icon(Icons.check_circle, size: 15, color: readyGreen),
          const SizedBox(width: 8),
          Text(
            '${uploaded.length} videos uploaded',
            style: TextStyle(
              color: p.ink,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              controller.collectionFor(scene),
              style: p.mono(size: 10, color: p.inkMuted),
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: p.corner,
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                uploaded.isEmpty
                    ? 'NOTHING UPLOADED'
                    : '${uploaded.length} '
                          '${uploaded.length == 1 ? "VIDEO" : "VIDEOS"} '
                          'UPLOADED',
                style: p.label(),
              ),
              const Spacer(),
              if (s.stage == FootageStage.uploading ||
                  s.stage == FootageStage.indexing) ...<Widget>[
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    valueColor: AlwaysStoppedAnimation<Color>(p.accent),
                  ),
                ),
                const SizedBox(width: 9),
              ],
              Text(
                switch (s.stage) {
                  FootageStage.uploading => 'Uploading',
                  FootageStage.indexing => 'Indexing',
                  FootageStage.ready => 'Indexed',
                  FootageStage.failed => 'Failed',
                  FootageStage.idle => 'Not indexed',
                },
                style: TextStyle(
                  color: ready ? readyGreen : p.inkMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (uploaded.isEmpty)
            Text(
              'Nothing uploaded yet.',
              style: TextStyle(color: p.inkMuted, fontSize: 13),
            )
          else
            Column(
              children: <Widget>[
                for (final String title in uploaded)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.check_circle, size: 16, color: readyGreen),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            clipNameFor(scene, title),
                            style: TextStyle(color: p.ink, fontSize: 14),
                          ),
                        ),
                        Text(title, style: p.mono(size: 10, color: p.inkMuted)),
                      ],
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            'Collection: ${controller.collectionFor(scene)}',
            style: p.mono(size: 10, color: p.inkMuted),
          ),
          if (s.message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              s.message,
              style: TextStyle(color: p.inkMuted, fontSize: 13, height: 1.4),
            ),
          ],
          if (s.stage == FootageStage.uploading) ...<Widget>[
            const SizedBox(height: 12),
            ThinProgress(value: s.uploadFraction, palette: p),
          ],
          if (!controller.isReady(scene)) ...<Widget>[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: () => SetupSheet.show(context, controller, scene),
                child: Text(
                  controller.isConnected
                      ? 'Set the collection'
                      : 'Add your key',
                ),
              ),
            ),
          ] else if (s.stage != FootageStage.uploading &&
              s.stage != FootageStage.indexing) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                if (uploaded.isEmpty) ...<Widget>[
                  FilledButton(
                    onPressed: () => controller.prepare(scene),
                    child: const Text('Upload and index'),
                  ),
                  const SizedBox(width: 8),
                ],
                TextButton(
                  onPressed: () async {
                    final ({List<File> files, String? error}) picked =
                        await pickVideos();
                    if (picked.error != null) {
                      controller.reportProblem(scene, picked.error!);
                    } else if (picked.files.isNotEmpty) {
                      await controller.prepare(scene, files: picked.files);
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: p.accent),
                  child: const Text('Choose a video'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
