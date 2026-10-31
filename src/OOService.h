#import "OOBackend.h"
#import "OOResult.h"

NS_ASSUME_NONNULL_BEGIN

// Expands ~ and resolves symlinks and relative components; nil with *error set if the path
// does not exist.
NSString *_Nullable OOResolvePath(NSString *path, NSString *_Nullable *_Nullable error);

@interface OOService : NSObject

- (instancetype)initWithBackend:(id<OOBackend>)backend;
- (instancetype)init NS_UNAVAILABLE;

// How often waiting re-reads status.
@property NSTimeInterval pollInterval;
// How long a settled path may sit unchanged after a request before it is re-sent.
@property NSTimeInterval resendInterval;
// Without wait, how long a request is held for a path that is still syncing.
@property NSTimeInterval settleTimeout;

- (OOStatusReport *)statusOf:(NSString *)path;

// As statusOf:, and a folder also lists up to `limit` of its children.
- (OOStatusReport *)statusOf:(NSString *)path childLimit:(NSUInteger)limit;

// Each visible entry in a folder with its status, stopping after `limit`.
- (OOListing *)childrenOf:(NSString *)dir limit:(NSUInteger)limit;

// Moves each path to the target state. With wait, blocks until every path reports the target
// status or `timeout` elapses; without it, returns once each request is sent. Results are in
// input order.
- (NSArray<OOApplyResult *> *)apply:(OOTarget)target
                              paths:(NSArray<NSString *> *)paths
                               wait:(BOOL)wait
                            timeout:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
