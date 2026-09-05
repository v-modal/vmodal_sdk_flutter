import 'package:flutter/material.dart';

import 'controller.dart';
import 'console_view.dart';
import 'gallery_view.dart';
import 'scene.dart';
import 'theme.dart';

void main() => runApp(const SightlineApp());

/// Two demos of the same VModal search flow, sharing one client and one
/// codebase but deliberately nothing else.
class SightlineApp extends StatefulWidget {
  const SightlineApp({super.key});

  @override
  State<SightlineApp> createState() => _SightlineAppState();
}

class _SightlineAppState extends State<SightlineApp> {
  final SightlineController _controller = SightlineController();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller.publishBundledFootage();
    _controller.restore();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (BuildContext context, Widget? _) {
      final Scene scene = scenes[_index];
      final Palette p = scene.palette;
      return MaterialApp(
        title: 'Sightline',
        debugShowCheckedModeBanner: false,
        theme: p.theme,
        home: Scaffold(
          body: SafeArea(
            bottom: false,
            child: IndexedStack(
              sizing: StackFit.expand,
              index: _index,
              children: <Widget>[
                ConsoleView(controller: _controller, scene: trafficScene),
                GalleryView(controller: _controller, scene: archiveScene),
              ],
            ),
          ),
          bottomNavigationBar: _TabBar(
            palette: p,
            index: _index,
            onChanged: (int value) => setState(() => _index = value),
          ),
        ),
      );
    },
  );
}

/// Tab bar that takes on the look of whichever demo is showing.
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.palette,
    required this.index,
    required this.onChanged,
  });

  final Palette palette;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: palette.surface,
      border: Border(top: BorderSide(color: palette.border)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < scenes.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onChanged(i),
                  borderRadius: palette.corner,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          scenes[i].tabIcon,
                          size: 21,
                          color: i == index ? palette.accent : palette.inkMuted,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          scenes[i].tabLabel,
                          style: palette.label(
                            color: i == index
                                ? palette.accent
                                : palette.inkMuted,
                            size: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
