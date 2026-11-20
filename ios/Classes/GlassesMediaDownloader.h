#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GlassesMediaDownloaderStatusHandler)(NSString *status, UIImage * _Nullable previewImage);
typedef void (^GlassesMediaDownloaderFileDownloadedHandler)(NSString *filePath, NSUInteger index, NSUInteger totalCount);
typedef void (^GlassesMediaDownloaderCompletionHandler)(NSArray<NSString *> * _Nullable downloadedFilePaths, NSError * _Nullable error);

@interface GlassesMediaDownloader : NSObject

- (instancetype)initWithStatusHandler:(nullable GlassesMediaDownloaderStatusHandler)statusHandler
               fileDownloadedHandler:(nullable GlassesMediaDownloaderFileDownloadedHandler)fileDownloadedHandler NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)startDownloadWithCompletion:(GlassesMediaDownloaderCompletionHandler)completion;

+ (NSString * _Nullable)getWiFiAddress;

@end

NS_ASSUME_NONNULL_END
