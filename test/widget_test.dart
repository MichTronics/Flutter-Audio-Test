import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_audio_vu/main.dart';

void main() {
  testWidgets('VU app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VuMeterApp());

    expect(find.text('VU METER'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
  });
}
