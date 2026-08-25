import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'src/qcsdk_types.dart';
import 'src/qcsdk_models.dart';

export 'src/qcsdk_types.dart';
export 'src/qcsdk_models.dart';

class FlutterQcsdk {
  static const MethodChannel _channel = MethodChannel('flutter_qcsdk/methods');
  static const EventChannel _eventChannel = EventChannel('flutter_qcsdk/events');

  static StreamSubscription? _eventSubscription;

  // Stream Controllers
  static final _deviceStateController = StreamController<QCDeviceState>.broadcast();
  static final _bluetoothStateController = StreamController<QCBluetoothState>.broadcast();
  static final _scanResultsController = StreamController<List<QCBleDevice>>.broadcast();
  static final _batteryController = StreamController<Map<String, dynamic>>.broadcast();
  static final _mediaUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  static final _aiChatController = StreamController<Map<String, dynamic>>.broadcast();
  static final _downloadProgressController = StreamController<Map<String, dynamic>>.broadcast();
  static final _downloadCompleteController = StreamController<Map<String, dynamic>>.broadcast();
  static final _wifiUpgradeController = StreamController<Map<String, dynamic>>.broadcast();

  // Public Streams
  static Stream<QCDeviceState> get deviceStateStream => _deviceStateController.stream;
  static Stream<QCBluetoothState> get bluetoothStateStream => _bluetoothStateController.stream;
  static Stream<List<QCBleDevice>> get scanResultsStream => _scanResultsController.stream;
  static Stream<Map<String, dynamic>> get batteryStream => _batteryController.stream;
  static Stream<Map<String, dynamic>> get mediaUpdateStream => _mediaUpdateController.stream;
  static Stream<Map<String, dynamic>> get aiChatStream => _aiChatController.stream;
  static Stream<Map<String, dynamic>> get downloadProgressStream => _downloadProgressController.stream;
  static Stream<Map<String, dynamic>> get downloadCompleteStream => _downloadCompleteController.stream;
  static Stream<Map<String, dynamic>> get wifiUpgradeStream => _wifiUpgradeController.stream;

  /// Initialize and start listening to native events from QCSDK
  static void initialize() {
    _eventSubscription?.cancel();
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen((dynamic event) {
      if (event is Map) {
        final String type = event['type'] ?? '';
        switch (type) {
          case 'scanResults':
            final rawList = event['peripherals'] as List? ?? [];
            final devices = rawList.map((m) => QCBleDevice.fromMap(m as Map)).toList();
            _scanResultsController.add(devices);
            break;
          case 'deviceState':
            final int stateVal = event['state'] as int? ?? 0;
            _deviceStateController.add(QCDeviceState.fromValue(stateVal));
            break;
          case 'bluetoothState':
            final int stateVal = event['state'] as int? ?? 0;
            _bluetoothStateController.add(QCBluetoothState.fromValue(stateVal));
            break;
          case 'batteryLevel':
            _batteryController.add({
              'battery': event['battery'] as int? ?? 0,
              'charging': event['charging'] as bool? ?? false,
            });
            break;
          case 'mediaUpdate':
            final photoCount = event['photoCount'] as int? ?? 0;
            final videoCount = event['videoCount'] as int? ?? 0;
            final audioCount = event['audioCount'] as int? ?? 0;
            debugPrint('👓 [SPECS SDK STREAM] Media Info Update -> Total: ${photoCount + videoCount + audioCount} (Photos: $photoCount, Videos: $videoCount, Audio: $audioCount)');
            _mediaUpdateController.add({
              'photoCount': photoCount,
              'videoCount': videoCount,
              'audioCount': audioCount,
              'mediaType': event['mediaType'] as int? ?? 0,
            });
            break;
          case 'aiChatText':
            _aiChatController.add({
              'event': 'text',
              'message': event['message'] as String? ?? '',
            });
            break;
          case 'aiChatVoice':
            _aiChatController.add({
              'event': 'voice',
              'data': event['data'] as Uint8List?,
            });
            break;
          case 'aiChatImage':
            _aiChatController.add({
              'event': 'image',
              'data': event['data'] as Uint8List?,
            });
            break;
          case 'downloadProgress':
            _downloadProgressController.add({
              'receivedSize': event['receivedSize'] as int? ?? 0,
              'expectedSize': event['expectedSize'] as int? ?? 0,
              'progress': event['progress'] as double? ?? 0.0,
            });
            break;
          case 'downloadComplete':
            _downloadCompleteController.add({
              'filePath': event['filePath'] as String? ?? '',
              'error': event['error'] as String? ?? '',
              'index': event['index'] as int? ?? 0,
              'count': event['count'] as int? ?? 0,
            });
            break;
          case 'wifiUpgradeProgress':
            _wifiUpgradeController.add({
              'event': 'progress',
              'download': event['download'] as int? ?? 0,
              'upgrade1': event['upgrade1'] as int? ?? 0,
              'upgrade2': event['upgrade2'] as int? ?? 0,
            });
            break;
          case 'wifiUpgradeResult':
            _wifiUpgradeController.add({
              'event': 'result',
              'success': event['success'] as bool? ?? false,
            });
            break;
        }
      }
    });
  }

