#import "GlassesMediaDownloader.h"

#import <NetworkExtension/NetworkExtension.h>
#import <QCSDK/QCSDKCmdCreator.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <arpa/inet.h>
#import <ifaddrs.h>

static NSString *const GlassesMediaDownloaderErrorDomain =
    @"GlassesMediaDownloaderErrorDomain";

typedef NS_ENUM(NSInteger, GlassesMediaDownloaderErrorCode) {
  GlassesMediaDownloaderErrorCodeWifiCredentials = 1,
  GlassesMediaDownloaderErrorCodeWifiIP,
  GlassesMediaDownloaderErrorCodeHotspotUnavailable,
  GlassesMediaDownloaderErrorCodeManifest,
  GlassesMediaDownloaderErrorCodeDownload,
  GlassesMediaDownloaderErrorCodeFilesystem
};

@interface GlassesMediaDownloader ()
@property(nonatomic, copy) GlassesMediaDownloaderStatusHandler statusHandler;
@property(nonatomic, copy)
    GlassesMediaDownloaderCompletionHandler completionHandler;
@property(nonatomic, copy) NSString *ssid;
@property(nonatomic, copy) NSString *password;
@property(nonatomic, copy) NSString *deviceIP;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURL *lastManifestURL;
@property(nonatomic, assign) BOOL didFinish;
@property(nonatomic, assign) BOOL isRequestingWifiCredentials;
@end

@implementation GlassesMediaDownloader

+ (NSString *)getWiFiAddress {
  NSString *address = nil;
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = getifaddrs(&interfaces);
  if (success == 0) {
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
        NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
        if ([name isEqualToString:@"en0"]) {
          address =
              [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)
                                                            temp_addr->ifa_addr)
                                                           ->sin_addr)];
          break;
        }
      }
      temp_addr = temp_addr->ifa_next;
    }
  }
  if (interfaces) {
    freeifaddrs(interfaces);
  }
  return address;
}

- (instancetype)initWithStatusHandler:
    (GlassesMediaDownloaderStatusHandler)statusHandler {
  self = [super init];
  if (self) {
    _statusHandler = [statusHandler copy];
    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    config.allowsCellularAccess =
        NO; // Force Wi-Fi en0 only (no cellular interference)
    config.timeoutIntervalForRequest = 20.0;
    config.timeoutIntervalForResource = 120.0;
    config.waitsForConnectivity = YES;
    config.HTTPMaximumConnectionsPerHost = 1;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.HTTPAdditionalHeaders = @{@"Connection" : @"close"};
    if (@available(iOS 13.0, *)) {
      config.allowsExpensiveNetworkAccess = YES;
      config.allowsConstrainedNetworkAccess = YES;
    }
    _session = [NSURLSession sessionWithConfiguration:config];
    _isRequestingWifiCredentials = NO;
  }
  return self;
}

- (void)startDownloadWithCompletion:
    (GlassesMediaDownloaderCompletionHandler)completion {
  self.completionHandler = [completion copy];
  self.didFinish = NO;
  [self updateStatus:@"Requesting Wi-Fi credentials..." preview:nil];
  [self requestWifiCredentials];
}

#pragma mark - Flow

- (void)requestWifiCredentials {
  if (self.isRequestingWifiCredentials) {
    NSLog(@"🔥 WiFi credentials already being requested, skipping duplicate");
    return;
  }

  self.isRequestingWifiCredentials = YES;
  __weak typeof(self) weakSelf = self;
  NSLog(@"🔥 requestWifiCredentials called - enabling WiFi transfer mode via "
        @"Bluetooth");

  [self updateStatus:@"Preparing glasses for WiFi transfer..." preview:nil];

  // Step 1: Enable WiFi transfer mode via Bluetooth
  [QCSDKCmdCreator openWifiWithMode:QCOperatorDeviceModeTransfer
      success:^(NSString *ssid, NSString *password) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }

        strongSelf.ssid = ssid ?: @"";
        strongSelf.password = password ?: @"";
        strongSelf.deviceIP = @"192.168.31.1";
        strongSelf.isRequestingWifiCredentials = NO;

        NSLog(@"🔥 SUCCESS: Glasses enabled WiFi transfer mode -> SSID: '%@'",
              ssid);
        [strongSelf
            updateStatus:[NSString
                             stringWithFormat:@"Glasses hotspot ready: %@",
                                              ssid ?: @"<unknown>"]
                 preview:nil];

        // Step 2: Directly trigger iOS native Wi-Fi connection
        [strongSelf applyHotspotConfigurationOnce];
      }
      fail:^(NSInteger code) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        strongSelf.isRequestingWifiCredentials = NO;
        NSLog(@"🔥 FAILED: Could not enable WiFi transfer mode, code: %ld",
              (long)code);

        [strongSelf updateStatus:@"Failed to enable WiFi transfer mode"
                         preview:nil];

        NSError *error = [NSError
            errorWithDomain:GlassesMediaDownloaderErrorDomain
                       code:GlassesMediaDownloaderErrorCodeWifiCredentials
                   userInfo:@{
                     NSLocalizedDescriptionKey :
                         @"Glasses could not enable WiFi transfer mode"
                   }];
        [strongSelf finishWithError:error];
      }];
}

- (void)applyHotspotConfigurationOnce {
  if (@available(iOS 11.0, *)) {
    NSLog(@"📱 Applying NEHotspotConfiguration for SSID: '%@'", self.ssid);

    NEHotspotConfiguration *configuration = nil;
    if (self.password.length > 0) {
      configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid
                                                        passphrase:self.password
                                                             isWEP:NO];
    } else {
      configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid];
    }

    configuration.joinOnce = NO; // Keep Wi-Fi route active!
    if (@available(iOS 13.0, *)) {
      configuration.lifeTimeInDays = @1;
    }

    __weak typeof(self) weakSelf = self;
    [[NEHotspotConfigurationManager sharedManager]
        applyConfiguration:configuration
         completionHandler:^(NSError *_Nullable error) {
           __strong typeof(weakSelf) strongSelf = weakSelf;
           if (!strongSelf) {
             return;
           }

           dispatch_async(dispatch_get_main_queue(), ^{
             if (error &&
                 error.code == 7) { // NEHotspotConfigurationErrorUserDenied
               NSLog(@"⚠️ User cancelled Wi-Fi join prompt");
               NSError *userDeniedErr = [NSError
                   errorWithDomain:GlassesMediaDownloaderErrorDomain
                              code:7
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"[7] Wi-Fi connection cancelled by user"
                          }];
               [strongSelf finishWithError:userDeniedErr];
               return;
             }

             NSLog(@"✅ Hotspot configuration applied (error: %@). Polling "
                   @"connection to glasses at 192.168.31.1...",
                   error ? error.localizedDescription : @"none");
             [strongSelf updateStatus:@"Connecting to glasses Wi-Fi..."
                              preview:nil];

             // Poll connection to 192.168.31.1 every 1.0s for up to 30 attempts
             [strongSelf pollConnectionToGlassesWithAttempt:1 maxAttempts:30];
           });
         }];
  }
}

- (void)pollConnectionToGlassesWithAttempt:(NSInteger)attempt
                               maxAttempts:(NSInteger)maxAttempts {
  if (self.didFinish)
    return;

  NSString *localIP = [GlassesMediaDownloader getWiFiAddress];
  NSLog(@"🔍 [WiFi Poll %ld/%ld] Local en0 IP: %@", (long)attempt,
        (long)maxAttempts, localIP ?: @"(none)");

  // Test reachability to media.config directly
  NSURL *testURL =
      [NSURL URLWithString:@"http://192.168.31.1/files/media.config"];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:2.0];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf || strongSelf.didFinish)
            return;

          dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              NSLog(@"🎉 SUCCESS: Connected to glasses at 192.168.31.1! "
                    @"Parsing media.config...");
              [strongSelf updateStatus:@"Connected! Downloading files..."
                               preview:nil];
              strongSelf.deviceIP = @"192.168.31.1";
              [strongSelf downloadManifestFromCustomURL:
                              @"http://192.168.31.1/files/media.config"];
              return;
            }

            if (attempt >= maxAttempts) {
              NSLog(@"❌ TIMEOUT: Could not connect to glasses Wi-Fi after %ld "
                    @"attempts",
                    (long)maxAttempts);
              NSError *timeoutError = [NSError
                  errorWithDomain:GlassesMediaDownloaderErrorDomain
                             code:GlassesMediaDownloaderErrorCodeWifiIP
                         userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Could not connect to glasses Wi-Fi. Please "
                               @"tap 'Get' again and tap 'Join'."
                         }];
              [strongSelf finishWithError:timeoutError];
              return;
            }

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                  [strongSelf pollConnectionToGlassesWithAttempt:attempt + 1
                                                     maxAttempts:maxAttempts];
                });
          });
        }];
  [task resume];
}

