import 'qcsdk_types.dart';

class QCVolumeInfo {
  final int musicMin;
  final int musicMax;
  final int musicCurrent;
  final int callMin;
  final int callMax;
  final int callCurrent;
  final int systemMin;
  final int systemMax;
  final int systemCurrent;
  final QCVolumeMode mode;

  QCVolumeInfo({
    required this.musicMin,
    required this.musicMax,
    required this.musicCurrent,
    required this.callMin,
    required this.callMax,
    required this.callCurrent,
    required this.systemMin,
    required this.systemMax,
    required this.systemCurrent,
    required this.mode,
  });

  Map<String, dynamic> toMap() {
    return {
      'musicMin': musicMin,
      'musicMax': musicMax,
      'musicCurrent': musicCurrent,
      'callMin': callMin,
      'callMax': callMax,
      'callCurrent': callCurrent,
      'systemMin': systemMin,
      'systemMax': systemMax,
      'systemCurrent': systemCurrent,
      'mode': mode.value,
    };
  }

  factory QCVolumeInfo.fromMap(Map<dynamic, dynamic> map) {
    return QCVolumeInfo(
      musicMin: map['musicMin'] as int,
      musicMax: map['musicMax'] as int,
      musicCurrent: map['musicCurrent'] as int,
      callMin: map['callMin'] as int,
      callMax: map['callMax'] as int,
      callCurrent: map['callCurrent'] as int,
      systemMin: map['systemMin'] as int,
      systemMax: map['systemMax'] as int,
      systemCurrent: map['systemCurrent'] as int,
      mode: QCVolumeMode.fromValue(map['mode'] as int),
    );
  }
}

class QCBleDevice {
  final String name;
  final String identifier;
  final String mac;
  final int rssi;
  final bool isPaired;

  QCBleDevice({
    required this.name,
    required this.identifier,
    required this.mac,
    required this.rssi,
    required this.isPaired,
  });

  factory QCBleDevice.fromMap(Map<dynamic, dynamic> map) {
    return QCBleDevice(
      name: map['name'] as String? ?? 'Unknown Device',
      identifier: map['identifier'] as String? ?? '',
      mac: map['mac'] as String? ?? '',
      rssi: map['rssi'] as int? ?? 0,
      isPaired: map['isPaired'] as bool? ?? false,
    );
  }
}

class QCDeviceVersion {
  final String hardwareVersion;
  final String firmwareVersion;
  final String hardwareWifiVersion;
  final String firmwareWifiVersion;

  QCDeviceVersion({
    required this.hardwareVersion,
    required this.firmwareVersion,
    required this.hardwareWifiVersion,
    required this.firmwareWifiVersion,
  });

  factory QCDeviceVersion.fromMap(Map<dynamic, dynamic> map) {
    return QCDeviceVersion(
      hardwareVersion: map['hardwareVersion'] as String? ?? '',
      firmwareVersion: map['firmwareVersion'] as String? ?? '',
      hardwareWifiVersion: map['hardwareWifiVersion'] as String? ?? '',
      firmwareWifiVersion: map['firmwareWifiVersion'] as String? ?? '',
    );
  }
}

class QCDeviceMediaInfo {
  final int photoCount;
  final int videoCount;
  final int audioCount;
  final int totalSize;

  QCDeviceMediaInfo({
    required this.photoCount,
    required this.videoCount,
    required this.audioCount,
    required this.totalSize,
  });

  factory QCDeviceMediaInfo.fromMap(Map<dynamic, dynamic> map) {
    return QCDeviceMediaInfo(
      photoCount: map['photoCount'] as int? ?? 0,
      videoCount: map['videoCount'] as int? ?? 0,
      audioCount: map['audioCount'] as int? ?? 0,
      totalSize: map['totalSize'] as int? ?? 0,
    );
  }
}
