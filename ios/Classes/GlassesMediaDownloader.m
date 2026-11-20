#import "GlassesMediaDownloader.h"

#import <QCSDK/QCSDKCmdCreator.h>
#import <NetworkExtension/NetworkExtension.h>
#import <ifaddrs.h>
#import <arpa/inet.h>

static NSString * const GlassesMediaDownloaderErrorDomain = @"GlassesMediaDownloaderErrorDomain";

typedef NS_ENUM(NSInteger, GlassesMediaDownloaderErrorCode) {
    GlassesMediaDownloaderErrorCodeWifiCredentials = 1,
    GlassesMediaDownloaderErrorCodeWifiIP,
    GlassesMediaDownloaderErrorCodeManifest,
    GlassesMediaDownloaderErrorCodeDownload,
    GlassesMediaDownloaderErrorCodeFilesystem,
    GlassesMediaDownloaderErrorCodeUserCancelled = 7
};

@interface GlassesMediaDownloader ()
@property (nonatomic, copy, nullable) GlassesMediaDownloaderStatusHandler statusHandler;
@property (nonatomic, copy, nullable) GlassesMediaDownloaderFileDownloadedHandler fileDownloadedHandler;
@property (nonatomic, copy, nullable) GlassesMediaDownloaderCompletionHandler completionHandler;
@property (nonatomic, copy) NSString *ssid;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *deviceIP;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) BOOL didFinish;
@property (nonatomic, assign) BOOL isRequestingWifiCredentials;
@property (nonatomic, strong) NSMutableArray<NSString *> *downloadedPaths;
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
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
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

- (instancetype)initWithStatusHandler:(nullable GlassesMediaDownloaderStatusHandler)statusHandler
               fileDownloadedHandler:(nullable GlassesMediaDownloaderFileDownloadedHandler)fileDownloadedHandler {
    self = [super init];
    if (self) {
        _statusHandler = [statusHandler copy];
        _fileDownloadedHandler = [fileDownloadedHandler copy];
        _downloadedPaths = [NSMutableArray array];
        _deviceIP = @"192.168.31.1";

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.allowsCellularAccess = NO; // Force Wi-Fi en0 interface only (no cellular interference)
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 60.0;
        config.waitsForConnectivity = YES;
        _session = [NSURLSession sessionWithConfiguration:config];
        _isRequestingWifiCredentials = NO;
        _didFinish = NO;
    }
    return self;
}

- (void)startDownloadWithCompletion:(GlassesMediaDownloaderCompletionHandler)completion {
    self.completionHandler = [completion copy];
    self.didFinish = NO;
    [self.downloadedPaths removeAllObjects];

    [self updateStatus:@"Requesting glasses Wi-Fi credentials via Bluetooth..." preview:nil];
    [self requestWifiCredentials];
}

#pragma mark - Connection Flow

- (void)requestWifiCredentials {
    if (self.isRequestingWifiCredentials) {
        NSLog(@"👓 [GlassesMediaDownloader] WiFi credentials already requested, skipping duplicate call");
        return;
    }

    self.isRequestingWifiCredentials = YES;
    __weak typeof(self) weakSelf = self;
    NSLog(@"👓 [GlassesMediaDownloader] Enabling WiFi transfer mode on smart glasses...");

    [QCSDKCmdCreator openWifiWithMode:QCOperatorDeviceModeTransfer success:^(NSString *ssid, NSString *password) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.didFinish) { return; }

        strongSelf.isRequestingWifiCredentials = NO;
        strongSelf.ssid = ssid ?: @"";
        strongSelf.password = password ?: @"";
        strongSelf.deviceIP = @"192.168.31.1";

        NSLog(@"👓 [GlassesMediaDownloader] SUCCESS: Glasses hotspot ready -> SSID: '%@', PWD: '%@'", ssid, password);
        [strongSelf updateStatus:[NSString stringWithFormat:@"Hotspot ready: %@", ssid ?: @"<unknown>"] preview:nil];

        [strongSelf applyHotspotConfiguration];

    } fail:^(NSInteger code) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.didFinish) { return; }

        strongSelf.isRequestingWifiCredentials = NO;
        NSLog(@"💥 [GlassesMediaDownloader] FAILED to open WiFi transfer mode on glasses (code: %ld)", (long)code);

        NSError *error = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                             code:GlassesMediaDownloaderErrorCodeWifiCredentials
                                         userInfo:@{NSLocalizedDescriptionKey: @"Smart glasses could not enable Wi-Fi transfer mode."}];
        [strongSelf finishWithError:error];
    }];
}

