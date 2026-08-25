#import "FlutterQcsdkPlugin.h"
#import <QCSDK/QCSDK.h>
#import "QCCentralManager.h"

@interface FlutterQcsdkPlugin () <QCCentralManagerDelegate, QCSDKManagerDelegate, FlutterStreamHandler>
@property (nonatomic, strong) FlutterEventSink eventSink;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *scannedPeripherals;
@end

@implementation FlutterQcsdkPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"flutter_qcsdk/methods"
            binaryMessenger:[registrar messenger]];
  
  FlutterEventChannel* eventChannel = [FlutterEventChannel
      eventChannelWithName:@"flutter_qcsdk/events"
           binaryMessenger:[registrar messenger]];

  FlutterQcsdkPlugin* instance = [[FlutterQcsdkPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
  [eventChannel setStreamHandler:instance];
  
  [QCSDKManager shareInstance].delegate = instance;
  [QCCentralManager shared].delegate = instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _scannedPeripherals = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"startScan" isEqualToString:call.method]) {
    [self.scannedPeripherals removeAllObjects];
    [[QCCentralManager shared] scan];
    result(nil);
  } 
  else if ([@"stopScan" isEqualToString:call.method]) {
    [[QCCentralManager shared] stopScan];
    result(nil);
  }
  else if ([@"connect" isEqualToString:call.method]) {
    NSString *identifier = call.arguments[@"identifier"];
    CBPeripheral *peripheral = self.scannedPeripherals[identifier];
    if (peripheral) {
      [[QCCentralManager shared] connect:peripheral];
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"NOT_FOUND" 
                                 message:@"Peripheral not found in scan results. Please scan first." 
                                 details:nil]);
    }
  }
  else if ([@"disconnect" isEqualToString:call.method]) {
    [[QCCentralManager shared] disconnect];
    result(nil);
  }
  else if ([@"unpair" isEqualToString:call.method]) {
    [[QCCentralManager shared] remove];
    result(nil);
  }
  else if ([@"setDeviceMode" isEqualToString:call.method]) {
    NSInteger modeVal = [call.arguments[@"mode"] integerValue];
    [QCSDKCmdCreator setDeviceMode:(QCOperatorDeviceMode)modeVal success:^{
      result(nil);
    } fail:^(NSInteger errCode) {
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to set device mode" details:@(errCode)]);
    }];
  }
  else if ([@"openWifiWithMode" isEqualToString:call.method]) {
    NSInteger modeVal = [call.arguments[@"mode"] integerValue];
    [QCSDKCmdCreator openWifiWithMode:(QCOperatorDeviceMode)modeVal success:^(NSString *ssid, NSString *pwd) {
      result(@{@"ssid": ssid ?: @"", @"password": pwd ?: @""});
    } fail:^(NSInteger errCode) {
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to open WiFi" details:@(errCode)]);
    }];
  }
  else if ([@"setVideoInfo" isEqualToString:call.method]) {
    NSInteger angle = [call.arguments[@"angle"] integerValue];
    NSInteger duration = [call.arguments[@"duration"] integerValue];
    [QCSDKCmdCreator setVideoInfo:angle duration:duration success:^{
      result(nil);
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to set video info" details:nil]);
    }];
  }
  else if ([@"getVideoInfo" isEqualToString:call.method]) {
    [QCSDKCmdCreator getVideoInfoSuccess:^(NSInteger angle, NSInteger duration) {
      result(@{@"angle": @(angle), @"duration": @(duration)});
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get video info" details:nil]);
    }];
  }
  else if ([@"getDeviceWifiIP" isEqualToString:call.method]) {
    [QCSDKCmdCreator getDeviceWifiIPSuccess:^(NSString * _Nullable ipAddress) {
      result(ipAddress);
    } failed:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get device WiFi IP" details:nil]);
    }];
  }
  else if ([@"getDeviceMedia" isEqualToString:call.method]) {
    [QCSDKCmdCreator getDeviceMedia:^(NSInteger photo, NSInteger video, NSInteger audio, NSInteger totalSize) {
      result(@{
        @"photoCount": @(photo),
        @"videoCount": @(video),
        @"audioCount": @(audio),
        @"totalSize": @(totalSize)
      });
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get device media count" details:nil]);
    }];
  }
  else if ([@"deleteAllMedias" isEqualToString:call.method]) {
    [QCSDKCmdCreator deleleteAllMediasSuccess:^{
      result(nil);
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to delete all media" details:nil]);
    }];
  }
  else if ([@"deleteMedia" isEqualToString:call.method]) {
    NSString *name = call.arguments[@"name"];
    [QCSDKCmdCreator deleleteMedia:name success:^{
      result(nil);
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to delete media file" details:nil]);
    }];
  }
  else if ([@"setAudioInfo" isEqualToString:call.method]) {
    NSInteger angle = [call.arguments[@"angle"] integerValue];
    NSInteger duration = [call.arguments[@"duration"] integerValue];
    [QCSDKCmdCreator setAudioInfo:angle duration:duration success:^{
      result(nil);
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to set audio info" details:nil]);
    }];
  }
  else if ([@"getAudioInfo" isEqualToString:call.method]) {
    [QCSDKCmdCreator getAudioInfoSuccess:^(NSInteger angle, NSInteger duration) {
      result(@{@"angle": @(angle), @"duration": @(duration)});
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get audio info" details:nil]);
    }];
  }
  else if ([@"getDeviceBattery" isEqualToString:call.method]) {
    [QCSDKCmdCreator getDeviceBattery:^(NSInteger battery, BOOL charging) {
      result(@{@"battery": @(battery), @"charging": @(charging)});
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get device battery" details:nil]);
    }];
  }
  else if ([@"getDeviceVersionInfo" isEqualToString:call.method]) {
    [QCSDKCmdCreator getDeviceVersionInfoSuccess:^(NSString *hdVersion, NSString *firmVersion, NSString *hdWifiVersion, NSString *firmWifiVersion) {
      result(@{
        @"hardwareVersion": hdVersion ?: @"",
        @"firmwareVersion": firmVersion ?: @"",
        @"hardwareWifiVersion": hdWifiVersion ?: @"",
        @"firmwareWifiVersion": firmWifiVersion ?: @""
      });
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get device version info" details:nil]);
    }];
  }
  else if ([@"isPeripheralFreeNow" isEqualToString:call.method]) {
    result(@([QCSDKCmdCreator isPeripheralFreeNow]));
  }
  else if ([@"setupDeviceDateTime" isEqualToString:call.method]) {
    [QCSDKCmdCreator setupDeviceDateTime:^(BOOL success, NSError * _Nullable error) {
      if (success) {
        result(nil);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"getThumbnail" isEqualToString:call.method]) {
    NSInteger pocket = [call.arguments[@"pocket"] integerValue];
    [QCSDKCmdCreator getThumbnail:pocket success:^(NSData *data, NSInteger w, NSInteger h) {
      result(@{
        @"data": [FlutterStandardTypedData typedDataWithBytes:data],
        @"width": @(w),
        @"height": @(h)
      });
    } fail:^{
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get thumbnail" details:nil]);
    }];
  }
  else if ([@"sendVoiceHeartbeat" isEqualToString:call.method]) {
    [QCSDKCmdCreator sendVoiceHeartbeatWithFinished:^(BOOL success, NSError * _Nullable error) {
      if (success) {
        result(nil);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"getVoiceWakeup" isEqualToString:call.method]) {
    [QCSDKCmdCreator getVoiceWakeupWithFinished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success) {
        result(resultVal);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"setVoiceWakeup" isEqualToString:call.method]) {
    BOOL isOn = [call.arguments[@"isOn"] boolValue];
    [QCSDKCmdCreator setVoiceWakeup:isOn finished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success) {
        result(resultVal);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"getWearingDetection" isEqualToString:call.method]) {
    [QCSDKCmdCreator getWearingDetectionWithFinished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success) {
        result(resultVal);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"setWearingDetection" isEqualToString:call.method]) {
    BOOL isOn = [call.arguments[@"isOn"] boolValue];
    [QCSDKCmdCreator setWearingDetection:isOn finished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success) {
        result(resultVal);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"getDeviceConfig" isEqualToString:call.method]) {
    [QCSDKCmdCreator getDeviceConfigWithFinished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success) {
        result(resultVal);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"setAISpeekModel" isEqualToString:call.method]) {
    NSInteger modelVal = [call.arguments[@"speakMode"] integerValue];
    [QCSDKCmdCreator setAISpeekModel:(QGAISpeakMode)modelVal finished:^(BOOL success, NSError * _Nullable error) {
      if (success) {
        result(nil);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"getVolume" isEqualToString:call.method]) {
    [QCSDKCmdCreator getVolumeWithFinished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success && [resultVal isKindOfClass:[QCVolumeInfoModel class]]) {
        QCVolumeInfoModel *vol = (QCVolumeInfoModel *)resultVal;
        result(@{
          @"musicMin": @(vol.musicMin),
          @"musicMax": @(vol.musicMax),
          @"musicCurrent": @(vol.musicCurrent),
          @"callMin": @(vol.callMin),
          @"callMax": @(vol.callMax),
          @"callCurrent": @(vol.callCurrent),
          @"systemMin": @(vol.systemMin),
          @"systemMax": @(vol.systemMax),
          @"systemCurrent": @(vol.systemCurrent),
          @"mode": @(vol.mode)
        });
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription ?: @"Failed to get volume settings" details:nil]);
      }
    }];
  }
  else if ([@"setVolume" isEqualToString:call.method]) {
    QCVolumeInfoModel *vol = [[QCVolumeInfoModel alloc] init];
    vol.musicMin = [call.arguments[@"musicMin"] integerValue];
    vol.musicMax = [call.arguments[@"musicMax"] integerValue];
    vol.musicCurrent = [call.arguments[@"musicCurrent"] integerValue];
    vol.callMin = [call.arguments[@"callMin"] integerValue];
    vol.callMax = [call.arguments[@"callMax"] integerValue];
    vol.callCurrent = [call.arguments[@"callCurrent"] integerValue];
    vol.systemMin = [call.arguments[@"systemMin"] integerValue];
    vol.systemMax = [call.arguments[@"systemMax"] integerValue];
    vol.systemCurrent = [call.arguments[@"systemCurrent"] integerValue];
    vol.mode = [call.arguments[@"mode"] integerValue];
    [QCSDKCmdCreator setVolume:vol finished:^(BOOL success, NSError * _Nullable error, id _Nullable resultVal) {
      if (success) {
        result(resultVal);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"setBTStatus" isEqualToString:call.method]) {
    BOOL isOpen = [call.arguments[@"isOpen"] boolValue];
    [QCSDKCmdCreator setBTStatus:isOpen finished:^(BOOL success, NSError * _Nullable error) {
      if (success) {
        result(nil);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"getBTStatus" isEqualToString:call.method]) {
    [QCSDKCmdCreator getBTStatusWithFinished:^(BOOL success, NSError * _Nullable error) {
      if (success) {
        result(nil);
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
      }
    }];
  }
  else if ([@"stopAIChat" isEqualToString:call.method]) {
    [[QCSDKManager shareInstance] stopAIChat];
    result(nil);
  }
  else if ([@"convertOpusToPcm" isEqualToString:call.method]) {
    NSString *inputPath = call.arguments[@"inputPath"];
    NSString *outputPath = call.arguments[@"outputPath"];
    [[QCSDKHelper shareInstance] convertOpusToPcm:inputPath outputPath:outputPath progress:^(float progress) {
      // Conversion progress
    } completion:^(BOOL success) {
      result(@(success));
    }];
  }
  else if ([@"startToDownloadMediaResource" isEqualToString:call.method]) {
    [[QCSDKManager shareInstance] startToDownloadMediaResourceWithProgress:^(NSInteger receivedSize, NSInteger expectedSize, CGFloat progress) {
      if (self.eventSink) {
        self.eventSink(@{
          @"type": @"downloadProgress",
          @"receivedSize": @(receivedSize),
          @"expectedSize": @(expectedSize),
          @"progress": @(progress)
        });
      }
    } completion:^(NSString * _Nullable filePath, NSError * _Nullable error, NSInteger index, NSInteger count) {
      if (self.eventSink) {
        self.eventSink(@{
          @"type": @"downloadComplete",
          @"filePath": filePath ?: @"",
          @"error": error.localizedDescription ?: @"",
          @"index": @(index),
          @"count": @(count)
        });
      }
    }];
    result(nil);
  }
  else if ([@"openBluetoothSettings" isEqualToString:call.method]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
      if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        if (@available(iOS 10.0, *)) {
          [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            result(@(success));
          }];
        } else {
          #pragma clang diagnostic push
          #pragma clang diagnostic ignored "-Wdeprecated-declarations"
          BOOL success = [[UIApplication sharedApplication] openURL:url];
          #pragma clang diagnostic pop
          result(@(success));
        }
      } else {
        result([FlutterError errorWithCode:@"ERROR" message:@"Cannot open settings URL" details:nil]);
      }
    });
  }
  else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - FlutterStreamHandler

- (FlutterError * _Nullable)onListenWithArguments:(id _Nullable)arguments eventSink:(FlutterEventSink)events {
  self.eventSink = events;
  return nil;
}

- (FlutterError * _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  self.eventSink = nil;
  return nil;
}

#pragma mark - QCSDKManagerDelegate

- (void)didUpdateBatteryLevel:(NSInteger)battery charging:(BOOL)charging {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"batteryLevel",
      @"battery": @(battery),
      @"charging": @(charging)
    });
  }
}