- (void)waitForHotspotReadiness {
  [self applyHotspotConfigurationOnce];
}

- (void)checkGlassesHotspotReadinessWithRetry:(NSInteger)retry {
  const NSInteger maxRetries = 10;

  NSLog(@"🔍 Checking glasses hotspot readiness (attempt %ld/%ld)...",
        (long)(retry + 1), (long)(maxRetries));

  // Check if the device can provide its WiFi IP - this indicates hotspot is
  // ready
  [QCSDKCmdCreator
      getDeviceWifiIPSuccess:^(NSString *_Nullable ipAddress) {
        if (ipAddress.length > 0) {
          NSLog(@"🎉 SUCCESS: Glasses hotspot is ready! Device IP: %@",
                ipAddress);
          [self
              updateStatus:[NSString
                               stringWithFormat:@"Glasses hotspot ready at %@",
                                                ipAddress]
                   preview:nil];

          // Store the IP and proceed with iOS-native WiFi joining
          self.deviceIP = ipAddress;
          [self triggerIOSNativeWiFiJoin];
        } else {
          NSLog(@"⏳ Glasses hotspot not ready yet, retrying...");
          [self retryHotspotReadinessCheck:retry maxRetries:maxRetries];
        }
      }
      failed:^{
        NSLog(@"⏳ Glasses not ready for WiFi yet, retrying...");
        [self retryHotspotReadinessCheck:retry maxRetries:maxRetries];
      }];
}

- (void)retryHotspotReadinessCheck:(NSInteger)retry
                        maxRetries:(NSInteger)maxRetries {
  if (retry >= maxRetries - 1) {
    NSLog(@"❌ TIMEOUT: Glasses hotspot failed to become ready after %ld "
          @"attempts",
          (long)maxRetries);
    [self updateStatus:@"Glasses hotspot failed to activate" preview:nil];

    NSError *error = [NSError
        errorWithDomain:GlassesMediaDownloaderErrorDomain
                   code:GlassesMediaDownloaderErrorCodeHotspotUnavailable
               userInfo:@{
                 NSLocalizedDescriptionKey :
                     @"Glasses hotspot failed to activate within expected time"
               }];
    [self finishWithError:error];
    return;
  }

  // Exponential backoff: 1s, 2s, 4s, 8s...
  NSTimeInterval delay = pow(2, retry);
  NSLog(@"⏱️ Waiting %.0fs before next readiness check...", delay);

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self checkGlassesHotspotReadinessWithRetry:retry + 1];
      });
}

- (void)triggerIOSNativeWiFiJoin {
  NSLog(@"📱 Triggering iOS-native WiFi joining for hotspot: %@", self.ssid);
#if CYAN_FREE_PROVISIONING
  // Free provisioning cannot sign the Hotspot entitlement, so the user joins
  // the hotspot in Settings.
  [self waitForManualJoinWithAttempt:0];
#else
  [self updateStatus:[NSString
                         stringWithFormat:@"Joining %@ via iOS...", self.ssid]
             preview:nil];

  // Try the modern NEHotspotConfiguration approach first
  // But with better timing - only apply once, then let iOS handle it
  if (@available(iOS 11.0, *)) {
    [self applyHotspotConfigurationOnce];
  } else {
    [self showManualConnectionInstructions];
  }
#endif
}

#if CYAN_FREE_PROVISIONING
- (void)waitForManualJoinWithAttempt:(NSInteger)attempt {
  const NSInteger maxAttempts = 40; // ~2 minutes at 3s intervals
  if (self.didFinish) {
    return;
  }

  if (attempt >= maxAttempts) {
    NSLog(@"⏱️ Manual join window expired, falling back to IP scan");
    [self performComprehensiveIPScan];
    return;
  }

  NSString *password = self.password.length > 0 ? self.password : @"(none)";
  NSString *instructions = [NSString
      stringWithFormat:
          @"📶 Open Settings ▸ Wi-Fi and join:\n%@\nPassword: %@ (if rejected, "
          @"try 123456789)\n\nWaiting for connection (%ld/%ld)...",
          self.ssid, password, (long)attempt + 1, (long)maxAttempts];
  [self updateStatus:instructions preview:nil];

  NSString *ip = self.deviceIP.length > 0 ? self.deviceIP : @"192.168.31.1";
  NSURL *testURL = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://%@/files/media.config", ip]];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:2.0];

  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              NSLog(@"✅ Manual join detected, glasses reachable at %@", ip);
              self->_deviceIP = ip;
              [self verifyWiFiConnectionAndProceed];
            } else {
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                           (int64_t)(3.0 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{
                               [self waitForManualJoinWithAttempt:attempt + 1];
                             });
            }
          });
        }] resume];
}
#endif

- (void)checkIfiOSConnectedToWiFi:(NSString *)expectedSSID
                         deviceIP:(NSString *)deviceIP {
  // Check if iOS actually connected to the expected WiFi network
  CFArrayRef interfaces = CNCopySupportedInterfaces();
  BOOL isConnectedToCorrectWiFi = NO;

  if (interfaces) {
    for (int i = 0; i < CFArrayGetCount(interfaces); i++) {
      CFStringRef interface = CFArrayGetValueAtIndex(interfaces, i);
      CFDictionaryRef networkInfo = CNCopyCurrentNetworkInfo(interface);

      if (networkInfo) {
        NSString *currentSSID =
            CFDictionaryGetValue(networkInfo, kCNNetworkInfoKeySSID);
        NSLog(@"📱 Current WiFi SSID: %@", currentSSID ?: @"(none)");

        if (currentSSID && [currentSSID isEqualToString:expectedSSID]) {
          NSLog(@"✅ iOS successfully connected to WiFi: %@", currentSSID);
          isConnectedToCorrectWiFi = YES;
        }

        CFRelease(networkInfo);
      }
    }
    CFRelease(interfaces);
  }

  if (isConnectedToCorrectWiFi) {
    NSLog(@"🔗 iOS is connected to correct WiFi, testing connectivity...");
    [self updateStatus:@"Connected! Testing data connection..." preview:nil];
    [self testConnectionWithKnownIP];
  } else {
    NSLog(@"❌ iOS did NOT connect to WiFi: %@", expectedSSID);
    NSLog(@"❌ iOS may have stayed on cellular or failed to join the network");

    [self updateStatus:@"iOS didn't join WiFi. Please check Settings and tap "
                       @"'Use Without Internet' if prompted."
               preview:nil];

    // Wait additional time and retry (extended for WiFi-dense environments)
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          NSLog(@"🔄 Retrying connection check after additional wait...");
          [self checkIfiOSConnectedToWiFi:expectedSSID deviceIP:deviceIP];
        });
  }
}

- (void)testConnectionWithKnownIP {
  if (!self.deviceIP || self.deviceIP.length == 0) {
    self.deviceIP = @"192.168.31.1";
  }
  NSLog(@"🔗 Testing connection to device IP: %@", self.deviceIP);

  [self updateStatus:[NSString stringWithFormat:@"Testing connection to %@...",
                                                self.deviceIP]
             preview:nil];

  NSURL *testURL = [NSURL
      URLWithString:[NSString stringWithFormat:@"http://%@/files/media.config",
                                               self.deviceIP]];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:10.0];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              NSLog(@"🎉 SUCCESS: Connected to glasses at %@", self.deviceIP);
              [self updateStatus:@"✅ Connected! Starting download..."
                         preview:nil];

              // Start the download process
              [self discoverAllEndpointsForIP:self.deviceIP];

            } else {
              NSLog(@"❌ Connection test failed: %@",
                    error.localizedDescription);
              [self updateStatus:@"Connection failed. Trying common IPs..."
                         preview:nil];

              // Fall back to trying common IP addresses
              [self testConnectionWithCommonIPs];
            }
          });
        }];
  [task resume];
}

- (void)tryHotspotConfiguration {
  NSLog(@"🔥 Trying hotspot configuration - PERSISTENT approach");
  [self updateStatus:@"Configuring WiFi automatically..." preview:nil];

  if (@available(iOS 11.0, *)) {
    [self joinHotspotWithAggressiveConfig];
  } else {
    [self showManualConnectionInstructions];
  }
}