- (void)applyHotspotConfiguration {
    if (@available(iOS 11.0, *)) {
        NSLog(@"👓 [GlassesMediaDownloader] Applying NEHotspotConfiguration for SSID: '%@'", self.ssid);

        NEHotspotConfiguration *configuration = nil;
        if (self.password.length > 0) {
            configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid
                                                               passphrase:self.password
                                                                   isWEP:NO];
        } else {
            configuration = [[NEHotspotConfiguration alloc] initWithSSID:self.ssid];
        }

        configuration.joinOnce = NO; // Keep Wi-Fi route active without dropping!
        if (@available(iOS 13.0, *)) {
            configuration.lifeTimeInDays = @1;
        }

        __weak typeof(self) weakSelf = self;
        [[NEHotspotConfigurationManager sharedManager] applyConfiguration:configuration
                                                     completionHandler:^(NSError * _Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.didFinish) { return; }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    if (error.code == 7) { // NEHotspotConfigurationErrorUserDenied
                        NSLog(@"⚠️ [GlassesMediaDownloader] User cancelled Wi-Fi join prompt");
                        NSError *userDeniedErr = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                                                     code:GlassesMediaDownloaderErrorCodeUserCancelled
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"[7] Wi-Fi connection cancelled by user"}];
                        [strongSelf finishWithError:userDeniedErr];
                        return;
                    }
                    NSLog(@"👓 [GlassesMediaDownloader] Hotspot config notice: %@ (proceeding to poll)", error.localizedDescription);
                } else {
                    NSLog(@"✅ [GlassesMediaDownloader] Hotspot config applied successfully");
                }

                [strongSelf updateStatus:@"Connecting to smart glasses Wi-Fi..." preview:nil];
                // Start polling http://192.168.31.1/files/media.config
                [strongSelf pollConnectionToGlassesWithAttempt:1 maxAttempts:30];
            });
        }];
    } else {
        [self pollConnectionToGlassesWithAttempt:1 maxAttempts:30];
    }
}

- (void)pollConnectionToGlassesWithAttempt:(NSInteger)attempt maxAttempts:(NSInteger)maxAttempts {
    if (self.didFinish) { return; }

    NSString *localIP = [GlassesMediaDownloader getWiFiAddress];
    NSLog(@"🔍 [GlassesMediaDownloader] [WiFi Poll %ld/%ld] Local en0 IP: %@", (long)attempt, (long)maxAttempts, localIP ?: @"(none)");

    NSURL *testURL = [NSURL URLWithString:@"http://192.168.31.1/files/media.config"];
    NSURLRequest *request = [NSURLRequest requestWithURL:testURL
                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                        timeoutInterval:2.0];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.didFinish) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && data && ((NSHTTPURLResponse *)response).statusCode == 200) {
                NSLog(@"🎉 [GlassesMediaDownloader] Connected to glasses! Received media.config (%lu bytes)", (unsigned long)data.length);
                [strongSelf parseManifestAndDownload:data baseURL:testURL];
                return;
            }

            if (attempt >= maxAttempts) {
                NSLog(@"❌ [GlassesMediaDownloader] TIMEOUT: Could not reach glasses Wi-Fi after %ld attempts", (long)maxAttempts);
                NSError *timeoutError = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                                            code:GlassesMediaDownloaderErrorCodeWifiIP
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Could not reach glasses Wi-Fi hotspot. Please tap 'Get' again and confirm 'Join'."}];
                [strongSelf finishWithError:timeoutError];
                return;
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [strongSelf pollConnectionToGlassesWithAttempt:attempt + 1 maxAttempts:maxAttempts];
            });
        });
    }];
    [task resume];
}

