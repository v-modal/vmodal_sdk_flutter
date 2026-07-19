import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_example/main.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

const _pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void _log(String message) => debugPrint('[sdk_flutter example] $message');

ExampleSearchImage _image(int index, {String? title}) => ExampleSearchImage(
  id: '$index-video.mp4-0000000002000',
  url: 'https://image.test/$index',
  title: title ?? 'Result $index',
  filename: 'video_$index.mp4',
  stream: 'astream',
  timestamp: '0000000002000',
  score: '87.5%',
);

ImageProvider<Object> _memoryImage(String _) =>
    MemoryImage(base64Decode(_pixel));

ImageProvider<Object> _brokenImage(String _) =>
    MemoryImage(Uint8List.fromList(<int>[1, 2, 3]));

Widget _resultsApp(
  List<ExampleSearchImage> images, {
  int total = 2,
  int returned = 2,
  bool searched = true,
  bool searching = false,
  ExampleImageProviderFactory imageProviderFactory = _memoryImage,
  double width = 400,
  double textScale = 1,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 900),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ExampleSearchResults(
                images: images,
                total: total,
                returned: returned,
                elapsedMs: 146,
                hasSearched: searched,
                searching: searching,
                imageProviderFactory: imageProviderFactory,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('example preserves the progressive mobile workflow', (
    WidgetTester tester,
  ) async {
    _log('checking auth, collection, upload, index, and search controls');
    await tester.pumpWidget(const VmodalExampleApp());
    expect(find.widgetWithText(TextField, 'Runtime API key'), findsOneWidget);
    expect(find.text('Configure client'), findsOneWidget);
    expect(find.text('Refresh collections'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Collection'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Stream'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('Choose video'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Create index'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('Search'), findsOneWidget);
  });

  test('search and upload share the example collection contract', () {
    _log('checking request fields shared by the progressive workflow');
    final request = exampleSearchRequest(
      ' bicycle ',
      exampleCollectionName,
      exampleStreamName,
      1,
    );
    expect(request.queryText, 'bicycle');
    expect(request.groupName, exampleCollectionName);
    expect(request.streamName, exampleStreamName);
    expect(request.searchSources, <String>['image']);
    expect(request.versionLancedb, 1);
    expect(request.toJson()['version_lancedb'], 1);

    final index = exampleIndexRequest(exampleCollectionName, exampleStreamName);
    expect(index.groupName, exampleCollectionName);
    expect(index.streamName, exampleStreamName);
    expect(index.indexType, exampleIndexType);
    expect(index.modality, exampleIndexType);
    expect(exampleIndexDone('completed'), isTrue);
    expect(exampleIndexDone('running'), isFalse);
  });

  test('collection names come from authenticated video groups', () {
    _log('checking collection filtering and deterministic sorting');
    final names = exampleCollectionNames(
      GroupsResponse(<String, Object?>{
        'total': 3,
        'data': <Object?>[
          <String, Object?>{'mode': 'vid_file', 'group_name': 'travel'},
          <String, Object?>{'mode': 'img_file', 'group_name': 'images'},
          <String, Object?>{'mode': 'vid_file', 'group_name': 'archive'},
        ],
      }),
    );
    expect(names, <String>['archive', 'travel']);
  });

  test('search 404 is explained without exposing the server body', () {
    _log('checking safe redaction of a missing-index response');
    const path = '/private/server/path/table';
    const error = ApiException(
      'api request failed',
      statusCode: 404,
      body: <String, Object?>{'detail': 'Missing LanceDB table: $path'},
    );
    final message = exampleSearchNotFound(error, exampleCollectionName);
    expect(message, contains('No searchable index exists'));
    expect(message, isNot(contains(path)));
  });

  test('search hits normalize to exact Android-compatible image records', () {
    _log('checking filename, stream, timestamp, title, and score fields');
    final response = SearchResponse(<String, Object?>{
      'cnt_actual': 1,
      'cnt_total': 3,
      'data': <Object?>[
        <String, Object?>{
          'source_path': r'folder\nested/clip.mp4',
          'stream_name': 'custom',
          'ts_unix': '1700000000',
          'effective_title': 'Red bicycle',
          'score_ui': 0.875,
        },
      ],
    });
    final candidate = exampleSearchCandidates(
      response,
      ' videos ',
      ' fallback ',
    ).single;
    expect(candidate.searchIndex, 0);
    expect(candidate.record, <String, Object?>{
      'mode': 'vid_file',
      'group_name': 'videos',
      'modality': 'image',
      'stream_name': 'custom',
      'filename': 'clip.mp4',
      'ts_unix_13digits': '1700000000000',
    });

    final image = exampleSearchImages(
      <ExampleSearchCandidate>[candidate],
      ImageUrlBulkResponse(<String, Object?>{
        'records': <Object?>[
          <String, Object?>{
            'input_index': 0,
            'found': true,
            'url_pre_signed': ' https://image.test/frame ',
          },
        ],
      }),
    ).single;
    expect(image.title, 'Red bicycle');
    expect(image.filename, 'clip.mp4');
    expect(image.stream, 'custom');
    expect(image.timestamp, '1700000000000');
    expect(image.score, '87.5%');
    expect(image.id, isNot(contains(image.url)));
  });

  test('all filename aliases use basename and blank hits are omitted', () {
    _log('checking every documented filename alias and both path separators');
    const keys = <String>[
      'filename',
      'filename_sanitized',
      'video_filename',
      'video',
      'source_path',
      'path',
    ];
    for (final key in keys) {
      final response = SearchResponse(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{key: r'folder\sub/video.mp4'},
        ],
      });
      expect(
        exampleSearchCandidates(response, 'group', 'stream').single.record,
        containsPair('filename', 'video.mp4'),
      );
    }
    final blank = SearchResponse(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{'filename': ' / '},
        <String, Object?>{'title': 'No file'},
      ],
    });
    expect(exampleSearchCandidates(blank, 'group', 'stream'), isEmpty);
  });

  test('timestamps normalize to the 13-digit lookup contract', () {
    _log('checking seconds, milliseconds, long, short, formatted, and blank');
    expect(exampleTimestamp13('1700000000'), '1700000000000');
    expect(exampleTimestamp13('1700000000123'), '1700000000123');
    expect(exampleTimestamp13('170000000012345'), '1700000000123');
    expect(exampleTimestamp13('2000'), '0000000002000');
    expect(exampleTimestamp13('time=2,000ms'), '0000000002000');
    expect(exampleTimestamp13(''), '');
  });

  test(
    'bulk mapping validates indexes, ordering, found state, and duplicates',
    () {
      _log(
        'checking identity-safe input_index association under partial output',
      );
      final response = SearchResponse(<String, Object?>{
        'data': List<Object?>.generate(
          4,
          (int index) => <String, Object?>{
            'filename': 'video_$index.mp4',
            'title': 'Title $index',
          },
        ),
      });
      final candidates = exampleSearchCandidates(response, 'group', 'stream');
      final images = exampleSearchImages(
        candidates,
        ImageUrlBulkResponse(<String, Object?>{
          'records': <Object?>[
            <String, Object?>{
              'input_index': '2',
              'url_pre_signed': 'https://image.test/2',
            },
            <String, Object?>{
              'input_index': 0.0,
              'url_pre_signed': 'https://image.test/0',
            },
            <String, Object?>{
              'input_index': '2',
              'url_pre_signed': 'https://image.test/duplicate',
            },
            <String, Object?>{
              'input_index': -1,
              'url_pre_signed': 'https://image.test/negative',
            },
            <String, Object?>{
              'input_index': 9,
              'url_pre_signed': 'https://image.test/large',
            },
            <String, Object?>{
              'input_index': 'bad',
              'url_pre_signed': 'https://image.test/malformed',
            },
            <String, Object?>{
              'input_index': 1,
              'found': false,
              'url_pre_signed': 'https://image.test/not-found',
            },
            <String, Object?>{'input_index': 3, 'url_pre_signed': ' '},
          ],
        }),
      );
      expect(images.map((ExampleSearchImage image) => image.title), <String>[
        'Title 0',
        'Title 2',
      ]);
      expect(images.last.url, 'https://image.test/2');
    },
  );

  test('missing input_index uses only bounded positional fallback', () {
    _log('checking compatibility fallback without cross-hit association');
    final candidates = exampleSearchCandidates(
      SearchResponse(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{'filename': 'zero.mp4'},
          <String, Object?>{'filename': 'one.mp4'},
        ],
      }),
      'group',
      'stream',
    );
    final images = exampleSearchImages(
      candidates,
      ImageUrlBulkResponse(<String, Object?>{
        'records': <Object?>[
          <String, Object?>{'url_pre_signed': 'https://image.test/zero'},
          <String, Object?>{'url_pre_signed': 'https://image.test/one'},
          <String, Object?>{'url_pre_signed': 'https://image.test/outside'},
        ],
      }),
    );
    expect(images.map((ExampleSearchImage image) => image.filename), <String>[
      'zero.mp4',
      'one.mp4',
    ]);
  });

  test('more than five search hits remain eligible for one bulk lookup', () {
    _log('checking removal of the old hidden five-card truncation');
    final response = SearchResponse(<String, Object?>{
      'data': List<Object?>.generate(
        12,
        (int index) => <String, Object?>{'filename': 'video_$index.mp4'},
      ),
    });
    expect(exampleSearchRows(response), hasLength(12));
    expect(exampleSearchCandidates(response, 'group', 'stream'), hasLength(12));
  });

  testWidgets('result area distinguishes initial, loading, and empty states', (
    WidgetTester tester,
  ) async {
    _log('checking all global result-area messages and summary counts');
    await tester.pumpWidget(
      _resultsApp(const <ExampleSearchImage>[], searched: false),
    );
    expect(find.byKey(const Key('search-summary')), findsNothing);
    expect(find.text('No matching results.'), findsNothing);

    await tester.pumpWidget(
      _resultsApp(
        const <ExampleSearchImage>[],
        searched: false,
        searching: true,
      ),
    );
    expect(find.text('Searching and resolving images...'), findsOneWidget);

    await tester.pumpWidget(
      _resultsApp(const <ExampleSearchImage>[], total: 0, returned: 0),
    );
    expect(
      find.text('Showing 0 images from 0 matches • 146 ms'),
      findsOneWidget,
    );
    expect(find.text('No matching results.'), findsOneWidget);

    await tester.pumpWidget(
      _resultsApp(const <ExampleSearchImage>[], total: 12, returned: 8),
    );
    expect(
      find.text('Showing 0 images from 12 matches (8 returned) • 146 ms'),
      findsOneWidget,
    );
    expect(find.text('No image-backed matches were found.'), findsOneWidget);
  });

  testWidgets('resolved images render metadata without duplicate filename', (
    WidgetTester tester,
  ) async {
    _log('checking image card content and conditional metadata sections');
    final images = <ExampleSearchImage>[
      _image(0),
      const ExampleSearchImage(
        id: '1-same.mp4-',
        url: 'https://image.test/1',
        title: 'same.mp4',
        filename: 'same.mp4',
        stream: '',
        timestamp: '',
        score: '',
      ),
    ];
    await tester.pumpWidget(_resultsApp(images));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-image-grid')), findsOneWidget);
    expect(find.byType(ExampleSearchImageCard), findsNWidgets(2));
    expect(find.text('Result 0'), findsOneWidget);
    expect(find.text('video_0.mp4'), findsOneWidget);
    expect(find.text('astream • 0000000002000 • 87.5%'), findsOneWidget);
    expect(find.text('same.mp4'), findsOneWidget);
  });

  testWidgets('one failed image stays local and preserves sibling cards', (
    WidgetTester tester,
  ) async {
    _log('checking per-card image failure without a global result error');
    await tester.pumpWidget(
      _resultsApp(
        <ExampleSearchImage>[_image(0), _image(1)],
        imageProviderFactory: (String url) =>
            url.endsWith('/0') ? _brokenImage(url) : _memoryImage(url),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Image unavailable'), findsOneWidget);
    expect(find.byType(ExampleSearchImageCard), findsNWidgets(2));
    expect(find.text('Result 1'), findsOneWidget);
  });

  testWidgets('grid adapts from one narrow column to multiple wide columns', (
    WidgetTester tester,
  ) async {
    _log('checking responsive max-extent layout and single scroll ownership');
    final images = List<ExampleSearchImage>.generate(4, _image);
    await tester.pumpWidget(_resultsApp(images, width: 260));
    await tester.pumpAndSettle();
    final narrow0 = tester.getTopLeft(
      find.byKey(Key('search-image-${images[0].id}')),
    );
    final narrow1 = tester.getTopLeft(
      find.byKey(Key('search-image-${images[1].id}')),
    );
    expect(narrow0.dx, narrow1.dx);
    expect(narrow1.dy, greaterThan(narrow0.dy));

    await tester.pumpWidget(_resultsApp(images, width: 700));
    await tester.pumpAndSettle();
    final wide0 = tester.getTopLeft(
      find.byKey(Key('search-image-${images[0].id}')),
    );
    final wide1 = tester.getTopLeft(
      find.byKey(Key('search-image-${images[1].id}')),
    );
    expect(wide0.dy, wide1.dy);
    expect(wide1.dx, greaterThan(wide0.dx));
    final grid = tester.widget<GridView>(
      find.byKey(const Key('search-image-grid')),
    );
    expect(grid.shrinkWrap, isTrue);
    expect(grid.physics, isA<NeverScrollableScrollPhysics>());
    expect(grid.gridDelegate, isA<SliverGridDelegateWithMaxCrossAxisExtent>());
  });

  testWidgets('long text and accessibility remain bounded at large scale', (
    WidgetTester tester,
  ) async {
    _log('checking ellipsis, large text, image semantics, and overflow safety');
    final semantics = tester.ensureSemantics();
    final image = ExampleSearchImage(
      id: 'long-video.mp4-0000000002000',
      url: 'https://image.test/long',
      title: List<String>.filled(20, 'Long searchable title').join(' '),
      filename: List<String>.filled(10, 'long_filename').join('_'),
      stream: 'astream',
      timestamp: '0000000002000',
      score: '87.5%',
    );
    await tester.pumpWidget(
      _resultsApp(<ExampleSearchImage>[image], width: 260, textScale: 1.8),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.bySemanticsLabel('Search result image: ${image.title}'),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