- (void)joinHotspotWithAggressiveConfig {
  if (@available(iOS 11.0, *)) {
    NSLog(@"🔥 joinHotspotWithAggressiveConfig called with SSID: %@",
          self.ssid);

    // Create aggressive configuration - multiple attempts with different
    // settings
    [self attemptHotspotConfigurationWithJoinOnce:NO attempt:1];
  }
}

- (void)attemptHotspotConfigurationWithJoinOnce:(BOOL)joinOnce
                                        attempt:(NSInteger)attempt {
  if (@available(iOS 11.0, *)) {
    NSLog(@"🔥 Attempt %ld: joinOnce=%d for SSID: %@", (long)attempt, joinOnce,
          self.ssid);

    NEHotspotConfiguration *configuration = nil;

    if (self.password.length > 0) {
      configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid
                                                        passphrase:self.password
                                                             isWEP:NO];
    } else {
      configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid];
    }

    // Aggressive configuration options
    configuration.joinOnce = joinOnce;
    if (@available(iOS 13.0, *)) {
      configuration.lifeTimeInDays = @1;
    }

    __weak typeof(self) weakSelf = self;

    [[NEHotspotConfigurationManager sharedManager]
        applyConfiguration:configuration
         completionHandler:^(NSError *_Nullable error) {
           __strong typeof(weakSelf) strongSelf = weakSelf;
           if (!strongSelf) {
             return;
           }

           dispatch_async(dispatch_get_main_queue(), ^{
             if (!error) {
               NSLog(@"🔥 SUCCESS: Applied hotspot configuration (attempt %ld)",
                     (long)attempt);
               [strongSelf
                   updateStatus:@"WiFi configured! Waiting for connection..."
                        preview:nil];

               // Wait for connection - LONGER time like working apps
               dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(12.0 * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                                [strongSelf testConnectionAfterAggressiveJoin];
                              });
             } else if (error.code ==
                        NEHotspotConfigurationErrorAlreadyAssociated) {
               NSLog(@"🔥 Already associated - testing connection");
               [strongSelf updateStatus:@"Already connected! Testing..."
                                preview:nil];
               dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(5.0 * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                                [strongSelf testConnectionAfterAggressiveJoin];
                              });
             } else if (attempt < 3) {
               NSLog(@"🔥 Attempt %ld failed, retrying with different "
                     @"settings: %@",
                     (long)attempt, error.localizedDescription);
               [strongSelf attemptHotspotConfigurationWithJoinOnce:!joinOnce
                                                           attempt:attempt + 1];
             } else {
               NSLog(@"🔥 All hotspot attempts failed: %@",
                     error.localizedDescription);
               [strongSelf
                   updateStatus:@"Auto WiFi failed. Manual connection needed."
                        preview:nil];

               // Wait before showing manual instructions
               dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(3.0 * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                                [strongSelf showManualConnectionInstructions];
                              });
             }
           });
         }];
  }
}

- (void)testConnectionAfterAggressiveJoin {
  NSLog(@"🔥 Testing connection after AGGRESSIVE hotspot join");
  [self updateStatus:@"Testing WiFi connection..." preview:nil];

  // Aggressive connection testing like working apps
  [self testConnectionWithIncreasingTimeouts];
}

- (void)testConnectionWithIncreasingTimeouts {
  NSLog(@"🔥 Starting aggressive connection testing");

  // Try multiple approaches with increasing timeouts
  [self tryGetDeviceIPWithTimeout:5.0 attempt:1];
}

- (void)tryGetDeviceIPWithTimeout:(NSTimeInterval)timeout
                          attempt:(NSInteger)attempt {
  NSLog(@"🔥 Getting device IP with timeout %.1f, attempt %ld", timeout,
        (long)attempt);

  [QCSDKCmdCreator
      getDeviceWifiIPSuccess:^(NSString *_Nullable ipAddress) {
        if (ipAddress.length > 0) {
          NSLog(@"🔥 Got device IP: %@", ipAddress);
          [self updateStatus:[NSString
                                 stringWithFormat:
                                     @"Found device! Testing connection to %@",
                                     ipAddress]
                     preview:nil];
          [self testConnectionToIPWithTimeout:ipAddress timeout:timeout];
        } else if (attempt < 3) {
          NSLog(@"🔥 No IP on attempt %ld, retrying with longer timeout",
                (long)attempt);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [self tryGetDeviceIPWithTimeout:timeout + 3.0
                                        attempt:attempt + 1];
              });
        } else {
          NSLog(@"🔥 No device IP after multiple attempts");
          [self testConnectionWithCommonIPs];
        }
      }
      failed:^{
        if (attempt < 3) {
          NSLog(@"🔥 QCSDK failed on attempt %ld, retrying", (long)attempt);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [self tryGetDeviceIPWithTimeout:timeout + 3.0
                                        attempt:attempt + 1];
              });
        } else {
          NSLog(@"🔥 QCSDK failed after multiple attempts");
          [self testConnectionWithCommonIPs];
        }
      }];
}

- (void)testConnectionToIPWithTimeout:(NSString *)ip
                              timeout:(NSTimeInterval)timeout {
  NSLog(@"🔥 Testing connection to %@ with timeout %.1f", ip, timeout);

  [self updateStatus:[NSString
                         stringWithFormat:@"Testing connection to %@...", ip]
             preview:nil];

  // Use shorter timeout for initial test, but with retry logic
  NSTimeInterval adjustedTimeout = (timeout > 5.0) ? 3.0 : timeout;
  NSURL *testURL = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://%@/files/media.config", ip]];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:adjustedTimeout];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              NSLog(@"🔥 SUCCESS: Connected to device at %@", ip);
              [self updateStatus:[NSString
                                     stringWithFormat:@"✅ CONNECTED to %@", ip]
                         preview:nil];
              // Set deviceIP BEFORE proceeding to download manifest
              self->_deviceIP = ip;
              // Verify WiFi connection is established before downloading
              [self verifyWiFiConnectionAndProceed];
            } else {
              NSLog(@"🔥 Failed to connect to %@: %@", ip,
                    error.localizedDescription);
              // If this was the original IP from QCSDK, try it once more with
              // longer timeout
              if ([ip isEqualToString:@"3.192.168.31"] && timeout <= 5.0) {
                NSLog(@"🔥 Retrying original IP with longer timeout...");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                 [self testConnectionToIPWithTimeout:ip
                                                             timeout:8.0];
                               });
              } else {
                [self testConnectionWithCommonIPs];
              }
            }
          });
        }];
  [task resume];
}

- (void)verifyWiFiConnectionAndProceed {
  NSLog(@"🔥 Verifying WiFi connection is stable before proceeding");
  [self updateStatus:@"Verifying WiFi connection..." preview:nil];

  // Test connectivity multiple times to ensure stable connection
  [self testConnectivityWithRetries:3 attempt:1];
}

- (void)testConnectivityWithRetries:(NSInteger)maxRetries
                            attempt:(NSInteger)attempt {
  if (self->_deviceIP.length == 0) {
    NSLog(@"🔥 ERROR: No device IP set for connectivity test");
    [self testConnectionWithCommonIPs];
    return;
  }

  NSURL *testURL = [NSURL
      URLWithString:[NSString stringWithFormat:@"http://%@/files/media.config",
                                               self->_deviceIP]];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:2.0]; // Reduced from 3.0

  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              NSLog(@"🔥 WiFi connection verified successfully (attempt %ld)",
                    (long)attempt);
              [self updateStatus:[NSString
                                     stringWithFormat:@"✅ WiFi stable at %@",
                                                      self->_deviceIP]
                         preview:nil];
              // Now proceed with endpoint discovery
              [self discoverAllEndpointsForIP:self->_deviceIP];
            } else if (attempt < maxRetries) {
              NSLog(@"🔥 WiFi test failed on attempt %ld, retrying...",
                    (long)attempt);
              [self updateStatus:[NSString
                                     stringWithFormat:
                                         @"Testing connection... (attempt %ld)",
                                         (long)attempt]
                         preview:nil];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                           (int64_t)(1.0 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{ // Reduced from 2.0
                               [self testConnectivityWithRetries:maxRetries
                                                         attempt:attempt + 1];
                             });
            } else {
              NSLog(@"🔥 WiFi connection test failed after %ld attempts",
                    (long)attempt);
              [self updateStatus:@"WiFi connection unstable" preview:nil];
              [self testConnectionWithCommonIPs];
            }
          });
        }] resume];
}