#pragma mark - Media Download

- (void)parseManifestAndDownload:(NSData *)manifestData baseURL:(NSURL *)baseURL {
    NSArray<NSURL *> *fileURLs = [self fileURLsFromManifestData:manifestData baseURL:baseURL];
    NSLog(@"📁 [GlassesMediaDownloader] Parsed %lu media file(s) from media.config", (unsigned long)fileURLs.count);

    if (fileURLs.count == 0) {
        NSLog(@"ℹ️ [GlassesMediaDownloader] media.config contains 0 files. Download finished.");
        [self updateStatus:@"No new media found on glasses." preview:nil];
        [self finishWithError:nil];
        return;
    }

    NSString *documentsDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documentsDirectory.length == 0) {
        NSError *error = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                             code:GlassesMediaDownloaderErrorCodeFilesystem
                                         userInfo:@{NSLocalizedDescriptionKey: @"Unable to locate Documents directory"}];
        [self finishWithError:error];
        return;
    }

    NSString *mediaDirectoryPath = [documentsDirectory stringByAppendingPathComponent:@"GlassesMedia"];
    NSURL *mediaDirectoryURL = [NSURL fileURLWithPath:mediaDirectoryPath isDirectory:YES];

    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:mediaDirectoryURL withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        NSError *error = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                             code:GlassesMediaDownloaderErrorCodeFilesystem
                                         userInfo:@{NSLocalizedDescriptionKey: dirError.localizedDescription ?: @"Could not create GlassesMedia directory"}];
        [self finishWithError:error];
        return;
    }

    [self updateStatus:[NSString stringWithFormat:@"Downloading %lu files...", (unsigned long)fileURLs.count] preview:nil];
    [self downloadFiles:fileURLs toDirectory:mediaDirectoryURL atIndex:0];
}

- (NSArray<NSURL *> *)fileURLsFromManifestData:(NSData *)data baseURL:(NSURL *)manifestURL {
    NSString *configString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!configString) {
        configString = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (configString.length == 0) {
        return @[];
    }

    NSArray<NSString *> *lines = [configString componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
    NSURL *parentBaseURL = [manifestURL URLByDeletingLastPathComponent];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }

        NSURL *resolvedURL = nil;
        if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) {
            resolvedURL = [NSURL URLWithString:trimmed];
        } else {
            resolvedURL = [NSURL URLWithString:trimmed relativeToURL:parentBaseURL];
        }

        if (resolvedURL) {
            [fileURLs addObject:resolvedURL.absoluteURL];
        }
    }
    return fileURLs.copy;
}

