import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final docsRoot = Directory('docs_sdk');
final internalDocs = docsRoot.existsSync() && File('docs.py').existsSync();

final requiredDocs = <String>[
  'README.md',
  'index.html',
  'index.json',
  'vmodal_sdk_flutter/index.html',
  'vmodal_sdk_flutter/VmodalClient-class.html',
  'vmodal_sdk_flutter/VmodalClient/VmodalClient.html',
  'vmodal_sdk_flutter/VmodalClient/close.html',
  'vmodal_sdk_flutter/CollectionsResource/listGroups.html',
  'vmodal_sdk_flutter/CollectionUploads/videoUpload.html',
  'vmodal_sdk_flutter/UploadTask-class.html',
];

final forbiddenDocs = <String>[
  'swagger.yaml',
  'swagger-ui',
  'openapi:',
  'operationid',
  'x-flutter-sdk-method',
  'class="summary source-code"',
  'id="source"',
  'routes-class.html',
  'routespec',
  'routecategory',
  'publicgatewayurl',
  'publicgatewayurlhash',
  'devgatewayurl',
  'searchapi-test.v-modal.com',
  '/api/v1',
  '/api/external/v1',
  '&#47;api&#47;v1',
  '&#47;api&#47;external&#47;v1',
  '&#x2f;api&#x2f;v1',
  '&#x2f;api&#x2f;external&#x2f;v1',
];

Iterable<File> docsTextFiles() sync* {
  const suffixes = <String>{
    '.css',
    '.html',
    '.js',
    '.json',
    '.md',
    '.svg',
    '.txt',
    '.xml',
  };
  for (final entity in docsRoot.listSync(recursive: true)) {
    if (entity is File &&
        suffixes.any((String suffix) => entity.path.endsWith(suffix))) {
      yield entity;
    }
  }
}

void main() {
  test('generated SDK reference contains required navigation and pages', () {
    if (!internalDocs) return;
    stdout.writeln('[docs] checking ${requiredDocs.length} required pages');
    expect(docsRoot.existsSync(), isTrue);
    for (final path in requiredDocs) {
      expect(File('${docsRoot.path}/$path').existsSync(), isTrue, reason: path);
    }
    expect(File('${docsRoot.path}/index.json').lengthSync(), greaterThan(1000));
  });

  test('search inventory exposes representative public SDK symbols', () {
    if (!internalDocs) return;
    final rows =
        jsonDecode(File('${docsRoot.path}/index.json').readAsStringSync())
            as List<Object?>;
    final names = rows
        .cast<Map<String, Object?>>()
        .map((Map<String, Object?> row) => '${row['qualifiedName']}')
        .toSet();
    const expected = <String>[
      'vmodal_sdk_flutter.VmodalClient',
      'vmodal_sdk_flutter.SearchesResource.searchVideo',
      'vmodal_sdk_flutter.CollectionUploads.videoUpload',
      'vmodal_sdk_flutter.UploadTask',
      'vmodal_sdk_flutter.SdkException',
    ];
    stdout.writeln('[docs] index entries=${rows.length}');
    for (final name in expected) {
      expect(names, contains(name), reason: name);
    }
  });

  test('generated text contains no endpoints or implementation source', () {
    if (!internalDocs) return;
    var count = 0;
    for (final file in docsTextFiles()) {
      count++;
      final text = utf8.decode(file.readAsBytesSync()).toLowerCase();
      for (final value in forbiddenDocs) {
        expect(text, isNot(contains(value)), reason: '${file.path}: $value');
      }
    }
    stdout.writeln('[docs] endpoint-free text files checked=$count');
    expect(count, greaterThan(100));
  });

  test('documentation commands use one deterministic Dartdoc pipeline', () {
    if (!internalDocs) return;
    final generator = File('docs.py').readAsStringSync();
    expect(generator, contains('dart, "doc", "--validate-links"'));
    expect(generator, contains('os_sanitize_dartdoc(site)'));
    expect(generator, contains('os_compare_trees(dest, site)'));
    expect(generator, isNot(contains('swagger_operations')));
    expect(generator, isNot(contains('routes_contract.json')));
  });

  test('maintainer docs use SDK reference terminology', () {
    if (!internalDocs) return;
    for (final path in <String>[
      'README_PRIVATE.md',
      'docs/release.md',
      'docs/sdk_doc.md',
    ]) {
      final text = File(path).readAsStringSync().toLowerCase();
      expect(text, isNot(contains('swagger')), reason: path);
      expect(text, isNot(contains('openapi')), reason: path);
      expect(text, isNot(contains('docs_swagger')), reason: path);
      expect(text, contains('docs_sdk'), reason: path);
    }
  });
}
