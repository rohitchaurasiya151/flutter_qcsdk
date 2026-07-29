/// Device operating modes
enum QCDeviceMode {
  unknown(0x00),
  photo(0x01),
  video(0x02),
  videoStop(0x03),
  transfer(0x04),
  ota(0x05),
  aiPhoto(0x06),
  speechRecognition(0x07),
  audio(0x08),
  transferStop(0x09),
  factoryReset(0x0A),
  speechRecognitionStop(0x0B),
  audioStop(0x0C),
  findDevice(0x0D),
  restart(0x0E),
  noPowerP2P(0x0F),
  speakStart(0x10),
  speakStop(0x11),
  translateStart(0x12),
  translateStop(0x13);

  final int value;
  const QCDeviceMode(this.value);

  static QCDeviceMode fromValue(int val) {
    return QCDeviceMode.values.firstWhere(
      (e) => e.value == val,
      orElse: () => QCDeviceMode.unknown,
    );
  }
}

/// Volume modes
enum QCVolumeMode {
  music(0x01),
  call(0x02),
  system(0x03);

  final int value;
  const QCVolumeMode(this.value);

  static QCVolumeMode fromValue(int val) {
    return QCVolumeMode.values.firstWhere(
      (e) => e.value == val,
      orElse: () => QCVolumeMode.music,
    );
  }
}

/// AI Speaking Modes
enum QCAISpeakMode {
  start(0x01),
  hold(0x02),
  stop(0x03),
  thinkingStart(0x04),
  thinkingHold(0x05),
  thinkingStop(0x06),
  noNet(0xf1);

  final int value;
  const QCAISpeakMode(this.value);

  static QCAISpeakMode fromValue(int val) {
    return QCAISpeakMode.values.firstWhere(
      (e) => e.value == val,
      orElse: () => QCAISpeakMode.start,
    );
  }
}

/// Connection states (from QCCentralManager)
enum QCDeviceState {
  unknown(0),
  unbind(1),
  connecting(2),
  connected(3),
  disconnecting(4),
  disconnected(5);

  final int value;
  const QCDeviceState(this.value);

  static QCDeviceState fromValue(int val) {
    return QCDeviceState.values.firstWhere(
      (e) => e.value == val,
      orElse: () => QCDeviceState.unknown,
    );
  }
}

/// Bluetooth State (from QCCentralManager)
enum QCBluetoothState {
  unknown(0),
  resetting(1),
  unsupported(2),
  unauthorized(3),
  poweredOff(4),
  poweredOn(5);

  final int value;
  const QCBluetoothState(this.value);

  static QCBluetoothState fromValue(int val) {
    return QCBluetoothState.values.firstWhere(
      (e) => e.value == val,
      orElse: () => QCBluetoothState.unknown,
    );
  }
}
