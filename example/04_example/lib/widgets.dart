import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'scene.dart';
import 'settings.dart';
import 'theme.dart';

/// Asks for the two things only the user can supply: their API key and the
/// collection to work in. Both are theirs; nothing about either is shipped.
class SetupSheet extends StatefulWidget {
  const SetupSheet({required this.controller, required this.scene, super.key});

  final SightlineController controller;
  final Scene scene;

  static Future<void> show(
    BuildContext context,
    SightlineController controller,
    Scene scene,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scene.palette.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(scene.palette.radius * 2),
      ),
    ),
    builder: (BuildContext _) =>
        SetupSheet(controller: controller, scene: scene),
  );

  @override
  State<SetupSheet> createState() => _SetupSheetState();
}

class _SetupSheetState extends State<SetupSheet> {
  final TextEditingController _key = TextEditingController();
  final TextEditingController _collection = TextEditingController();
  bool _remember = false;
  String? _collectionError;

  Palette get _p => widget.scene.palette;

  @override
  void initState() {
    super.initState();
    final Settings saved = widget.controller.settings;
    _key.text = saved.apiKey;
    // Empty on a first run: the collection belongs to the user's account, so
    // the scene's name is only a hint in the field.
    _collection.text = saved.collections[widget.scene.id] ?? '';
    _remember = saved.remember;
  }

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    _collection.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String value = data?.text?.trim() ?? '';
    if (value.isNotEmpty) setState(() => _key.text = value);
  }

  Future<void> _submit() async {
    final String? problem = validateCollection(_collection.text);
    setState(() => _collectionError = problem);
    if (problem != null) return;
    final bool ok = await widget.controller.applySetup(
      scene: widget.scene,
      apiKey: _key.text,
      collection: _collection.text,
      remember: _remember,
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = _p;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('VMODAL API KEY', style: p.label(color: p.inkMuted)),
            const SizedBox(height: 10),
            TextField(
              key: const Key('setup-api-key'),
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: widget.controller.settings.apiKey.isEmpty,
              style: p.mono(size: 14),
              decoration: InputDecoration(
                hintText: 'ak_...',
                suffixIcon: TextButton(
                  onPressed: _paste,
                  style: TextButton.styleFrom(foregroundColor: p.accent),
                  child: const Text('Paste'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Masked as you type. Get one at v-modal.com/contact.',
              style: TextStyle(color: p.inkMuted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 22),
            Text('COLLECTION', style: p.label(color: p.inkMuted)),
            const SizedBox(height: 10),
            TextField(
              key: const Key('setup-collection'),
              controller: _collection,
              autocorrect: false,
              enableSuggestions: false,
              style: p.mono(size: 14),
              decoration: InputDecoration(
                hintText: widget.scene.suggestedCollection,
                errorText: _collectionError,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Text(
              'Where this tab uploads and searches, inside your own account. '
              'Letters, digits and underscore.',
              style: TextStyle(color: p.inkMuted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 18),
            InkWell(
              onTap: () => setState(() => _remember = !_remember),
              child: Row(
                children: <Widget>[
                  Switch.adaptive(
                    value: _remember,
                    activeThumbColor: p.accent,
                    onChanged: (bool value) =>
                        setState(() => _remember = value),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Remember on this device. Kept in a plain file, so only '
                      'do it on a device you trust.',
                      style: TextStyle(
                        color: p.inkMuted,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.controller.connectError != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                widget.controller.connectError!,
                style: TextStyle(color: p.accent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: widget.controller.isConnecting ? null : _submit,
              child: Text(
                widget.controller.isConnecting ? 'Connecting' : 'Connect',
              ),
            ),
            if (widget.controller.settings.remember) ...<Widget>[
              const SizedBox(height: 4),
              TextButton(
                onPressed: () {
                  widget.controller.forgetSaved();
                  Navigator.of(context).pop();
                },
                style: TextButton.styleFrom(foregroundColor: p.inkMuted),
                child: const Text('Forget what is saved'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lets the user pick video files to upload.
Future<({List<File> files, String? error})> pickVideos() async {
  try {
    final List<XFile> picked = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(
          label: 'video',
          // Apple platforms need the UTIs; the others use extensions or MIME.
          uniformTypeIdentifiers: <String>['public.movie'],
          extensions: <String>['mp4', 'mov', 'm4v'],
          mimeTypes: <String>['video/mp4', 'video/quicktime'],
        ),
      ],
    );
    return (
      files: picked.map((XFile file) => File(file.path)).toList(),
      error: null,
    );
  } on Object catch (error) {
    return (files: const <File>[], error: 'Could not open the picker: $error');
  }
}

/// Picks one picture to search with.
Future<({File? file, String? error})> pickImage() async {
  try {
    final XFile? picked = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(
          label: 'image',
          uniformTypeIdentifiers: <String>['public.image'],
          extensions: <String>['jpg', 'jpeg', 'png', 'heic', 'webp'],
          mimeTypes: <String>['image/jpeg', 'image/png', 'image/webp'],
        ),
      ],
    );
    return (file: picked == null ? null : File(picked.path), error: null);
  } on Object catch (error) {
    return (file: null, error: 'Could not open the picker: $error');
  }
}

/// Small round icon button that matches whichever scene is showing.
class IconAction extends StatelessWidget {
  const IconAction({
    required this.icon,
    required this.palette,
    required this.onTap,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final Palette palette;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? '',
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: palette.border),
        ),
        child: Icon(icon, size: 16, color: palette.inkMuted),
      ),
    ),
  );
}

/// Explains the demo on demand, so the screen itself stays quiet.
class HowItWorks extends StatelessWidget {
  const HowItWorks({required this.scene, super.key});

  final Scene scene;

  static void open(BuildContext context, Scene scene) => showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext _) => HowItWorks(scene: scene),
  );

  @override
  Widget build(BuildContext context) {
    final Palette p = scene.palette;
    return Dialog(
      backgroundColor: p.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: p.corner),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(height: 3, color: p.accent),
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(scene.title.toUpperCase(), style: p.label(size: 10)),
                    const SizedBox(height: 12),
                    Text('What this does', style: p.display(size: 26)),
                    const SizedBox(height: 14),
                    Text(
                      scene.explainer,
                      style: TextStyle(
                        color: p.inkMuted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    for (int i = 0; i < scene.steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: p.accent.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '${i + 1}',
                                style: p.mono(size: 12, color: p.accent),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  scene.steps[i],
                                  style: TextStyle(
                                    color: p.ink,
                                    fontSize: 14.5,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 6),
                    Divider(color: p.border, height: 1),
                    const SizedBox(height: 16),
                    Text(
                      'Indexing happens once and stays on the server.',
                      style: TextStyle(
                        color: p.inkMuted,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Divider(color: p.border, height: 1),
                    const SizedBox(height: 14),
                    Text(
                      'VModal Flutter SDK. Bring your own key, v-modal.com/contact.',
                      style: TextStyle(
                        color: p.inkMuted,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(foregroundColor: p.accent),
                        child: const Text('Got it'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin progress line, used while footage uploads.
class ThinProgress extends StatelessWidget {
  const ThinProgress({required this.value, required this.palette, super.key});

  final double value;
  final Palette palette;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: LinearProgressIndicator(
      value: value == 0 ? null : value,
      minHeight: 3,
      backgroundColor: palette.border,
      valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
    ),
  );
}

/// One returned frame. Falls back to a neutral block if bytes are missing.
class FrameImage extends StatelessWidget {
  const FrameImage({
    required this.hit,
    required this.palette,
    this.fit = BoxFit.cover,
    super.key,
  });

  final SearchHit hit;
  final Palette palette;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (hit.bytes == null) {
      return ColoredBox(
        color: palette.border,
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 18,
            color: palette.inkMuted,
          ),
        ),
      );
    }
    return Image.memory(
      hit.bytes!,
      fit: fit,
      gaplessPlayback: true,
      semanticLabel: 'Frame at ${hit.timeLabel} from ${hit.fileName}',
    );
  }
}

/// Full-bleed view of one frame with its metadata.
class FrameDetail extends StatelessWidget {
  const FrameDetail({required this.hit, required this.palette, super.key});

  final SearchHit hit;
  final Palette palette;

  static void open(BuildContext context, SearchHit hit, Palette palette) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (BuildContext _) => FrameDetail(hit: hit, palette: palette),
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: palette.surface,
    insetPadding: const EdgeInsets.all(20),
    shape: RoundedRectangleBorder(borderRadius: palette.corner),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AspectRatio(
          aspectRatio: 16 / 9,
          child: FrameImage(hit: hit, palette: palette, fit: BoxFit.contain),
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(hit.timeLabel, style: palette.mono(size: 20)),
              const SizedBox(height: 8),
              Text(
                hit.fileName,
                style: TextStyle(color: palette.inkMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
