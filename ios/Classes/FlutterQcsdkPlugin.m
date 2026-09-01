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
  
  [QCSDKManager shareInstance].debug = YES;
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

- (void)sendEvent:(NSDictionary *)event {
  if (!self.eventSink) return;
  if ([NSThread isMainThread]) {
    self.eventSink(event);
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.eventSink) {
        self.eventSink(event);
      }
    });
  }
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
  else if ([@"getDeviceState" isEqualToString:call.method]) {
    QCState state = [QCCentralManager shared].deviceState;
    result(@(state));
  }
  else if ([@"isDeviceConnected" isEqualToString:call.method]) {
    BOOL isConnected = ([QCCentralManager shared].deviceState == QCStateConnected);
    result(@(isConnected));
  }
  else if ([@"getConnectedDevice" isEqualToString:call.method]) {
    CBPeripheral *peripheral = [QCCentralManager shared].connectedPeripheral;
    if (peripheral && [QCCentralManager shared].deviceState == QCStateConnected) {
      NSString *uuid = peripheral.identifier.UUIDString ?: @"";
      NSString *name = peripheral.name ?: @"Smart Specs";
      result(@{
        @"name": name,
        @"identifier": uuid,
        @"mac": uuid,
        @"rssi": @(0),
        @"isPaired": @(YES)
      });
    } else {
      NSString *uuid = [[NSUserDefaults standardUserDefaults] objectForKey:@"QCLastConnectedIdentifier"];
      if (uuid && uuid.length > 0 && [QCCentralManager shared].deviceState == QCStateConnected) {
        result(@{
          @"name": @"Smart Specs",
          @"identifier": uuid,
          @"mac": uuid,
          @"rssi": @(0),
          @"isPaired": @(YES)
        });
      } else {
        result(nil);
      }
    }
  }
  else if ([@"connect" isEqualToString:call.method]) {
    NSString *identifier = call.arguments[@"identifier"];
    CBPeripheral *peripheral = self.scannedPeripherals[identifier];
    if (!peripheral && identifier.length > 0) {
      peripheral = [[QCCentralManager shared] periperalWithUUID:identifier];
    }
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
    NSLog(@"👓 [iOS QCSDK] openWifiWithMode called (mode: %ld)", (long)modeVal);
    [QCSDKCmdCreator openWifiWithMode:(QCOperatorDeviceMode)modeVal success:^(NSString *ssid, NSString *pwd) {
      NSLog(@"👓 [iOS QCSDK] openWifiWithMode SUCCESS -> SSID: '%@', PWD: '%@'", ssid, pwd);
      result(@{@"ssid": ssid ?: @"", @"password": pwd ?: @""});
    } fail:^(NSInteger errCode) {
      NSLog(@"⚠️ [iOS QCSDK] openWifiWithMode FAILED with errCode: %ld", (long)errCode);
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
    NSLog(@"👓 [iOS QCSDK] getDeviceWifiIP called");
    [QCSDKCmdCreator getDeviceWifiIPSuccess:^(NSString * _Nullable ipAddress) {
      NSLog(@"👓 [iOS QCSDK] getDeviceWifiIP SUCCESS -> IP: %@", ipAddress);
      result(ipAddress);
    } failed:^{
      NSLog(@"⚠️ [iOS QCSDK] getDeviceWifiIP FAILED");
      result([FlutterError errorWithCode:@"ERROR" message:@"Failed to get device WiFi IP" details:nil]);
    }];
  }
  else if ([@"getDeviceMedia" isEqualToString:call.method]) {
    NSLog(@"👓 [iOS QCSDK] getDeviceMedia called");
    [QCSDKCmdCreator getDeviceMedia:^(NSInteger photo, NSInteger video, NSInteger audio, NSInteger totalSize) {
      NSLog(@"👓 [iOS QCSDK] getDeviceMedia SUCCESS -> Photos: %ld, Videos: %ld, Audio: %ld, TotalSize: %ld bytes",
            (long)photo, (long)video, (long)audio, (long)totalSize);
      result(@{
        @"photoCount": @(photo),
        @"videoCount": @(video),
        @"audioCount": @(audio),
        @"totalSize": @(totalSize)
      });
    } fail:^{
      NSLog(@"⚠️ [iOS QCSDK] getDeviceMedia FAILED");
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
    @try {
      BOOL isOpen = [call.arguments[@"isOpen"] boolValue];
      [QCSDKCmdCreator setBTStatus:isOpen finished:^(BOOL success, NSError * _Nullable error) {
        if (success) {
          result(nil);
        } else {
          result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
        }
      }];
    } @catch (NSException *exception) {
      NSLog(@"⚠️ [iOS QCSDK] setBTStatus exception caught: %@", exception);
      result(nil);
    }
  }
  else if ([@"getBTStatus" isEqualToString:call.method]) {
    @try {
      [QCSDKCmdCreator getBTStatusWithFinished:^(BOOL success, NSError * _Nullable error) {
        if (success) {
          result(nil);
        } else {
          result([FlutterError errorWithCode:@"ERROR" message:error.localizedDescription details:nil]);
        }
      }];
    } @catch (NSException *exception) {
      NSLog(@"⚠️ [iOS QCSDK] getBTStatus exception caught (vendor bug in QCDFU_Utils): %@", exception);
      result(nil);
    }
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
    NSLog(@"👓 [iOS QCSDK] startToDownloadMediaResource initiated");
    __weak typeof(self) weakSelf = self;
    [[QCSDKManager shareInstance] startToDownloadMediaResourceWithProgress:^(NSInteger receivedSize, NSInteger expectedSize, CGFloat progress) {
      NSLog(@"👓 [iOS QCSDK] Download Progress: %ld / %ld bytes (%.1f%%)", (long)receivedSize, (long)expectedSize, progress * 100.0);
      [weakSelf sendEvent:@{
        @"type": @"downloadProgress",
        @"receivedSize": @(receivedSize),
        @"expectedSize": @(expectedSize),
        @"progress": @(progress)
      }];
    } completion:^(NSString * _Nullable filePath, NSError * _Nullable error, NSInteger index, NSInteger count) {
      if (error) {
        NSString *reason = @"";
        switch (error.code) {
          case 2000: reason = @"QCErrorCodeInvalidWifiOrPassword (WiFi or password is empty)"; break;
          case 2001: reason = @"QCErrorCodeFailedToGetGlassesIP (iPhone not connected to glasses Wi-Fi hotspot)"; break;
          case 2002: reason = @"QCErrorCodeFailedToGetAppIP (Failed to obtain iPhone IP address)"; break;
          case 2003: reason = @"QCErrorCodeLocalNetworkNotAuthorized (iOS Local Network permission denied/missing)"; break;
          case 2004: reason = @"QCErrorCodeDownloadConfigFileFailed (HTTP request to glasses config failed)"; break;
          case 2005: reason = @"QCErrorCodeDownloadFileFailed (HTTP download of media file failed)"; break;
          case 2006: reason = @"QCErrorCodeFileListEmpty (No media files on device)"; break;
          default: reason = error.localizedDescription ?: @"Unknown error"; break;
        }
        NSLog(@"⚠️ [iOS QCSDK] Download Error: code=%ld, reason='%@', domain=%@, details=%@",
              (long)error.code, reason, error.domain, error.userInfo);
      } else {
        NSLog(@"✅ [iOS QCSDK] Download File Success [%ld/%ld]: path='%@'",
              (long)index + 1, (long)count, filePath ?: @"(empty completion)");
      }
      [weakSelf sendEvent:@{
        @"type": @"downloadComplete",
        @"filePath": filePath ?: @"",
        @"error": error ? [NSString stringWithFormat:@"[%ld] %@", (long)error.code, error.localizedDescription ?: @""] : @"",
        @"index": @(index),
        @"count": @(count)
      }];
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
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.eventSink) {
      self.eventSink(@{
        @"type": @"bluetoothState",
        @"state": @([QCCentralManager shared].bleState)
      });
      self.eventSink(@{
        @"type": @"deviceState",
        @"state": @([QCCentralManager shared].deviceState)
      });
    }
  });
  return nil;
}

- (FlutterError * _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  self.eventSink = nil;
  return nil;
}

#pragma mark - QCSDKManagerDelegate

- (void)didUpdateBatteryLevel:(NSInteger)battery charging:(BOOL)charging {
  [self sendEvent:@{
    @"type": @"batteryLevel",
    @"battery": @(battery),
    @"charging": @(charging)
  }];
}

- (void)didUpdateMediaWithPhotoCount:(NSInteger)photo videoCount:(NSInteger)video audioCount:(NSInteger)audio type:(NSInteger)type {
  [self sendEvent:@{
    @"type": @"mediaUpdate",
    @"photoCount": @(photo),
    @"videoCount": @(video),
    @"audioCount": @(audio),
    @"mediaType": @(type)
  }];
}

- (void)didReceiveAIChatTextMessage:(NSString *)message {
  [self sendEvent:@{
    @"type": @"aiChatText",
    @"message": message ?: @""
  }];
}

- (void)didReceiveAIChatVoiceData:(NSData *)pcmData {
  if (pcmData) {
    FlutterStandardTypedData *typedData = [FlutterStandardTypedData typedDataWithBytes:pcmData];
    [self sendEvent:@{
      @"type": @"aiChatVoice",
      @"data": typedData
    }];
  }
}

- (void)didReceiveAIChatImageData:(NSData *)imageData {
  if (imageData) {
    FlutterStandardTypedData *typedData = [FlutterStandardTypedData typedDataWithBytes:imageData];
    [self sendEvent:@{
      @"type": @"aiChatImage",
      @"data": typedData
    }];
  }
}

- (void)didUpdateWiFiUpgradeProgressWithDownload:(NSInteger)download upgrade1:(NSInteger)upgrade1 upgrade2:(NSInteger)upgrade2 {
  [self sendEvent:@{
    @"type": @"wifiUpgradeProgress",
    @"download": @(download),
    @"upgrade1": @(upgrade1),
    @"upgrade2": @(upgrade2)
  }];
}

- (void)didReceiveWiFiUpgradeResult:(BOOL)success {
  [self sendEvent:@{
    @"type": @"wifiUpgradeResult",
    @"success": @(success)
  }];
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
  [self sendEvent:@{
    @"type": @"scanResults",
    @"peripherals": list
  }];
}

- (void)didState:(QCState)state {
  [self sendEvent:@{
    @"type": @"deviceState",
    @"state": @(state)
  }];
}

- (void)didBluetoothState:(QCBluetoothState)state {
  [self sendEvent:@{
    @"type": @"bluetoothState",
    @"state": @(state)
  }];
}

- (void)didFailConnected:(CBPeripheral *)peripheral error:(nullable NSError*)error {
  [self sendEvent:@{
    @"type": @"connectFail",
    @"identifier": peripheral.identifier.UUIDString ?: @"",
    @"error": error.localizedDescription ?: @"Connection failed"
  }];
}

@end
