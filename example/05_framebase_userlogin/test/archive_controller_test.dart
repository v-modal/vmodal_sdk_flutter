import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test(
    'archive manifests and imported files stay with their account',
    () async {
      final root = await Directory.systemTemp.createTemp('framebase_test_');
      addTearDown(() => root.delete(recursive: true));
      final a = SearchGateway(MutableApiKeyProvider('fixture-a'), 'alice');
      final b = SearchGateway(MutableApiKeyProvider('fixture-b'), 'bob');
      final c = ArchiveController(supportDirectory: root);
      await c.activate('alice', a, canRead: true, canWrite: true);
      c.clips.first.uploaded = true;
      c.pendingJob = 'alice-job';
      c.record('Alice upload', 'done');
      final src = File('${root.path}/sample.mp4');
      await src.writeAsBytes([1, 2, 3]);
      await c.importFile(src.path, 3);
      await c.save();
      expect(c.clips.last.path, startsWith('${root.path}/accounts/alice/'));
      c.deactivate();
      expect(c.events, isEmpty);
      expect(c.pendingJob, isEmpty);
      await c.activate('bob', b, canRead: true, canWrite: true);
      expect(c.clips, hasLength(3));
      expect(c.clips.first.uploaded, isFalse);
      expect(c.pendingJob, isEmpty);
      expect(c.events, isEmpty);
      await c.activate('alice', a, canRead: true, canWrite: true);
      expect(c.clips, hasLength(4));
      expect(c.clips.first.uploaded, isTrue);
      expect(c.pendingJob, 'alice-job');
      expect(c.events.any((e) => e.title == 'Alice upload'), isTrue);
      final manifest = File('${root.path}/accounts/alice/archive.json');
      expect(await manifest.readAsString(), isNot(contains('fixture-a')));
      await a.close();
      await b.close();
      c.dispose();
    },
  );
}