- (void)testConnectionAfterEnhancedHotspotJoin {
  NSLog(@"🔥 Testing connection after enhanced hotspot join");
  [self updateStatus:@"Testing enhanced connection..." preview:nil];

  // Check network connectivity with multiple approaches
  [self checkNetworkConnectivityWithCompletion:^(BOOL isConnected) {
    if (isConnected) {
      NSLog(@"🔥 Network connectivity confirmed, trying device connection");
      [self tryFinalConnectionTest];
    } else {
      NSLog(@"🔥 No network connectivity, falling back to manual instructions");
      [self showManualConnectionInstructions];
    }
  }];
}

- (void)checkNetworkConnectivityWithCompletion:(void (^)(BOOL))completion {
  // Test internet connectivity by trying to reach apple.com
  NSURL *testURL = [NSURL URLWithString:@"http://captive.apple.com"];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:3.0];

  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          BOOL canReachInternet =
              !error && ((NSHTTPURLResponse *)response).statusCode == 200;
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(canReachInternet);
          });
        }] resume];
}

- (void)tryFinalConnectionTest {
  NSLog(@"🔥 Final connection test attempt");
  [self updateStatus:@"Final connection test..." preview:nil];

  [QCSDKCmdCreator
      getDeviceWifiIPSuccess:^(NSString *_Nullable ipAddress) {
        if (ipAddress.length > 0) {
          [self testConnectionToIP:ipAddress];
        } else {
          [self showManualConnectionInstructions];
        }
      }
      failed:^{
        [self showManualConnectionInstructions];
      }];
}

- (void)showManualConnectionInstructions {
  NSLog(@"🔥 Showing enhanced manual connection instructions");
  NSString *instructions = [NSString
      stringWithFormat:
          @"📶 MANUALLY join WiFi:\n%@\n\n👆 Then wait for connection...",
          self.ssid];
  [self updateStatus:instructions preview:nil];

  // Try connection after giving user more time to manually connect
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self tryConnectionAfterManualPrompt];
      });
}

- (void)tryConnectionAfterManualPrompt {
  NSLog(@"🔥 Testing connection after manual prompt");
  [self updateStatus:@"Testing manual connection..." preview:nil];

  // First check if we can get device IP through QCSDK
  [QCSDKCmdCreator
      getDeviceWifiIPSuccess:^(NSString *_Nullable ipAddress) {
        if (ipAddress.length > 0) {
          NSLog(@"🔥 Got device IP after manual prompt: %@", ipAddress);
          [self updateStatus:[NSString stringWithFormat:@"Found device at %@",
                                                        ipAddress]
                     preview:nil];
          [self testConnectionToIP:ipAddress];
        } else {
          NSLog(@"🔥 No IP from QCSDK, trying comprehensive IP scan");
          [self performComprehensiveIPScan];
        }
      }
      failed:^{
        NSLog(@"🔥 QCSDK failed, trying comprehensive IP scan");
        [self performComprehensiveIPScan];
      }];
}

- (void)performComprehensiveIPScan {
  [self updateStatus:@"Scanning for glasses device..." preview:nil];

  // Expanded list of common glasses IPs
  NSArray *comprehensiveIPs = @[
    @"192.168.43.1", @"192.168.4.1", @"192.168.1.1", @"192.168.0.1",
    @"192.168.31.1", @"192.168.100.1", @"192.168.123.1", @"192.168.137.1",
    @"3.192.168.31", @"10.0.0.1", @"172.20.10.1"
  ];

  __block NSString *workingIP = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  NSLog(@"🔥 Starting comprehensive IP scan with %lu IPs",
        (unsigned long)comprehensiveIPs.count);

  for (NSString *ip in comprehensiveIPs) {
    NSURL *testURL = [NSURL
        URLWithString:[NSString
                          stringWithFormat:@"http://%@/files/media.config",
                                           ip]];
    NSURLRequest *request =
        [NSURLRequest requestWithURL:testURL
                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                     timeoutInterval:2.0];

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              workingIP = ip;
              NSLog(@"🔥 Found working IP: %@", ip);
            }
            dispatch_semaphore_signal(semaphore);
          }] resume];

    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)));
    if (workingIP)
      break;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (workingIP) {
      self->_deviceIP = workingIP;
      [self updateStatus:[NSString
                             stringWithFormat:@"✅ Connected to glasses at %@",
                                              workingIP]
                 preview:nil];
      // Verify WiFi connection before proceeding to manifest download
      [self verifyWiFiConnectionAndProceed];
    } else {
      [self showFinalErrorMessage];
    }
  });
}

- (void)showFinalErrorMessage {
  NSString *errorMessage =
      [NSString stringWithFormat:
                    @"❌ Connection failed!\n\n1. 📶 Join WiFi: %@\n2. 🔋 "
                    @"Ensure glasses are ON\n3. 🔄 Try restarting app\n\nNote: "
                    @"Auto WiFi doesn't work reliably on iOS 18+",
                    self.ssid];
  [self updateStatus:errorMessage preview:nil];

  NSError *error = [NSError
      errorWithDomain:GlassesMediaDownloaderErrorDomain
                 code:GlassesMediaDownloaderErrorCodeWifiIP
             userInfo:@{
               NSLocalizedDescriptionKey :
                   @"Could not establish connection to glasses device. Please "
                   @"check WiFi connection and try again."
             }];
  [self finishWithError:error];
}

- (void)promptForManualHotspot {
  [self updateStatus:
            @"Please connect to glasses WiFi hotspot (AM01W_XXXX) manually"
             preview:nil];

  // Try common glasses SSIDs after user has time to connect manually
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __weak typeof(self) weakSelf = self;
        [self tryCommonGlassesIPs];
      });
}

- (void)tryCommonGlassesIPs {
  [self updateStatus:@"Looking for glasses on network..." preview:nil];

  // Try common glasses IPs to find the device
  NSArray *commonIPs = @[
    @"192.168.1.1", @"192.168.0.1", @"192.168.43.1", @"192.168.4.1",
    @"192.168.31.1"
  ];

  __block NSString *workingIP = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  for (NSString *ip in commonIPs) {
    NSURL *testURL = [NSURL
        URLWithString:[NSString
                          stringWithFormat:@"http://%@/files/media.config",
                                           ip]];
    NSURLRequest *request =
        [NSURLRequest requestWithURL:testURL
                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                     timeoutInterval:2.0];

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              workingIP = ip;
            }
            dispatch_semaphore_signal(semaphore);
          }] resume];

    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));
    if (workingIP)
      break;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (workingIP) {
      self->_deviceIP = workingIP;
      [self updateStatus:[NSString
                             stringWithFormat:@"Found glasses at %@", workingIP]
                 preview:nil];
      // Verify WiFi connection before proceeding to manifest download
      [self verifyWiFiConnectionAndProceed];
    } else {
      NSError *error =
          [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                              code:GlassesMediaDownloaderErrorCodeWifiIP
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Could not find glasses. Please ensure you're "
                                @"connected to the glasses WiFi hotspot."
                          }];
      [self finishWithError:error];
    }
  });
}

- (void)requestDeviceIP {
  __weak typeof(self) weakSelf = self;
  NSLog(@"🔥 requestDeviceIP called after hotspot join");
  [self updateStatus:@"Retrieving device IP address..." preview:nil];
  [QCSDKCmdCreator
      getDeviceWifiIPSuccess:^(NSString *_Nullable ipAddress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        NSLog(@"🔥 Got IP address: %@", ipAddress ?: @"nil");
        if (ipAddress.length == 0) {
          NSLog(@"🔥 IP address is empty, testing connection manually");
          [strongSelf testConnectionWithCommonIPs];
          return;
        }
        NSLog(@"🔥 Setting device IP to: %@", ipAddress);
        strongSelf->_deviceIP = ipAddress;
        [strongSelf
            updateStatus:[NSString
                             stringWithFormat:@"Found device at %@", ipAddress]
                 preview:nil];

        // Actually test if we can reach this IP
        [strongSelf testConnectionToIP:ipAddress];
      }
      failed:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        NSLog(@"🔥 Failed to get device IP, testing common IPs");
        [strongSelf testConnectionWithCommonIPs];
      }];
}

