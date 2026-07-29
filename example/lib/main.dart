import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_qcsdk/flutter_qcsdk.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QCSDK Demo',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.teal,
          secondary: Colors.tealAccent,
          surface: Color(0xFF1E1E1E),
          onPrimary: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.teal,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  QCDeviceState _deviceState = QCDeviceState.unknown;
  QCBluetoothState _bluetoothState = QCBluetoothState.unknown;
  List<QCBleDevice> _scannedDevices = [];
  Map<String, dynamic> _batteryInfo = {'battery': 0, 'charging': false};
  String _statusLog = "Disconnected";
  QCDeviceVersion? _deviceVersion;
  QCDeviceMediaInfo? _mediaInfo;
  String _downloadInfo = "";

  // AI chat outputs
  String _aiText = "";
  int _voiceDataCount = 0;
  int _imageDataCount = 0;

  // Stream Subscriptions
  StreamSubscription? _deviceStateSub;
  StreamSubscription? _bluetoothStateSub;
  StreamSubscription? _scanResultsSub;
  StreamSubscription? _batterySub;
  StreamSubscription? _mediaUpdateSub;
  StreamSubscription? _aiChatSub;
  StreamSubscription? _downloadProgressSub;
  StreamSubscription? _downloadCompleteSub;

  @override
  void initState() {
    super.initState();
    // Initialize the plugin and start listening to EventChannel
    FlutterQcsdk.initialize();
    _subscribeToStreams();
  }

  void _subscribeToStreams() {
    _deviceStateSub = FlutterQcsdk.deviceStateStream.listen((state) {
      setState(() {
        _deviceState = state;
        _statusLog = "State changed: ${state.name.toUpperCase()}";
      });
      if (state == QCDeviceState.connected) {
        // Query some info once connected
        _queryDeviceInfo();
      }
    });

    _bluetoothStateSub = FlutterQcsdk.bluetoothStateStream.listen((state) {
      setState(() {
        _bluetoothState = state;
      });
    });

    _scanResultsSub = FlutterQcsdk.scanResultsStream.listen((devices) {
      setState(() {
        _scannedDevices = devices;
      });
    });

    _batterySub = FlutterQcsdk.batteryStream.listen((info) {
      setState(() {
        _batteryInfo = info;
      });
    });

    _mediaUpdateSub = FlutterQcsdk.mediaUpdateStream.listen((update) {
      setState(() {
        _mediaInfo = QCDeviceMediaInfo(
          photoCount: update['photoCount'] as int? ?? 0,
          videoCount: update['videoCount'] as int? ?? 0,
          audioCount: update['audioCount'] as int? ?? 0,
          totalSize: _mediaInfo?.totalSize ?? 0,
        );
        _statusLog = "Media updated: Photos=${update['photoCount']}, Videos=${update['videoCount']}, Audios=${update['audioCount']}";
      });
    });

    _downloadProgressSub = FlutterQcsdk.downloadProgressStream.listen((event) {
      final progress = event['progress'] as double? ?? 0.0;
      setState(() {
        _downloadInfo = "Progress: ${(progress * 100).toStringAsFixed(0)}% (${event['receivedSize']}/${event['expectedSize']} bytes)";
        _statusLog = "Download progress: ${(progress * 100).toStringAsFixed(0)}%";
      });
    });

    _downloadCompleteSub = FlutterQcsdk.downloadCompleteStream.listen((event) {
      final filePath = event['filePath'] as String? ?? '';
      final error = event['error'] as String? ?? '';
      final index = event['index'] as int? ?? 0;
      final count = event['count'] as int? ?? 0;
      setState(() {
        if (error.isNotEmpty) {
          _downloadInfo = "Failed: $error";
          _statusLog = "Download failed: $error";
        } else {
          _downloadInfo = "File $index/$count downloaded";
          _statusLog = "Downloaded: $filePath";
          if (index == count) {
            _downloadInfo = "Finished! $count files downloaded";
            _statusLog = "Download Finished! Total files: $count";
          }
        }
      });
    });

    _aiChatSub = FlutterQcsdk.aiChatStream.listen((event) {
      final eventType = event['event'];
      if (eventType == 'text') {
        setState(() {
          _aiText = event['message'] ?? '';
        });
      } else if (eventType == 'voice') {
        setState(() {
          _voiceDataCount++;
        });
      } else if (eventType == 'image') {
        setState(() {
          _imageDataCount++;
        });
      }
    });
  }

  @override
  void dispose() {
    _deviceStateSub?.cancel();
    _bluetoothStateSub?.cancel();
    _scanResultsSub?.cancel();
    _batterySub?.cancel();
    _mediaUpdateSub?.cancel();
    _downloadProgressSub?.cancel();
    _downloadCompleteSub?.cancel();
    _aiChatSub?.cancel();
    super.dispose();
  }

  Future<void> _queryDeviceInfo() async {
    try {
      final version = await FlutterQcsdk.getDeviceVersionInfo();
      final battery = await FlutterQcsdk.getDeviceBattery();
      final media = await FlutterQcsdk.getDeviceMedia();
      setState(() {
        _deviceVersion = version;
        _batteryInfo = battery;
        _mediaInfo = media;
      });
    } catch (e) {
      _logError("Failed to query device info: $e");
    }
  }

  void _logError(String msg) {
    setState(() {
      _statusLog = "Error: $msg";
    });
  }

  void _logInfo(String msg) {
    setState(() {
      _statusLog = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isConnected = _deviceState == QCDeviceState.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('QCSDK Native BLE wrapper'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: isConnected ? _queryDeviceInfo : null,
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status and BT Info Panel
            _buildStatusPanel(),
            const SizedBox(height: 16),

            // Scan / Connection controls
            if (!isConnected) ...[
              _buildScanControlPanel(),
              const SizedBox(height: 16),
              _buildScannedDevicesList(),
            ] else ...[
              // Connection management and device details
              _buildConnectedPanel(),
              const SizedBox(height: 16),
              _buildCommandsPanel(),
              const SizedBox(height: 16),
              _buildAIChatPanel(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Connection Status: ${_deviceState.name.toUpperCase()}", 
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text("Bluetooth Adapter State: ${_bluetoothState.name.toUpperCase()}"),
            const SizedBox(height: 8),
            Text("Log: $_statusLog", style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildScanControlPanel() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            icon: const Icon(Icons.search),
            label: const Text("Start Scan"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
            onPressed: () async {
              try {
                setState(() => _scannedDevices.clear());
                bool granted = true;
                if (Theme.of(context).platform == TargetPlatform.android) {
                  // Request Bluetooth scan & connect, Location, and Nearby Wi-Fi devices permissions
                  final statusScan = await Permission.bluetoothScan.request();
                  final statusConnect = await Permission.bluetoothConnect.request();
                  final statusLocation = await Permission.location.request();
                  await Permission.nearbyWifiDevices.request();
                  granted = (statusScan.isGranted && statusConnect.isGranted) || statusLocation.isGranted;
                }
                if (!granted) {
                  _logError("Permissions denied. Cannot scan for Bluetooth devices.");
                  return;
                }
                await FlutterQcsdk.startScan();
                _logInfo("Scanning started...");
              } catch (e) {
                _logError(e.toString());
              }
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text("Stop Scan"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800], foregroundColor: Colors.white),
            onPressed: () async {
              try {
                await FlutterQcsdk.stopScan();
                _logInfo("Scanning stopped");
              } catch (e) {
                _logError(e.toString());
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScannedDevicesList() {
    if (_scannedDevices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24.0),
          child: Text("No devices found. Tap 'Start Scan' to search.", 
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Scanned Devices:", style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _scannedDevices.length,
          itemBuilder: (context, index) {
            final device = _scannedDevices[index];
            return ListTile(
              leading: const Icon(Icons.bluetooth, color: Colors.tealAccent),
              title: Text(device.name),
              subtitle: Text("MAC: ${device.mac}\nRSSI: ${device.rssi}"),
              trailing: ElevatedButton(
                child: const Text("Connect"),
                onPressed: () async {
                  try {
                    _logInfo("Connecting to ${device.name}...");
                    await FlutterQcsdk.connect(device.identifier);
                  } catch (e) {
                    _logError("Failed to connect: $e");
                  }
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildConnectedPanel() {
    final battery = _batteryInfo['battery'] as int? ?? 0;
    final charging = _batteryInfo['charging'] as bool? ?? false;

    return Card(
      color: Colors.teal.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Connected Device Settings", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900], foregroundColor: Colors.white),
                  onPressed: () async {
                    try {
                      await FlutterQcsdk.disconnect();
                    } catch (e) {
                      _logError(e.toString());
                    }
                  },
                  child: const Text("Disconnect"),
                ),
              ],
            ),
            const Divider(color: Colors.white24),
            const SizedBox(height: 8),
            Text("Battery Level: $battery% ${charging ? '(Charging)' : ''}"),
            const SizedBox(height: 4),
            if (_deviceVersion != null) ...[
              Text("Firmware Version: ${_deviceVersion!.firmwareVersion}"),
              Text("Hardware Version: ${_deviceVersion!.hardwareVersion}"),
              Text("WiFi Firmware: ${_deviceVersion!.firmwareWifiVersion}"),
            ],
            const SizedBox(height: 4),
            if (_mediaInfo != null)
              Text("Files on Device: Photos=${_mediaInfo!.photoCount}, Videos=${_mediaInfo!.videoCount}, Audios=${_mediaInfo!.audioCount}"),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandsPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Device Mode Controls", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: () => _setMode(QCDeviceMode.photo),
                  child: const Text("Photo Mode"),
                ),
                ElevatedButton(
                  onPressed: () => _setMode(QCDeviceMode.video),
                  child: const Text("Video Record Start"),
                ),
                ElevatedButton(
                  onPressed: () => _setMode(QCDeviceMode.videoStop),
                  child: const Text("Video Record Stop"),
                ),
                ElevatedButton(
                  onPressed: () => _setMode(QCDeviceMode.audio),
                  child: const Text("Audio Record Start"),
                ),
                ElevatedButton(
                  onPressed: () => _setMode(QCDeviceMode.audioStop),
                  child: const Text("Audio Record Stop"),
                ),
                ElevatedButton(
                  onPressed: () => _setMode(QCDeviceMode.aiPhoto),
                  child: const Text("AI Photo Mode"),
                ),
              ],
            ),
            const Divider(color: Colors.white24, height: 24),
            const Text("Device Utilities", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    try {
                      await FlutterQcsdk.setupDeviceDateTime();
                      _logInfo("Device time synced successfully");
                    } catch (e) {
                      _logError("Time Sync failed: $e");
                    }
                  },
                  child: const Text("Sync Time"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      final wifi = await FlutterQcsdk.openWifiWithMode(QCDeviceMode.transfer);
                      _logInfo("WiFi opened. SSID: ${wifi['ssid']}, PWD: ${wifi['password']}");
                    } catch (e) {
                      _logError("Failed to open Wi-Fi: $e");
                    }
                  },
                  child: const Text("Open WiFi (Transfer)"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      _logInfo("Fetching media info...");
                      final media = await FlutterQcsdk.getDeviceMedia();
                      setState(() {
                        _mediaInfo = media;
                      });
                      _logInfo("Media Info: Photos=${media.photoCount}, Videos=${media.videoCount}, Audios=${media.audioCount}, Size=${media.totalSize} bytes");
                    } catch (e) {
                      _logError("Get Media Info failed: $e");
                    }
                  },
                  child: const Text("Get Media Info"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (_mediaInfo == null || (_mediaInfo!.photoCount == 0 && _mediaInfo!.videoCount == 0 && _mediaInfo!.audioCount == 0)) {
                      setState(() {
                        _downloadInfo = "No Media Resources";
                      });
                      return;
                    }
                    try {
                      setState(() {
                        _downloadInfo = "Connecting...";
                      });
                      _logInfo("Starting download resources...");
                      await FlutterQcsdk.startToDownloadMediaResource();
                    } catch (e) {
                      _logError(e.toString());
                      setState(() {
                        _downloadInfo = "Error: $e";
                      });
                    }
                  },
                  child: const Text("Download Media via WiFi"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      await FlutterQcsdk.deleteAllMedias();
                      _logInfo("Deleted all media files");
                      _queryDeviceInfo();
                    } catch (e) {
                      _logError("Delete failed: $e");
                    }
                  },
                  child: const Text("Delete All Medias"),
                ),
              ],
            ),
            if (_downloadInfo.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                "Download Status: $_downloadInfo",
                style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAIChatPanel() {
    return Card(
      color: Colors.purple.withOpacity(0.05),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("AI Assistant Streaming", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.purpleAccent)),
                TextButton(
                  onPressed: () async {
                    try {
                      await FlutterQcsdk.stopAIChat();
                      _logInfo("AI Chat Stopped");
                    } catch (e) {
                      _logError(e.toString());
                    }
                  },
                  child: const Text("Stop AI Chat"),
                )
              ],
            ),
            const Divider(color: Colors.white24),
            const SizedBox(height: 8),
            Text("AI Recognized Text:\n${_aiText.isEmpty ? 'No text received yet' : _aiText}", 
                style: const TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Voice Packets (PCM): $_voiceDataCount"),
                Text("Image Packets: $_imageDataCount"),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setMode(QCDeviceMode mode) async {
    try {
      _logInfo("Setting mode to ${mode.name}...");
      await FlutterQcsdk.setDeviceMode(mode);
      _logInfo("Set mode ${mode.name} success!");
    } catch (e) {
      _logError("Mode switch failed: $e");
    }
  }
}
