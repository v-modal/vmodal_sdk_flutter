import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_example/main.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  testWidgets('example requires runtime injection', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const VmodalExampleApp());
    expect(find.widgetWithText(TextField, 'Runtime API key'), findsOneWidget);
    expect(find.text('Configure client'), findsOneWidget);
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
    final request = exampleSearchRequest(
      ' bicycle ',
      exampleCollectionName,
      exampleStreamName,
    );
    expect(request.queryText, 'bicycle');
    expect(request.groupName, exampleCollectionName);
    expect(request.streamName, exampleStreamName);
    expect(request.searchSources, <String>['image']);

    final index = exampleIndexRequest(exampleCollectionName, exampleStreamName);
    expect(index.groupName, exampleCollectionName);
    expect(index.streamName, exampleStreamName);
    expect(index.indexType, exampleIndexType);
    expect(index.modality, exampleIndexType);
  });

  test('search 404 is explained without exposing the server body', () {
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

  test('index states and search result fields are presentation ready', () {
    expect(exampleIndexDone('completed'), isTrue);
    expect(exampleIndexDone('running'), isFalse);
    final response = SearchResponse(<String, Object?>{
      'cnt_actual': 1,
      'cnt_total': 1,
      'data': <Object?>[
        <String, Object?>{
          'effective_title': 'Red frame',
          'item_id': 'fallback-id',
          'source': 'image',
          'ts_unix': '2000',
          'score_ui': 0.875,
        },
      ],
    });
    final row = exampleSearchRows(response).single;
    expect(exampleResultTitle(row), 'Red frame');
    expect(exampleResultDetails(row), 'IMAGE • timestamp 2000 • score 87.5%');
  });
}
