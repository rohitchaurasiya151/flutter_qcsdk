import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_qcsdk_method_channel.dart';

abstract class FlutterQcsdkPlatform extends PlatformInterface {
  /// Constructs a FlutterQcsdkPlatform.
  FlutterQcsdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterQcsdkPlatform _instance = MethodChannelFlutterQcsdk();

  /// The default instance of [FlutterQcsdkPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterQcsdk].
  static FlutterQcsdkPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterQcsdkPlatform] when
  /// they register themselves.
  static set instance(FlutterQcsdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
