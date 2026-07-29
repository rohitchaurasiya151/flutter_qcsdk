import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_qcsdk_platform_interface.dart';

/// An implementation of [FlutterQcsdkPlatform] that uses method channels.
class MethodChannelFlutterQcsdk extends FlutterQcsdkPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_qcsdk');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