- (void)downloadFiles:(NSArray<NSURL *> *)fileURLs toDirectory:(NSURL *)directoryURL atIndex:(NSUInteger)index {
    if (self.didFinish) { return; }

    if (index >= fileURLs.count) {
        NSLog(@"🎉 [GlassesMediaDownloader] Successfully downloaded all %lu file(s) to %@", (unsigned long)fileURLs.count, directoryURL.path);
        [self updateStatus:@"All media files downloaded successfully!" preview:nil];
        [self finishWithError:nil];
        return;
    }

    NSURL *fileURL = fileURLs[index];
    NSString *filename = fileURL.lastPathComponent.length > 0 ? fileURL.lastPathComponent : [NSString stringWithFormat:@"media_%lu", (unsigned long)index];
    NSURL *destinationURL = [directoryURL URLByAppendingPathComponent:filename];

    NSLog(@"📥 [GlassesMediaDownloader] Downloading [%lu/%lu]: %@", (unsigned long)(index + 1), (unsigned long)fileURLs.count, filename);
    [self updateStatus:[NSString stringWithFormat:@"Downloading [%lu/%lu]: %@", (unsigned long)(index + 1), (unsigned long)fileURLs.count, filename] preview:nil];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:fileURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.didFinish) { return; }

        if (error) {
            NSLog(@"💥 [GlassesMediaDownloader] Download error for %@: %@", filename, error.localizedDescription);
            NSError *dlErr = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                                 code:GlassesMediaDownloaderErrorCodeDownload
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download %@: %@", filename, error.localizedDescription]}];
            [strongSelf finishWithError:dlErr];
            return;
        }

        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode < 200 || httpResp.statusCode >= 300) {
            NSLog(@"💥 [GlassesMediaDownloader] HTTP %ld error for %@", (long)httpResp.statusCode, filename);
            NSError *dlErr = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                                 code:GlassesMediaDownloaderErrorCodeDownload
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download %@: HTTP %ld", filename, (long)httpResp.statusCode]}];
            [strongSelf finishWithError:dlErr];
            return;
        }

        if (data.length == 0) {
            NSLog(@"💥 [GlassesMediaDownloader] Downloaded 0 bytes for %@", filename);
            NSError *dlErr = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                                 code:GlassesMediaDownloaderErrorCodeDownload
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Downloaded file %@ is empty", filename]}];
            [strongSelf finishWithError:dlErr];
            return;
        }

        [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
        NSError *writeErr = nil;
        if (![data writeToURL:destinationURL options:NSDataWritingAtomic error:&writeErr]) {
            NSLog(@"💥 [GlassesMediaDownloader] Write error for %@: %@", filename, writeErr.localizedDescription);
            NSError *fsErr = [NSError errorWithDomain:GlassesMediaDownloaderErrorDomain
                                                 code:GlassesMediaDownloaderErrorCodeFilesystem
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to save %@ to disk: %@", filename, writeErr.localizedDescription]}];
            [strongSelf finishWithError:fsErr];
            return;
        }

        NSLog(@"✅ [GlassesMediaDownloader] Saved [%lu/%lu] (%lu bytes) -> %@", (unsigned long)(index + 1), (unsigned long)fileURLs.count, (unsigned long)data.length, destinationURL.path);
        [strongSelf.downloadedPaths addObject:destinationURL.path];

        if (strongSelf.fileDownloadedHandler) {
            strongSelf.fileDownloadedHandler(destinationURL.path, index, fileURLs.count);
        }

        [strongSelf downloadFiles:fileURLs toDirectory:directoryURL atIndex:index + 1];
    }];
    [task resume];
}

#pragma mark - Cleanup & Completion

- (void)updateStatus:(NSString *)status preview:(UIImage * _Nullable)preview {
    if (!self.statusHandler) { return; }
    GlassesMediaDownloaderStatusHandler handler = self.statusHandler;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(status, preview);
    });
}

- (void)finishWithError:(NSError * _Nullable)error {
    if (self.didFinish) { return; }
    self.didFinish = YES;

    if (!error) {
        NSLog(@"👓 [GlassesMediaDownloader] Download completed successfully. Returning glasses to Photo mode in 1.5s...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [QCSDKCmdCreator setDeviceMode:QCOperatorDeviceModePhoto success:^{
                NSLog(@"✅ [GlassesMediaDownloader] Smart glasses successfully returned to Photo mode");
            } fail:^(NSInteger mode) {
                NSLog(@"⚠️ [GlassesMediaDownloader] Notice: could not switch mode (mode: %ld)", (long)mode);
            }];
        });
    }

    GlassesMediaDownloaderCompletionHandler completion = self.completionHandler;
    NSArray<NSString *> *paths = [self.downloadedPaths copy];
    self.completionHandler = nil;

    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(paths, error);
        });
    }
}

@end
