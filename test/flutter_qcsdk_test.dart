import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qcsdk/flutter_qcsdk.dart';

void main() {
  const MethodChannel channel = MethodChannel('flutter_qcsdk/methods');

  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (methodCall.method == 'isPeripheralFreeNow') {
        return true;
      }
      return null;
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('isPeripheralFreeNow returns true', () async {
    final result = await FlutterQcsdk.isPeripheralFreeNow();
    expect(result, isTrue);
    expect(log, <Matcher>[
      isMethodCall('isPeripheralFreeNow', arguments: null),
    ]);
  });
}