- (void)testConnectionToIP:(NSString *)ip {
  [self updateStatus:[NSString
                         stringWithFormat:@"Testing connection to %@...", ip]
             preview:nil];

  NSURL *testURL = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://%@/files/media.config", ip]];
  NSURLRequest *request =
      [NSURLRequest requestWithURL:testURL
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:5.0];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              NSLog(@"🔥 Successfully connected to %@", ip);
              [self updateStatus:[NSString
                                     stringWithFormat:@"Connected to %@", ip]
                         preview:nil];
              // Set deviceIP and verify connection before proceeding
              self->_deviceIP = ip;
              [self verifyWiFiConnectionAndProceed];
            } else {
              NSLog(@"🔥 Failed to connect to %@: %@", ip,
                    error.localizedDescription);
              [self testConnectionWithCommonIPs];
            }
          });
        }];
  [task resume];
}

- (void)testConnectionWithCommonIPs {
  [self updateStatus:@"🔍 Scanning for glasses endpoints..." preview:nil];

  // Prioritized IP list - try most likely ones first
  NSArray *priorityIPs =
      @[ @"192.168.31.1", @"3.192.168.31", @"192.168.43.1", @"192.168.4.1" ];
  NSArray *fallbackIPs = @[ @"192.168.1.1", @"192.168.0.1" ];

  __block NSString *workingIP = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  NSLog(@"🔥 Starting fast IP scan with priority IPs first");

  // Test priority IPs first with shorter timeout
  for (NSString *ip in priorityIPs) {
    NSURL *testURL = [NSURL
        URLWithString:[NSString
                          stringWithFormat:@"http://%@/files/media.config",
                                           ip]];
    NSURLRequest *request =
        [NSURLRequest requestWithURL:testURL
                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                     timeoutInterval:1.5];

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (!error && data &&
                ((NSHTTPURLResponse *)response).statusCode == 200) {
              workingIP = ip;
              NSLog(@"🔥 Found working priority IP: %@", ip);
            }
            dispatch_semaphore_signal(semaphore);
          }] resume];

    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
    if (workingIP)
      break;
  }

  // If no priority IPs worked, try fallbacks
  if (!workingIP) {
    NSLog(@"🔥 No priority IPs worked, trying fallbacks");
    for (NSString *ip in fallbackIPs) {
      NSURL *testURL = [NSURL
          URLWithString:[NSString
                            stringWithFormat:@"http://%@/files/media.config",
                                             ip]];
      NSURLRequest *request =
          [NSURLRequest requestWithURL:testURL
                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                       timeoutInterval:1.0];

      [[[NSURLSession sharedSession]
          dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
              if (!error && data &&
                  ((NSHTTPURLResponse *)response).statusCode == 200) {
                workingIP = ip;
                NSLog(@"🔥 Found working fallback IP: %@", ip);
              }
              dispatch_semaphore_signal(semaphore);
            }] resume];

      dispatch_semaphore_wait(
          semaphore,
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
      if (workingIP)
        break;
    }
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (workingIP) {
      self->_deviceIP = workingIP;
      [self updateStatus:[NSString stringWithFormat:@"✅ Found glasses at %@",
                                                    workingIP]
                 preview:nil];
      NSLog(@"🔥 Successfully connected to glasses at IP: %@", workingIP);
      // Verify WiFi connection before proceeding to endpoint discovery
      [self verifyWiFiConnectionAndProceed];
    } else {
      NSError *error =
          [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                              code:GlassesMediaDownloaderErrorCodeWifiIP
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Could not reach glasses. Please manually "
                                @"connect to the glasses WiFi hotspot."
                          }];
      [self finishWithError:error];
    }
  });
}

- (void)discoverAllEndpointsForIP:(NSString *)ip {
  NSLog(@"🔥 Starting fast endpoint discovery for IP: %@", ip);
  [self updateStatus:[NSString
                         stringWithFormat:@"🔍 Discovering endpoints on %@...",
                                          ip]
             preview:nil];

  // Prioritized list - test most likely endpoints first
  NSArray *priorityEndpoints = @[
    @"/files/media.config", @"/media.config", @"/files/manifest", @"/manifest"
  ];

  // Secondary endpoints to test if priority ones fail
  NSArray *secondaryEndpoints =
      @[ @"/api/media", @"/api/files", @"/config", @"/files", @"/" ];

  NSMutableArray *foundEndpoints = [NSMutableArray array];
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  NSLog(@"🔥 Testing priority endpoints first on IP %@", ip);

  // Test priority endpoints first with shorter timeout
  for (NSString *endpoint in priorityEndpoints) {
    NSString *urlString =
        [NSString stringWithFormat:@"http://%@%@", ip, endpoint];
    NSURL *testURL = [NSURL URLWithString:urlString];
    NSURLRequest *request =
        [NSURLRequest requestWithURL:testURL
                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                     timeoutInterval:1.5]; // Reduced from 3.0

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (!error) {
              NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
              NSLog(@"🔥 PRIORITY ENDPOINT: %@ - Status: %ld", urlString,
                    (long)httpResponse.statusCode);

              if (httpResponse.statusCode == 200 && data.length > 0) {
                [foundEndpoints addObject:@{
                  @"url" : urlString,
                  @"endpoint" : endpoint,
                  @"status" : @(httpResponse.statusCode),
                  @"contentLength" : @(data.length),
                  @"contentType" : httpResponse.MIMEType ?: @"unknown"
                }];
                NSLog(@"🔥 ✅ VALID PRIORITY ENDPOINT: %@", urlString);
              }
            }
            dispatch_semaphore_signal(semaphore);
          }] resume];

    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(2.0 * NSEC_PER_SEC))); // Reduced from 3.5

    // If we found the main endpoint, break early
    if (foundEndpoints.count > 0) {
      NSLog(@"🔥 Found priority endpoint, skipping secondary scan");
      break;
    }
  }

  // If no priority endpoints found, test secondary ones
  if (foundEndpoints.count == 0) {
    NSLog(@"🔥 No priority endpoints found, testing secondary ones");

    for (NSString *endpoint in secondaryEndpoints) {
      NSString *urlString =
          [NSString stringWithFormat:@"http://%@%@", ip, endpoint];
      NSURL *testURL = [NSURL URLWithString:urlString];
      NSURLRequest *request =
          [NSURLRequest requestWithURL:testURL
                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                       timeoutInterval:1.0];

      [[[NSURLSession sharedSession]
          dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
              if (!error) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200 && data.length > 0) {
                  [foundEndpoints addObject:@{
                    @"url" : urlString,
                    @"endpoint" : endpoint,
                    @"status" : @(httpResponse.statusCode),
                    @"contentLength" : @(data.length),
                    @"contentType" : httpResponse.MIMEType ?: @"unknown"
                  }];
                  NSLog(@"🔥 ✅ VALID SECONDARY ENDPOINT: %@", urlString);
                }
              }
              dispatch_semaphore_signal(semaphore);
            }] resume];

      dispatch_semaphore_wait(
          semaphore,
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));

      // If we found an endpoint, break early
      if (foundEndpoints.count > 0)
        break;
    }
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"🔥 Fast endpoint discovery complete. Found %lu valid endpoints.",
          (unsigned long)foundEndpoints.count);

    // Log all found endpoints
    for (NSDictionary *endpointInfo in foundEndpoints) {
      NSLog(@"🔥 📄 Found: %@ (%@ bytes, %@)", endpointInfo[@"url"],
            endpointInfo[@"contentLength"], endpointInfo[@"contentType"]);
    }

    if (foundEndpoints.count > 0) {
      [self
          updateStatus:[NSString
                           stringWithFormat:@"🔍 Found %lu endpoints!",
                                            (unsigned long)foundEndpoints.count]
               preview:nil];
      [self processDiscoveredEndpoints:foundEndpoints];
    } else {
      [self updateStatus:@"No media endpoints found" preview:nil];
      NSError *error =
          [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                              code:GlassesMediaDownloaderErrorCodeManifest
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"No media endpoints found on glasses device."
                          }];
      [self finishWithError:error];
    }
  });
}

