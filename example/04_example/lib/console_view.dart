import 'dart:io';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'scene.dart';
import 'theme.dart';
import 'widgets.dart';

/// Control-room view: dense, monospaced, one frame per row like a log.
class ConsoleView extends StatefulWidget {
  const ConsoleView({required this.controller, required this.scene, super.key});

  final SightlineController controller;
  final Scene scene;

  @override
  State<ConsoleView> createState() => _ConsoleViewState();
}

class _ConsoleViewState extends State<ConsoleView> {
  final TextEditingController _query = TextEditingController();

  Palette get _p => widget.scene.palette;
  SceneState get _state => widget.controller.stateOf(widget.scene);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _run(String query) {
    _query.text = query;
    widget.controller.search(widget.scene, query);
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = _p;
    final SceneState s = _state;
    final bool searchable = s.stage == FootageStage.ready;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('SIGHTLINE', style: p.mono(size: 11, spacing: 3)),
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
        const SizedBox(height: 28),
        Text(widget.scene.title, style: p.display(size: 32)),
        const SizedBox(height: 10),
        Text(
          widget.scene.strapline,
          style: TextStyle(color: p.inkMuted, fontSize: 14.5, height: 1.45),
        ),
        const SizedBox(height: 26),
        _FootageCard(controller: widget.controller, scene: widget.scene),
        const SizedBox(height: 22),
        TextField(
          controller: _query,
          enabled: searchable,
          style: TextStyle(color: p.ink, fontSize: 15),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: searchable
                ? widget.scene.searchHint
                : 'Index some footage first',
            prefixIcon: Icon(Icons.search, color: p.inkMuted, size: 20),
          ),
          onSubmitted: (String value) =>
              widget.controller.search(widget.scene, value),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: widget.scene.exampleQueries
              .map(
                (String q) => InkWell(
                  onTap: searchable ? () => _run(q) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: p.border),
                      borderRadius: p.corner,
                    ),
                    child: Text(
                      q,
                      style: p.mono(
                        size: 12,
                        color: searchable ? p.inkMuted : p.border,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 26),
        if (s.searching)
          ThinProgress(value: 0, palette: p)
        else if (s.searchMessage.isNotEmpty)
          Text(s.searchMessage, style: p.mono(size: 12, color: p.accent))
        else if (s.hasSearched)
          Text(
            '${s.hits.length > shownPerClip ? shownPerClip : s.hits.length}'
            '/${s.hits.length} FRAMES · '
            '${s.elapsedMs.toStringAsFixed(0)} MS',
            style: p.mono(size: 11, spacing: 1.5, color: p.inkMuted),
          ),
        const SizedBox(height: 14),
        for (int i = 0; i < s.hits.length && i < shownPerClip; i++) ...<Widget>[
          _HitRow(hit: s.hits[i], palette: p),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.palette});

  final SearchHit hit;
  final Palette palette;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => FrameDetail.open(context, hit, palette),
    child: Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border),
        borderRadius: palette.corner,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 132,
            height: 76,
            child: FrameImage(hit: hit, palette: palette),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(hit.timeLabel, style: palette.mono(size: 17)),
                const SizedBox(height: 5),
                Text(
                  hit.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: palette.mono(size: 11, color: palette.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Camera card: what is loaded, and whether it is searchable yet.
class _FootageCard extends StatelessWidget {
  const _FootageCard({required this.controller, required this.scene});

  final SightlineController controller;
  final Scene scene;

  @override
  Widget build(BuildContext context) {
    final Palette p = scene.palette;
    final SceneState s = controller.stateOf(scene);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.border),
        borderRadius: p.corner,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Nothing about the feed until there is a key to read it with.
          if (controller.isReady(scene)) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    controller.bundledFootage(scene).isEmpty
                        ? 'NO CLIP BUNDLED'
                        : controller.bundledFootage(scene).first.label,
                    style: p.mono(size: 12, spacing: 1.2),
                  ),
                ),
                _StageBadge(stage: s.stage, palette: p),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Collection: ${controller.collectionFor(scene)}',
              style: p.mono(size: 10, color: p.inkMuted),
            ),
          ],
          if (s.message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
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
                if (controller.uploadedClips(scene).isEmpty) ...<Widget>[
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

class _StageBadge extends StatelessWidget {
  const _StageBadge({required this.stage, required this.palette});

  final FootageStage stage;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final (String text, Color color) = switch (stage) {
      FootageStage.idle => ('NOT INDEXED', palette.inkMuted),
      FootageStage.uploading => ('UPLOADING', palette.accent),
      FootageStage.indexing => ('INDEXING', palette.accent),
      FootageStage.ready => ('SEARCHABLE', readyGreen),
      FootageStage.failed => ('FAILED', const Color(0xFFF87171)),
    };
    final bool working =
        stage == FootageStage.uploading || stage == FootageStage.indexing;
    return Row(
      children: <Widget>[
        if (working)
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          )
        else
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        SizedBox(width: working ? 9 : 7),
        Text(text, style: palette.label(color: color, size: 10)),
      ],
    );
  }
}

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
      controller.isConnected ? 'KEY ACTIVE' : 'NO KEY',
      style: palette.mono(
        size: 11,
        spacing: 1.5,
        color: controller.isConnected ? readyGreen : palette.accent,
      ),
    ),
  );
}
