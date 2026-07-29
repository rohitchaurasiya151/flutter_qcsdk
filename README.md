# flutter_qcsdk

A Flutter plugin for Oudmon / HeyCyan smart glasses and wearable devices.

---

## Proprietary SDK & Dependency Setup (Important)

This package acts **strictly as a bridge** and **does not distribute the proprietary Oudmon/HeyCyan native SDK binaries or GPL compression libraries**. 

If you are developing with or consuming this package, you must supply the native SDK and dependency files from your purchase:

1. **Android**: 
   * Copy the `com/oudmon` source directory containing the Java/Kotlin classes into your local package clone at:
     `android/src/main/java/com/oudmon/`
   * Copy the `org/jvcompress` source directory containing LZO compression classes into:
     `android/src/main/java/org/jvcompress/`
   
2. **iOS**: Copy the purchased frameworks (`QCSDK.framework`, `JLAudioUnitKit.framework`, and `JLLogHelper.framework`) into your local package clone at:
   `ios/Frameworks/`

These directories are automatically ignored in `.gitignore` and `.pubignore` to prevent licensing, copyleft (GPL), and redistribution issues.

---

## Getting Started


To get started with `flutter_qcsdk`, initialize the SDK before calling other methods:

```dart
import 'package:flutter_qcsdk/flutter_qcsdk.dart';

void main() {
  // Initialize the SDK and start listening to native events
  FlutterQcsdk.initialize();
}
```

---

## 1. Event Streams (Real-time Listening)

### Device Connection State
Listen to the connection state of the smart glasses (Disconnected, Connecting, Connected, etc.):
```dart
FlutterQcsdk.deviceStateStream.listen((state) {
  print('Device Connection State: $state'); // e.g. QCDeviceState.connected
});
```

### Bluetooth State
Listen to the phone's Bluetooth state (On, Off, Scanning, etc.):
```dart
FlutterQcsdk.bluetoothStateStream.listen((state) {
  print('Bluetooth State: $state'); // e.g. QCBluetoothState.poweredOn
});
```

### BLE Scan Results
Receive the list of nearby smart glasses/wearables discovered during a scan:
```dart
FlutterQcsdk.scanResultsStream.listen((List<QCBleDevice> devices) {
  for (var device in devices) {
    print('Found device: ${device.name} - ID: ${device.identifier}');
  }
});
```

### Battery Level & Charging Status
Receive battery changes:
```dart
FlutterQcsdk.batteryStream.listen((data) {
  final int battery = data['battery'];
  final bool charging = data['charging'];
  print('Battery: $battery%, Charging: $charging');
});
```

### Media Count Updates
Listen for changes in the media counts (photos, videos, audio) on the device:
```dart
FlutterQcsdk.mediaUpdateStream.listen((data) {
  print('Media counts changed: ${data['photoCount']} photos, ${data['videoCount']} videos');
});
```

### AI Chat Event Stream
Listen to incoming text transcripts, voice, or image data from the glasses' AI Assistant:
```dart
FlutterQcsdk.aiChatStream.listen((data) {
  final event = data['event']; // 'text', 'voice', or 'image'
  if (event == 'text') {
    print('AI Assistant: ${data['message']}');
  } else if (event == 'voice' || event == 'image') {
    final Uint8List bytes = data['data'];
    // Process audio/image bytes
  }
});
```

### Download Progress & Completion
Listen to the progress and completion of media file transfers:
```dart
// Progress stream
FlutterQcsdk.downloadProgressStream.listen((progressData) {
  print('Download Progress: ${progressData['progress'] * 100}%');
});

// Complete stream
FlutterQcsdk.downloadCompleteStream.listen((result) {
  print('Download Completed! File saved to: ${result['filePath']}');
});
```

---

## 2. Device Discovery & Connection (BLE)

### Start Scanning
Search for nearby smart glasses/wearable devices:
```dart
await FlutterQcsdk.startScan();
```

### Stop Scanning
Stop the active Bluetooth scan:
```dart
await FlutterQcsdk.stopScan();
```

### Connect to Device
Connect to a device using its unique identifier (MAC address / UUID):
```dart
await FlutterQcsdk.connect('YOUR_DEVICE_IDENTIFIER');
```

### Disconnect Device
Disconnect and unbind the active device:
```dart
await FlutterQcsdk.disconnect();
```

### Sync Time
Synchronize the date and time of the glasses with the phone:
```dart
await FlutterQcsdk.setupDeviceDateTime();
```

---

## 3. Wi-Fi & Media File Operations

### Open Wi-Fi Mode
Request the device to turn on its Wi-Fi hotspot with a specified mode (e.g., photo, video, speech):
```dart
final wifiConfig = await FlutterQcsdk.openWifiWithMode(QCDeviceMode.photo);
print('SSID: ${wifiConfig['ssid']}');
print('Password: ${wifiConfig['password']}');
```

