import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_v2ray/flutter_v2ray_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_v2ray');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native status query preserves state, traffic, and session identity',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getV2RayStatus');
            return <String, Object>{
              'duration': '00:02:03',
              'uploadSpeed': '123',
              'downloadSpeed': '456',
              'upload': '789',
              'download': '1024',
              'state': 'CONNECTED',
              'error': '',
              'sessionId': 'native-session-1',
              'generation': '1700000000000',
            };
          });

      final status = await FlutterV2rayPlatform.instance.getV2RayStatus();

      expect(status.duration, '00:02:03');
      expect(status.uploadSpeed, 123);
      expect(status.downloadSpeed, 456);
      expect(status.upload, 789);
      expect(status.download, 1024);
      expect(status.state, 'CONNECTED');
      expect(status.sessionId, 'native-session-1');
      expect(status.generation, 1700000000000);
    },
  );

  test(
    'native status query failures are not coerced to disconnected',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(
              code: 'STATUS_QUERY_TIMEOUT',
              message: 'timed out',
            );
          });

      await expectLater(
        FlutterV2rayPlatform.instance.getV2RayStatus(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'STATUS_QUERY_TIMEOUT',
          ),
        ),
      );
    },
  );
}
