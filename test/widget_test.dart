import 'package:flutter_test/flutter_test.dart';
import 'package:smart_health_sport/main.dart';

void main() {
  testWidgets('SMART HEALTH SPORT tampil',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartHealthSport());

    expect(find.byType(SmartHealthSport), findsOneWidget);
  });
}