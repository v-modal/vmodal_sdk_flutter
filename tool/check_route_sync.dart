import 'dart:convert';
import 'dart:io';

import 'package:vmodal_sdk_flutter/src/routes.dart';

void main() {
  final root = _packageRoot();
  final fixtureFile = File('${root.path}/test/fixtures/routes_contract.json');
  final upstream = File(
    '${root.path}/../../../vmx_avideo/infra/search_api_ui/routers/apionly_routes.py',
  );
  final images = File(
    '${root.path}/../../../vmx_avideo/infra/search_api_ui/routers/apionly_serve_img.py',
  );
  if (!fixtureFile.existsSync()) _fail('route fixture is unavailable');
  final fixture = (jsonDecode(fixtureFile.readAsStringSync()) as List)
      .map((Object? item) => Map<String, Object?>.from(item! as Map))
      .toList();
  final normalized =
      Routes.specs
          .map(
            (RouteSpec spec) => <String, Object?>{
              'category': spec.category.name,
              'method': spec.method,
              'name': spec.name,
              'path': spec.path,
              'source': spec.source,
            },
          )
          .toList()
        ..sort(
          (Map<String, Object?> a, Map<String, Object?> b) =>
              '${a['name']}'.compareTo('${b['name']}'),
        );
  _same(fixture, normalized, 'fixture differs from Routes.specs');
  if (!upstream.existsSync() || !images.existsSync()) {
    stdout.writeln(
      'local route contract OK: ${fixture.length} classified operations; '
      'upstream source unavailable',
    );
    return;
  }

  final source = upstream.readAsStringSync();
  final block = RegExp(
    r'class apiEndpoints:[\s\S]*?(?=\n\n# [─#]|\n@dataclass\nclass UserCtx)',
  ).firstMatch(source)?.group(0);
  final endpointBlock = block ?? _fail('apiEndpoints block was not found');
  final declared = RegExp(r'^\s+([a-z_]+): str = "([^"]+)"', multiLine: true)
      .allMatches(endpointBlock)
      .map((RegExpMatch match) => match.group(2)!)
      .toSet();
  final upstreamRows = fixture
      .where((Map<String, Object?> row) => row['source'] == 'upstream')
      .map((Map<String, Object?> row) => '${row['path']}')
      .toSet();
  final missingDeclared = declared.difference(upstreamRows);
  if (missingDeclared.isNotEmpty) {
    _fail('missing upstream declarations: $missingDeclared');
  }

  final active = _decorators(source, commented: false);
  final representedActive = fixture
      .where(
        (Map<String, Object?> row) =>
            row['source'] == 'upstream' &&
            (row['category'] == 'active' || row['category'] == 'deprecated'),
      )
      .map(_wireKey)
      .toSet();
  final missingActive = active.difference(representedActive);
  if (missingActive.isNotEmpty) {
    _fail('missing active upstream routes: $missingActive');
  }

  final imageActive = _decorators(images.readAsStringSync(), commented: false);
  final imageRows = fixture
      .where((Map<String, Object?> row) => row['category'] == 'image')
      .map(_wireKey)
      .toSet();
  _same(
    imageActive.toList()..sort(),
    imageRows.toList()..sort(),
    'image routes differ from upstream',
  );

  final names = fixture.map((Map<String, Object?> row) => row['name']).toList();
  if (names.toSet().length != names.length) _fail('duplicate route name');
  final sorted = List<Object?>.from(names)
    ..sort((Object? a, Object? b) => '$a'.compareTo('$b'));
  _same(names, sorted, 'fixture is not sorted by name');
  stdout.writeln('route contract OK: ${fixture.length} classified operations');
}

Directory _packageRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) _fail('package root was not found');
    dir = parent;
  }
  return dir;
}

Set<String> _decorators(String source, {required bool commented}) {
  final prefix = commented ? r'#\s*' : '';
  final pattern = RegExp(
    '^$prefix@router\\.(get|post|delete)\\("([^"]+)"',
    multiLine: true,
  );
  return pattern
      .allMatches(source)
      .map(
        (RegExpMatch match) =>
            '${match.group(1)!.toUpperCase()} ${match.group(2)}',
      )
      .toSet();
}

String _wireKey(Map<String, Object?> row) => '${row['method']} ${row['path']}';

Never _fail(String message) {
  throw StateError(message);
}

void _same(Object? actual, Object? expected, String message) {
  if (jsonEncode(actual) != jsonEncode(expected)) _fail(message);
}