- (void)processDiscoveredEndpoints:(NSArray *)foundEndpoints {
  NSLog(@"🔥 Processing %lu discovered endpoints",
        (unsigned long)foundEndpoints.count);

  // Priority order for endpoints
  NSArray *priorityEndpoints = @[
    @"/files/media.config", @"/media.config", @"/files/manifest", @"/manifest",
    @"/api/media"
  ];

  // Try priority endpoints first
  for (NSString *priorityEndpoint in priorityEndpoints) {
    for (NSDictionary *endpointInfo in foundEndpoints) {
      if ([endpointInfo[@"endpoint"] isEqualToString:priorityEndpoint]) {
        NSLog(@"🔥 🎯 Using priority endpoint: %@", endpointInfo[@"url"]);
        [self useDiscoveredEndpoint:endpointInfo];
        return;
      }
    }
  }

  // If no priority endpoints, use the first one found
  if (foundEndpoints.count > 0) {
    NSDictionary *firstEndpoint = foundEndpoints[0];
    NSLog(@"🔥 📋 Using first available endpoint: %@", firstEndpoint[@"url"]);
    [self useDiscoveredEndpoint:firstEndpoint];
  }
}

- (void)useDiscoveredEndpoint:(NSDictionary *)endpointInfo {
  NSString *urlString = endpointInfo[@"url"];
  NSNumber *contentLength = endpointInfo[@"contentLength"];
  NSString *contentType = endpointInfo[@"contentType"];

  NSLog(@"🔥 Using endpoint: %@ (Size: %@ bytes, Type: %@)", urlString,
        contentLength, contentType);

  // Check if this is a manifest/config file
  NSString *endpoint = endpointInfo[@"endpoint"];
  if ([endpoint containsString:@"media.config"] ||
      [endpoint containsString:@"manifest"] ||
      [endpoint containsString:@"config"]) {
    NSLog(@"🔥 Treating as manifest endpoint: %@", urlString);
    self.deviceIP = [self extractIPFromURL:urlString];
    [self
        updateStatus:[NSString stringWithFormat:@"📄 Loading manifest from %@",
                                                endpoint]
             preview:nil];
    [self downloadManifestFromCustomURL:urlString];
  } else {
    NSLog(@"🔥 Treating as direct media endpoint: %@", urlString);
    [self updateStatus:[NSString stringWithFormat:@"🎥 Direct media access: %@",
                                                  endpoint]
               preview:nil];
    [self downloadDirectMediaFromURL:urlString];
  }
}

- (NSString *)extractIPFromURL:(NSString *)urlString {
  NSURL *url = [NSURL URLWithString:urlString];
  return url.host;
}

- (void)downloadManifestFromCustomURL:(NSString *)manifestURLString {
  NSLog(@"🔥 Downloading manifest from custom URL: %@", manifestURLString);

  NSURL *manifestURL = [NSURL URLWithString:manifestURLString];
  self.lastManifestURL = manifestURL;
  if (!manifestURL) {
    NSError *error =
        [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                            code:GlassesMediaDownloaderErrorCodeManifest
                        userInfo:@{
                          NSLocalizedDescriptionKey : @"Invalid manifest URL."
                        }];
    [self finishWithError:error];
    return;
  }

  [self updateStatus:@"Fetching custom media manifest..." preview:nil];
  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session
        dataTaskWithURL:manifestURL
      completionHandler:^(NSData *_Nullable data,
                          NSURLResponse *_Nullable response,
                          NSError *_Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }

        if (error) {
          NSString *description = [NSString
              stringWithFormat:@"Failed to download manifest: %@",
                               error.localizedDescription ?: @"unknown error"];
          NSError *manifestError = [NSError
              errorWithDomain:GlassesMediaDownloaderErrorDomain
                         code:GlassesMediaDownloaderErrorCodeManifest
                     userInfo:@{NSLocalizedDescriptionKey : description}];
          [strongSelf finishWithError:manifestError];
          return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
          NSString *description =
              [NSString stringWithFormat:@"Manifest request returned HTTP %ld.",
                                         (long)httpResponse.statusCode];
          NSError *manifestError = [NSError
              errorWithDomain:GlassesMediaDownloaderErrorDomain
                         code:GlassesMediaDownloaderErrorCodeManifest
                     userInfo:@{NSLocalizedDescriptionKey : description}];
          [strongSelf finishWithError:manifestError];
          return;
        }

        NSLog(@"🔥 ✅ Manifest downloaded successfully! Size: %llu bytes",
              httpResponse.expectedContentLength);

        NSString *configString =
            [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!configString) {
          configString =
              [[NSString alloc] initWithData:data
                                    encoding:NSISOLatin1StringEncoding];
        }

        NSLog(@"🔥 📄 Manifest content: %@",
              configString.length > 200 ? [configString substringToIndex:200]
                                        : configString);

        if (configString.length == 0) {
          NSError *manifestError = [NSError
              errorWithDomain:GlassesMediaDownloaderErrorDomain
                         code:GlassesMediaDownloaderErrorCodeManifest
                     userInfo:@{
                       NSLocalizedDescriptionKey : @"Media manifest is empty."
                     }];
          [strongSelf finishWithError:manifestError];
          return;
        }

        NSArray<NSURL *> *fileURLs =
            [strongSelf fileURLsFromManifestString:configString
                                           baseURL:manifestURL];
        NSLog(@"🔥 📁 Found %lu media files in manifest",
              (unsigned long)fileURLs.count);

        [strongSelf prepareDownloadDirectoryWithManifest:fileURLs
                                                 baseURL:manifestURL];
      }];
  [task resume];
}

- (void)downloadDirectMediaFromURL:(NSString *)mediaURLString {
  NSLog(@"🔥 Downloading direct media from: %@", mediaURLString);

  NSURL *mediaURL = [NSURL URLWithString:mediaURLString];
  if (!mediaURL) {
    NSError *error = [NSError
        errorWithDomain:GlassesMediaDownloaderErrorDomain
                   code:GlassesMediaDownloaderErrorCodeDownload
               userInfo:@{NSLocalizedDescriptionKey : @"Invalid media URL."}];
    [self finishWithError:error];
    return;
  }

  NSString *filename = mediaURL.lastPathComponent.length > 0
                           ? mediaURL.lastPathComponent
                           : @"media_file";
  [self updateStatus:[NSString stringWithFormat:@"Downloading: %@", filename]
             preview:nil];

  // Create a single-file manifest for direct download
  NSArray<NSURL *> *singleFileArray = @[ mediaURL ];
  NSURL *baseURL = [mediaURL URLByDeletingLastPathComponent];

  [self prepareDownloadDirectoryWithManifest:singleFileArray baseURL:baseURL];
}

- (void)joinHotspotWithModernConfig {
  NSLog(
      @"joinHotspotWithModernConfig called with SSID: %@, password present: %@",
      self.ssid, self.password.length > 0 ? @"YES" : @"NO");
  [self updateStatus:@"Configuring WiFi connection..." preview:nil];

  if (@available(iOS 11.0, *)) {
    NEHotspotConfiguration *configuration = nil;

    // Modern iOS configuration
    if (self.password.length > 0) {
      configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid
                                                        passphrase:self.password
                                                             isWEP:NO];
    } else {
      configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid];
    }

    // Modern configuration options
    configuration.joinOnce = YES; // Join once for this session

    NSLog(@"🔥 Applying modern NEHotspotConfiguration for SSID: %@", self.ssid);
    __weak typeof(self) weakSelf = self;

    [[NEHotspotConfigurationManager sharedManager]
        applyConfiguration:configuration
         completionHandler:^(NSError *_Nullable error) {
           __strong typeof(weakSelf) strongSelf = weakSelf;
           if (!strongSelf) {
             return;
           }

           if (!error) {
             NSLog(@"🔥 Successfully applied hotspot configuration!");
             [strongSelf updateStatus:@"WiFi configured. Testing connection..."
                              preview:nil];

             // Wait a moment for connection to establish
             dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(3.0 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              [strongSelf testConnectionAfterHotspotJoin];
                            });
           } else if (error.code ==
                      NEHotspotConfigurationErrorAlreadyAssociated) {
             NSLog(@"🔥 Already associated with hotspot");
             [strongSelf
                 updateStatus:@"Already connected. Testing connection..."
                      preview:nil];
             dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(2.0 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              [strongSelf testConnectionAfterHotspotJoin];
                            });
           } else {
             NSLog(@"🔥 Failed to configure hotspot: %@",
                   error.localizedDescription);
             [strongSelf
                 updateStatus:[NSString
                                  stringWithFormat:@"WiFi config failed: %@",
                                                   error.localizedDescription]
                      preview:nil];

             // Fallback to manual connection prompt
             dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(2.0 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              [strongSelf promptForManualConnection];
                            });
           }
         }];
  } else {
    [self promptForManualConnection];
  }
}