- (void)didUpdateMediaWithPhotoCount:(NSInteger)photo videoCount:(NSInteger)video audioCount:(NSInteger)audio type:(NSInteger)type {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"mediaUpdate",
      @"photoCount": @(photo),
      @"videoCount": @(video),
      @"audioCount": @(audio),
      @"mediaType": @(type)
    });
  }
}

- (void)didReceiveAIChatTextMessage:(NSString *)message {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"aiChatText",
      @"message": message
    });
  }
}

- (void)didReceiveAIChatVoiceData:(NSData *)pcmData {
  if (self.eventSink) {
    FlutterStandardTypedData *typedData = [FlutterStandardTypedData typedDataWithBytes:pcmData];
    self.eventSink(@{
      @"type": @"aiChatVoice",
      @"data": typedData
    });
  }
}

- (void)didReceiveAIChatImageData:(NSData *)imageData {
  if (self.eventSink) {
    FlutterStandardTypedData *typedData = [FlutterStandardTypedData typedDataWithBytes:imageData];
    self.eventSink(@{
      @"type": @"aiChatImage",
      @"data": typedData
    });
  }
}

- (void)didUpdateWiFiUpgradeProgressWithDownload:(NSInteger)download upgrade1:(NSInteger)upgrade1 upgrade2:(NSInteger)upgrade2 {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"wifiUpgradeProgress",
      @"download": @(download),
      @"upgrade1": @(upgrade1),
      @"upgrade2": @(upgrade2)
    });
  }
}