  // --- Bluetooth Connection Actions ---

  /// Query the current device connection state directly
  static Future<QCDeviceState> getDeviceState() async {
    final int? stateVal = await _channel.invokeMethod<int>('getDeviceState');
    return QCDeviceState.fromValue(stateVal ?? 0);
  }

  /// Check whether the device is currently connected
  static Future<bool> isDeviceConnected() async {
    final bool? isConnected = await _channel.invokeMethod<bool>('isDeviceConnected');
    return isConnected ?? false;
  }

  /// Retrieve the currently connected device info (if connected)
  static Future<QCBleDevice?> getConnectedDevice() async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getConnectedDevice');
    if (res == null) return null;
    return QCBleDevice.fromMap(res);
  }

  /// Start scanning for devices
  static Future<void> startScan() async {
    await _channel.invokeMethod('startScan');
  }

  /// Stop scanning for devices
  static Future<void> stopScan() async {
    await _channel.invokeMethod('stopScan');
  }

  /// Connect to a device via its unique identifier (MAC / UUID string)
  static Future<void> connect(String identifier) async {
    await _channel.invokeMethod('connect', {'identifier': identifier});
  }

  /// Temporarily disconnect the device (retains device pairing and stored info for fast reconnection)
  static Future<void> disconnect() async {
    await _channel.invokeMethod('disconnect');
  }

  /// Unpair and completely unbind the device (clears stored pairing credentials and device info)
  static Future<void> unpair() async {
    await _channel.invokeMethod('unpair');
  }

  // --- Device Control Commands ---

  /// Set the device operating mode (e.g. Photo, Video, Speech)
  static Future<void> setDeviceMode(QCDeviceMode mode) async {
    await _channel.invokeMethod('setDeviceMode', {'mode': mode.value});
  }

  /// Open device Wi-Fi with specified mode
  static Future<Map<String, String>> openWifiWithMode(QCDeviceMode mode) async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('openWifiWithMode', {'mode': mode.value});
    return {
      'ssid': res?['ssid'] as String? ?? '',
      'password': res?['password'] as String? ?? '',
    };
  }

  /// Configure video parameters (angle, duration)
  static Future<void> setVideoInfo(int angle, int duration) async {
    await _channel.invokeMethod('setVideoInfo', {'angle': angle, 'duration': duration});
  }

  /// Retrieve current video parameters
  static Future<Map<String, int>> getVideoInfo() async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getVideoInfo');
    return {
      'angle': res?['angle'] as int? ?? 0,
      'duration': res?['duration'] as int? ?? 0,
    };
  }

  /// Get the IP address of the device's connected Wi-Fi
  static Future<String?> getDeviceWifiIP() async {
    return await _channel.invokeMethod<String>('getDeviceWifiIP');
  }

  /// Get counts of media files currently on the device
  static Future<QCDeviceMediaInfo> getDeviceMedia() async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getDeviceMedia');
    final mediaInfo = QCDeviceMediaInfo.fromMap(res ?? {});
    debugPrint('👓 [SPECS SDK getDeviceMedia] Photos: ${mediaInfo.photoCount}, Videos: ${mediaInfo.videoCount}, Audio: ${mediaInfo.audioCount}, Total: ${mediaInfo.photoCount + mediaInfo.videoCount + mediaInfo.audioCount}');
    return mediaInfo;
  }

  /// Delete all media files on the device
  static Future<void> deleteAllMedias() async {
    await _channel.invokeMethod('deleteAllMedias');
  }

  /// Delete a specific media file by name
  static Future<void> deleteMedia(String name) async {
    await _channel.invokeMethod('deleteMedia', {'name': name});
  }

  /// Configure audio parameters
  static Future<void> setAudioInfo(int angle, int duration) async {
    await _channel.invokeMethod('setAudioInfo', {'angle': angle, 'duration': duration});
  }

  /// Retrieve audio parameters
  static Future<Map<String, int>> getAudioInfo() async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getAudioInfo');
    return {
      'angle': res?['angle'] as int? ?? 0,
      'duration': res?['duration'] as int? ?? 0,
    };
  }

  /// Get battery level and charging status
  static Future<Map<String, dynamic>> getDeviceBattery() async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getDeviceBattery');
    return {
      'battery': res?['battery'] as int? ?? 0,
      'charging': res?['charging'] as bool? ?? false,
    };
  }

  /// Get hardware, firmware, and Wi-Fi versions of the device
  static Future<QCDeviceVersion> getDeviceVersionInfo() async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getDeviceVersionInfo');
    return QCDeviceVersion.fromMap(res ?? {});
  }

  /// Check if the Bluetooth channel is free
  static Future<bool> isPeripheralFreeNow() async {
    return await _channel.invokeMethod<bool>('isPeripheralFreeNow') ?? false;
  }

  /// Sync device time with phone time
  static Future<void> setupDeviceDateTime() async {
    await _channel.invokeMethod('setupDeviceDateTime');
  }

  /// Retrieve media thumbnail by media pocket index
  static Future<Map<String, dynamic>> getThumbnail(int pocket) async {
    final Map<dynamic, dynamic>? res = await _channel.invokeMethod('getThumbnail', {'pocket': pocket});
    return {
      'data': res?['data'] as Uint8List?,
      'width': res?['width'] as int? ?? 0,
      'height': res?['height'] as int? ?? 0,
    };
  }

  /// Send AI voice heartbeat
  static Future<void> sendVoiceHeartbeat() async {
    await _channel.invokeMethod('sendVoiceHeartbeat');
  }

  /// Get voice wakeup status
  static Future<dynamic> getVoiceWakeup() async {
    return await _channel.invokeMethod('getVoiceWakeup');
  }

  /// Set voice wakeup state
  static Future<dynamic> setVoiceWakeup(bool isOn) async {
    return await _channel.invokeMethod('setVoiceWakeup', {'isOn': isOn});
  }

  /// Get wearing detection calibration status
  static Future<dynamic> getWearingDetection() async {
    return await _channel.invokeMethod('getWearingDetection');
  }

  /// Enable or disable wearing detection
  static Future<dynamic> setWearingDetection(bool isOn) async {
    return await _channel.invokeMethod('setWearingDetection', {'isOn': isOn});
  }

  /// Get device general configurations
  static Future<dynamic> getDeviceConfig() async {
    return await _channel.invokeMethod('getDeviceConfig');
  }

  /// Set AI speaking mode
  static Future<void> setAISpeekModel(QCAISpeakMode speakMode) async {
    await _channel.invokeMethod('setAISpeekModel', {'speakMode': speakMode.value});
  }

  /// Get current volume configurations for system, call, and music channels
  static Future<QCVolumeInfo?> getVolume() async {
    return await _channel.invokeMethod<QCVolumeInfo>('getVolume');
  }

  /// Set volume configurations
  static Future<void> setVolume(QCVolumeInfo info) async {
    await _channel.invokeMethod('setVolume', info.toMap());
  }

  /// Set Bluetooth state on/off
  static Future<void> setBTStatus(bool isOpen) async {
    await _channel.invokeMethod('setBTStatus', {'isOpen': isOpen});
  }

  /// Query Bluetooth status
  static Future<void> getBTStatus() async {
    await _channel.invokeMethod('getBTStatus');
  }

  /// Stop active AI Voice session
  static Future<void> stopAIChat() async {
    await _channel.invokeMethod('stopAIChat');
  }

  /// Helper to convert Opus audio files into standard WAV/PCM format
  static Future<bool> convertOpusToPcm(String inputPath, String outputPath) async {
    final bool? res = await _channel.invokeMethod<bool>('convertOpusToPcm', {
      'inputPath': inputPath,
      'outputPath': outputPath,
    });
    return res ?? false;
  }

  /// Trigger Wi-Fi media files download from glasses to phone storage
  static Future<void> startToDownloadMediaResource() async {
    await _channel.invokeMethod('startToDownloadMediaResource');
  }

  /// Open native Bluetooth settings screen (Android only)
  static Future<void> openBluetoothSettings() async {
    await _channel.invokeMethod('openBluetoothSettings');
  }
}