- (void)testConnectionAfterHotspotJoin {
  NSLog(@"🔥 Testing connection after hotspot join");
  [self updateStatus:@"Testing network connection..." preview:nil];

  // Check if we're actually connected to the target WiFi
  if ([self isCurrentlyOnTargetWiFi]) {
    NSLog(@"🔥 Confirmed on target WiFi, proceeding with connection test");
    [self testConnectionWithQCSDKAndCommonIPs];
  } else {
    NSLog(@"🔥 Not on target WiFi, prompting for manual connection");
    [self promptForManualConnection];
  }
}

- (BOOL)isCurrentlyOnTargetWiFi {
  // Test connectivity to target network instead of checking SSID directly
  return [self testConnectivityToTargetNetwork];
}

- (BOOL)testConnectivityToTargetNetwork {
  // Test if we can reach the glasses device by trying common IPs
  NSArray *targetIPs =
      @[ @"192.168.43.1", @"192.168.4.1", @"192.168.1.1", @"192.168.0.1" ];

  __block BOOL canReachTarget = NO;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  for (NSString *ip in targetIPs) {
    NSURL *testURL = [NSURL
        URLWithString:[NSString
                          stringWithFormat:@"http://%@/files/media.config",
                                           ip]];
    NSURLRequest *request =
        [NSURLRequest requestWithURL:testURL
                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                     timeoutInterval:1.0];

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (!error && ((NSHTTPURLResponse *)response).statusCode == 200) {
              canReachTarget = YES;
            }
            dispatch_semaphore_signal(semaphore);
          }] resume];

    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
    if (canReachTarget)
      break;
  }

  return canReachTarget;
}

- (void)testConnectionWithQCSDKAndCommonIPs {
  // First try the QCSDK IP retrieval
  [QCSDKCmdCreator
      getDeviceWifiIPSuccess:^(NSString *_Nullable ipAddress) {
        if (ipAddress.length > 0) {
          NSLog(@"🔥 Got device IP: %@", ipAddress);
          [self testConnectionToIP:ipAddress];
        } else {
          NSLog(@"🔥 No IP from QCSDK, trying common IPs");
          [self testConnectionWithCommonIPs];
        }
      }
      failed:^{
        NSLog(@"🔥 QCSDK IP failed, trying common IPs");
        [self testConnectionWithCommonIPs];
      }];
}

- (void)promptForManualConnection {
  [self
      updateStatus:[NSString stringWithFormat:@"Please manually join WiFi: %@",
                                              self.ssid]
           preview:nil];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self testConnectionWithCommonIPs];
      });
}

- (void)joinHotspot {
  // Legacy method - redirect to modern config
  [self joinHotspotWithModernConfig];
}

- (void)downloadManifest {
  NSString *manifestString = [NSString
      stringWithFormat:@"http://%@/files/media.config", self->_deviceIP];
  NSURL *manifestURL = [NSURL URLWithString:manifestString];
  if (!manifestURL) {
    NSError *error =
        [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                            code:GlassesMediaDownloaderErrorCodeManifest
                        userInfo:@{
                          NSLocalizedDescriptionKey : @"Invalid manifest URL."
                        }];
    [self finishWithError:error];
    return;
  }

  [self updateStatus:@"Fetching media manifest..." preview:nil];
  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session
        dataTaskWithURL:manifestURL
      completionHandler:^(NSData *_Nullable data,
                          NSURLResponse *_Nullable response,
                          NSError *_Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        if (error) {
          NSString *description = [NSString
              stringWithFormat:@"Failed to download manifest: %@",
                               error.localizedDescription ?: @"unknown error"];
          NSError *manifestError = [NSError
              errorWithDomain:GlassesMediaDownloaderErrorDomain
                         code:GlassesMediaDownloaderErrorCodeManifest
                     userInfo:@{NSLocalizedDescriptionKey : description}];
          [strongSelf finishWithError:manifestError];
          return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
          NSString *description =
              [NSString stringWithFormat:@"Manifest request returned HTTP %ld.",
                                         (long)httpResponse.statusCode];
          NSError *manifestError = [NSError
              errorWithDomain:GlassesMediaDownloaderErrorDomain
                         code:GlassesMediaDownloaderErrorCodeManifest
                     userInfo:@{NSLocalizedDescriptionKey : description}];
          [strongSelf finishWithError:manifestError];
          return;
        }

        NSString *configString =
            [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!configString) {
          configString =
              [[NSString alloc] initWithData:data
                                    encoding:NSISOLatin1StringEncoding];
        }
        if (configString.length == 0) {
          NSError *manifestError = [NSError
              errorWithDomain:GlassesMediaDownloaderErrorDomain
                         code:GlassesMediaDownloaderErrorCodeManifest
                     userInfo:@{
                       NSLocalizedDescriptionKey : @"Media manifest is empty."
                     }];
          [strongSelf finishWithError:manifestError];
          return;
        }

        NSArray<NSURL *> *fileURLs =
            [strongSelf fileURLsFromManifestString:configString
                                           baseURL:manifestURL];
        [strongSelf prepareDownloadDirectoryWithManifest:fileURLs
                                                 baseURL:manifestURL];
      }];
  [task resume];
}

- (NSArray<NSURL *> *)fileURLsFromManifestString:(NSString *)manifest
                                         baseURL:(NSURL *)manifestURL {
  NSArray<NSString *> *lines = [manifest
      componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
  NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
  NSURL *baseURL = [manifestURL URLByDeletingLastPathComponent];
  for (NSString *line in lines) {
    NSString *trimmed = [line
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
      continue;
    }
    if ([trimmed hasPrefix:@"#"]) {
      continue;
    }
    NSURL *resolvedURL = nil;
    if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) {
      resolvedURL = [NSURL URLWithString:trimmed];
    } else {
      resolvedURL = [NSURL URLWithString:trimmed relativeToURL:baseURL];
    }
    if (resolvedURL) {
      [fileURLs addObject:resolvedURL.absoluteURL];
    }
  }
  return fileURLs.copy;
}

- (void)prepareDownloadDirectoryWithManifest:(NSArray<NSURL *> *)fileURLs
                                     baseURL:(NSURL *)manifestURL {
  (void)manifestURL;
  NSString *documentsDirectory = NSSearchPathForDirectoriesInDomains(
                                     NSDocumentDirectory, NSUserDomainMask, YES)
                                     .firstObject;
  if (documentsDirectory.length == 0) {
    NSError *error =
        [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                            code:GlassesMediaDownloaderErrorCodeFilesystem
                        userInfo:@{
                          NSLocalizedDescriptionKey :
                              @"Unable to locate the Documents directory."
                        }];
    [self finishWithError:error];
    return;
  }

  NSString *mediaDirectoryPath =
      [documentsDirectory stringByAppendingPathComponent:@"GlassesMedia"];
  NSURL *mediaDirectoryURL = [NSURL fileURLWithPath:mediaDirectoryPath
                                        isDirectory:YES];

  NSError *directoryError = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtURL:mediaDirectoryURL
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&directoryError]) {
    NSError *error = [NSError
        errorWithDomain:GlassesMediaDownloaderErrorDomain
                   code:GlassesMediaDownloaderErrorCodeFilesystem
               userInfo:@{
                 NSLocalizedDescriptionKey : directoryError.localizedDescription
                     ?: @"Unable to prepare download directory."
               }];
    [self finishWithError:error];
    return;
  }

  if (fileURLs.count == 0) {
    [self updateStatus:@"No media listed in manifest." preview:nil];
    [self finishWithError:nil];
    return;
  }

  [self downloadFiles:fileURLs
          toDirectory:mediaDirectoryURL
              atIndex:0
                retry:0
        latestPreview:nil];
}

