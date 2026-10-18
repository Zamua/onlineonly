#import "OOBackend.h"

NS_ASSUME_NONNULL_BEGIN

// OOBackend over the Mach port the Dropbox desktop client serves to its Finder extension.
@interface OODropbox : NSObject <OOBackend>
// nil when the Dropbox client is not running for this user.
+ (nullable instancetype)connect;
- (instancetype)init NS_UNAVAILABLE;
// Sync roots Dropbox watches (normally just the Dropbox folder).
- (NSArray<NSString *> *)roots;
@end

NS_ASSUME_NONNULL_END
