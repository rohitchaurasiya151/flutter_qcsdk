#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GlassesMediaDownloaderStatusHandler)(NSString *status, UIImage * _Nullable previewImage);
typedef void (^GlassesMediaDownloaderCompletionHandler)(NSError * _Nullable error);
typedef void (^GlassesMediaDownloaderProgressHandler)(NSInteger completedFiles, NSInteger totalFiles, CGFloat progress);
typedef void (^GlassesMediaDownloaderFileHandler)(NSString *filePath, NSInteger index, NSInteger count);

@interface GlassesMediaDownloader : NSObject

@property (nonatomic, copy, nullable) GlassesMediaDownloaderProgressHandler progressHandler;
@property (nonatomic, copy, nullable) GlassesMediaDownloaderFileHandler fileDownloadedHandler;

- (instancetype)initWithStatusHandler:(GlassesMediaDownloaderStatusHandler)statusHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)startDownloadWithCompletion:(GlassesMediaDownloaderCompletionHandler)completion;

@end

NS_ASSUME_NONNULL_END