### Get Wi-Fi IP
Retrieve the IP address of the device's connected Wi-Fi:
```dart
String? ip = await FlutterQcsdk.getDeviceWifiIP();
print('Device Wi-Fi IP: $ip');
```

### Fetch Device Media Info
Get details about the photos, videos, and audio files stored on the device:
```dart
QCDeviceMediaInfo mediaInfo = await FlutterQcsdk.getDeviceMedia();
print('Total Photos: ${mediaInfo.photoCount}');
print('Total Videos: ${mediaInfo.videoCount}');
```

### Download Media Files
Trigger the download of media files from the glasses to the phone storage (listen to `downloadProgressStream` and `downloadCompleteStream` for updates):
```dart
await FlutterQcsdk.startToDownloadMediaResource();
```

### Get Thumbnail
Retrieve a thumbnail image by passing its media pocket index:
```dart
final thumb = await FlutterQcsdk.getThumbnail(0);
Uint8List? imageBytes = thumb['data'];
int width = thumb['width'];
int height = thumb['height'];
```

### Delete Media Files
Delete a specific media file by name, or clear all media files:
```dart
// Delete single file
await FlutterQcsdk.deleteMedia('photo_01.jpg');

// Delete all media files
await FlutterQcsdk.deleteAllMedias();
```

### Convert Opus Audio to PCM/WAV
Convert downloaded audio (often in Opus format) into standard PCM format:
```dart
bool success = await FlutterQcsdk.convertOpusToPcm('input.opus', 'output.pcm');
print('Audio conversion success: $success');
```

---

## 4. Device Settings & Controls

### Set Device Operating Mode
Set the device operation mode:
```dart
await FlutterQcsdk.setDeviceMode(QCDeviceMode.speech);
```

### Configure Video / Audio Info
Configure angle parameters and duration for video and audio recording:
```dart
// Configure Video info
await FlutterQcsdk.setVideoInfo(90, 30); // angle: 90, duration: 30s

// Retrieve current configurations
final videoConfig = await FlutterQcsdk.getVideoInfo();
print('Angle: ${videoConfig['angle']}, Duration: ${videoConfig['duration']}');

// Configure Audio info
await FlutterQcsdk.setAudioInfo(90, 60);
```

### Retrieve System Status Info
Get hardware details and battery levels directly:
```dart
// Get Version Info
QCDeviceVersion version = await FlutterQcsdk.getDeviceVersionInfo();
print('Firmware Version: ${version.firmwareVersion}');
print('Hardware Version: ${version.hardwareVersion}');

// Get Battery Info
final batteryInfo = await FlutterQcsdk.getDeviceBattery();
print('Battery: ${batteryInfo['battery']}%, Charging: ${batteryInfo['charging']}');
```

---

## 5. Smart Features & AI Assistant

### Set AI Speaking Mode
Set the AI assistant speak mode (e.g. continuous speak, quiet mode):
```dart
await FlutterQcsdk.setAISpeekModel(QCAISpeakMode.normal);
```

### Stop AI Voice Session
Instantly stop the active AI Voice chat/assistant session:
```dart
await FlutterQcsdk.stopAIChat();
```

### Wearing Detection
Toggle and query wearing detection status:
```dart
// Set wearing detection to ON
await FlutterQcsdk.setWearingDetection(true);

// Query status
final status = await FlutterQcsdk.getWearingDetection();
print('Wearing detection active: $status');
```

### Voice Wakeup Control
Manage voice assistant wakeup states:
```dart
// Turn voice wakeup ON
await FlutterQcsdk.setVoiceWakeup(true);

// Query status
final wakeupStatus = await FlutterQcsdk.getVoiceWakeup();
```

### Volume Configurations
Query and update the system volumes:
```dart
// Get volume info
QCVolumeInfo? volume = await FlutterQcsdk.getVolume();
print('System Volume: ${volume?.systemVolume}');

// Update volume info
final newVolume = QCVolumeInfo(systemVolume: 8, callVolume: 10, musicVolume: 12);
await FlutterQcsdk.setVolume(newVolume);
```

---

## Credits & Acknowledgments

This Flutter plugin acts as a bridge wrapper around the native SDKs. We would like to acknowledge and credit the original developers of the underlying native SDK components:
- **Oudmon & HeyCyan Engineering Team** — Original creators of the native iOS and Android SDK libraries for Bluetooth and Wi-Fi smart glasses communication.
- **Jxr35, jxr202, and gs** — Core engineers of the Android native BLE/Wi-Fi control layers.
- **Liang Jingkanji (劉強東)** — Developer of the Kotlin `Interval` polling module.
- **Mahadevan Gorti Surya Srinivasa** — Developer of the `jvcompress` LZO decompression port used on Android.