- (void)didReceiveWiFiUpgradeResult:(BOOL)success {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"wifiUpgradeResult",
      @"success": @(success)
    });
  }
}

#pragma mark - QCCentralManagerDelegate

- (void)didScanPeripherals:(NSArray <QCBlePeripheral*>*)peripheralArr {
  NSMutableArray *list = [NSMutableArray array];
  for (QCBlePeripheral *per in peripheralArr) {
    if (per.peripheral.identifier.UUIDString) {
      self.scannedPeripherals[per.peripheral.identifier.UUIDString] = per.peripheral;
      [list addObject:@{
        @"name": per.peripheral.name ?: @"Unknown Device",
        @"identifier": per.peripheral.identifier.UUIDString ?: @"",
        @"mac": per.mac ?: @"",
        @"rssi": per.RSSI ?: @(0),
        @"isPaired": @(per.isPaired)
      }];
    }
  }
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"scanResults",
      @"peripherals": list
    });
  }
}

- (void)didState:(QCState)state {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"deviceState",
      @"state": @(state)
    });
  }
}

- (void)didBluetoothState:(QCBluetoothState)state {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"bluetoothState",
      @"state": @(state)
    });
  }
}

- (void)didFailConnected:(CBPeripheral *)peripheral error:(nullable NSError*)error {
  if (self.eventSink) {
    self.eventSink(@{
      @"type": @"connectFail",
      @"identifier": peripheral.identifier.UUIDString ?: @"",
      @"error": error.localizedDescription ?: @"Connection failed"
    });
  }
}

@end