- (void)downloadFiles:(NSArray<NSURL *> *)fileURLs
          toDirectory:(NSURL *)directoryURL
              atIndex:(NSUInteger)index
                retry:(NSInteger)retry
        latestPreview:(UIImage *_Nullable)latestPreview {
  if (self.didFinish) {
    return;
  }

  if (index >= fileURLs.count) {
    NSLog(@"🎉 [GlassesMediaDownloader] Successfully downloaded all %lu files!",
          (unsigned long)fileURLs.count);
    [self updateStatus:@"All media downloaded. Checking post-download manifest..."
               preview:latestPreview];

    // Re-fetch media.config to inspect what smart glasses report after download
    NSURL *checkURL = self.lastManifestURL ?: [NSURL URLWithString:@"http://192.168.31.1/files/media.config"];
    NSLog(@"🔥 🔍 [POST-DOWNLOAD CHECK] Re-fetching manifest from: %@", checkURL.absoluteString);
    NSMutableURLRequest *postCheckReq =
        [NSMutableURLRequest requestWithURL:checkURL
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:5.0];
    [postCheckReq setValue:@"close" forHTTPHeaderField:@"Connection"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *postCheckTask = [self.session
          dataTaskWithRequest:postCheckReq
            completionHandler:^(NSData *_Nullable data,
                                NSURLResponse *_Nullable response,
                                NSError *_Nullable error) {
              __strong typeof(weakSelf) strongSelf = weakSelf;
              if (!strongSelf) {
                return;
              }

              NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
              if (error) {
                NSLog(@"🔥 🔍 [POST-DOWNLOAD CHECK] Re-fetch error: %@", error.localizedDescription);
              } else {
                NSString *postContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!postContent) {
                  postContent = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                }
                NSLog(@"🔥 🔍 [POST-DOWNLOAD CHECK] Status: %ld, Size: %lu bytes",
                      (long)httpResp.statusCode, (unsigned long)data.length);
                NSLog(@"🔥 🔍 [POST-DOWNLOAD CHECK] Content after download:\n%@",
                      postContent.length > 0 ? postContent : @"(empty)");
              }

              dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf finishWithError:nil];
              });
            }];
    [postCheckTask resume];
    return;
  }

  NSURL *fileURL = fileURLs[index];
  NSString *filename =
      fileURL.lastPathComponent.length > 0
          ? fileURL.lastPathComponent
          : [NSString stringWithFormat:@"media_%lu", (unsigned long)index];
  NSURL *destinationURL = [directoryURL URLByAppendingPathComponent:filename];

  NSString *attemptStr = retry > 0
                             ? [NSString stringWithFormat:@" (Attempt %ld/3)",
                                                          (long)(retry + 1)]
                             : @"";
  NSLog(@"📥 [GlassesMediaDownloader] Downloading [%lu/%lu]%@: %@",
        (unsigned long)(index + 1), (unsigned long)fileURLs.count, attemptStr,
        filename);
  [self updateStatus:[NSString stringWithFormat:@"Downloading %lu/%lu: %@%@",
                                                (unsigned long)(index + 1),
                                                (unsigned long)fileURLs.count,
                                                filename, attemptStr]
             preview:latestPreview];

  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:fileURL
                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                          timeoutInterval:20.0];
  [request setValue:@"close" forHTTPHeaderField:@"Connection"];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session
        dataTaskWithRequest:request
          completionHandler:^(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.didFinish) {
              return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            BOOL hasNetworkError = (error != nil || httpResponse.statusCode < 200 ||
                                    httpResponse.statusCode >= 300 ||
                                    data.length == 0);

            if (hasNetworkError) {
              if (retry < 3) {
                NSLog(@"⚠️ [GlassesMediaDownloader] Download hiccup for %@ (error: "
                      @"%@, HTTP %ld). Retrying %ld/3 in 1.0s...",
                      filename, error.localizedDescription ?: @"none",
                      (long)httpResponse.statusCode, (long)(retry + 1));
                [strongSelf
                    updateStatus:[NSString
                                     stringWithFormat:@"Retrying %@ (%ld/3)...",
                                                      filename,
                                                      (long)(retry + 1)]
                         preview:latestPreview];
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(1.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                      [strongSelf downloadFiles:fileURLs
                                    toDirectory:directoryURL
                                        atIndex:index
                                          retry:retry + 1
                                  latestPreview:latestPreview];
                    });
                return;
              }

              NSString *description = [NSString
                  stringWithFormat:@"Failed to download %@ after 3 attempts: %@ "
                                   @"(HTTP %ld)",
                                   filename,
                                   error.localizedDescription ?: @"unknown error",
                                   (long)httpResponse.statusCode];
              NSLog(@"💥 [GlassesMediaDownloader] %@", description);
              NSError *downloadError = [NSError
                  errorWithDomain:GlassesMediaDownloaderErrorDomain
                             code:GlassesMediaDownloaderErrorCodeDownload
                         userInfo:@{NSLocalizedDescriptionKey : description}];
              [strongSelf finishWithError:downloadError];
              return;
            }

            [[NSFileManager defaultManager] removeItemAtURL:destinationURL
                                                      error:nil];
            NSError *writeError = nil;
            if (![data writeToURL:destinationURL
                          options:NSDataWritingAtomic
                            error:&writeError]) {
              NSString *description =
                  [NSString stringWithFormat:@"Failed to save %@: %@", filename,
                                             writeError.localizedDescription
                                                 ?: @"unknown error"];
              NSError *filesystemError = [NSError
                  errorWithDomain:GlassesMediaDownloaderErrorDomain
                             code:GlassesMediaDownloaderErrorCodeFilesystem
                         userInfo:@{NSLocalizedDescriptionKey : description}];
              [strongSelf finishWithError:filesystemError];
              return;
            }

            NSLog(@"✅ [GlassesMediaDownloader] Saved [%lu/%lu] (%lu bytes) -> %@",
                  (unsigned long)(index + 1), (unsigned long)fileURLs.count,
                  (unsigned long)data.length, destinationURL.path);
            UIImage *previewImage = [strongSelf previewImageForData:data];
            UIImage *nextPreview = previewImage ?: latestPreview;
            NSString *status =
                [NSString stringWithFormat:@"Saved %lu/%lu: %@",
                                           (unsigned long)(index + 1),
                                           (unsigned long)fileURLs.count, filename];
            [strongSelf updateStatus:status preview:nextPreview];

            // 350ms pacing delay between files to allow smart glasses hardware to flush internal buffers and close file descriptor
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(0.35 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                  [strongSelf downloadFiles:fileURLs
                                toDirectory:directoryURL
                                    atIndex:index + 1
                                      retry:0
                              latestPreview:nextPreview];
                });
          }];
  [task resume];
}

#pragma mark - Helpers

- (UIImage *_Nullable)previewImageForData:(NSData *)data {
  UIImage *image = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
  return image;
}

- (void)updateStatus:(NSString *)status preview:(UIImage *_Nullable)preview {
  if (!self.statusHandler) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    self.statusHandler(status, preview);
  });
}

- (void)stopTransferModeWithAttempt:(NSInteger)attempt
                         completion:(GlassesMediaDownloaderCompletionHandler _Nullable)completion {
  NSLog(@"🔥 [GlassesMediaDownloader] Stopping transfer mode via QCOperatorDeviceModeTransferStop (attempt %zd)",
        attempt);
  [self updateStatus:@"Stopping transfer mode..." preview:nil];

  [QCSDKCmdCreator setDeviceMode:QCOperatorDeviceModeTransferStop
      success:^{
        NSLog(@"🔥 ✅ [GlassesMediaDownloader] Successfully stopped transfer mode (attempt %zd)", attempt);
        [self updateStatus:@"Transfer mode stopped" preview:nil];
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
          });
        }
      }
      fail:^(NSInteger mode) {
        NSLog(@"🔥 ⚠️ [GlassesMediaDownloader] Failed to stop transfer mode, current mode: %zd (attempt %zd)",
              mode, attempt);
        if (attempt < 3) {
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [self stopTransferModeWithAttempt:attempt + 1 completion:completion];
              });
        } else {
          NSLog(@"🔥 ⚠️ [GlassesMediaDownloader] Max stop attempts reached. Proceeding with completion.");
          if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
              completion(nil);
            });
          }
        }
      }];
}

- (void)finishWithError:(NSError *_Nullable)error {
  if (self.didFinish) {
    return;
  }
  self.didFinish = YES;

  GlassesMediaDownloaderCompletionHandler completion = self.completionHandler;
  self.completionHandler = nil;

  if (!error) {
    NSLog(@"🔥 [GlassesMediaDownloader] All files downloaded. Stopping WiFi transfer mode...");
    [self updateStatus:@"Download complete! Stopping transfer mode..."
               preview:nil];
    [self stopTransferModeWithAttempt:1 completion:completion];
  } else {
    // If there was an error, try to stop transfer mode so glasses don't stay in Wi-Fi mode
    [QCSDKCmdCreator setDeviceMode:QCOperatorDeviceModeTransferStop success:^{} fail:^(NSInteger m){}];
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
      });
    }
  }
}

@end
