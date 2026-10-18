#import "OOBackend.h"
#import "OODomain.h"

NS_ASSUME_NONNULL_BEGIN

// Per-path outcome of an apply call, in the `result` field.
extern NSString *const OOResultRequested;  // Dropbox accepted the request; not waited on
extern NSString *const OOResultDone;       // waited, and the path reached the target state
extern NSString *const OOResultPending;    // waited until the timeout without reaching it
extern NSString *const OOResultAlready;    // already in the target state
extern NSString *const OOResultFailed;     // see `error`

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

// {path, status} or {path, error}.
- (NSDictionary *)statusOf:(NSString *)path;

// Status of each visible entry in a folder: {path, name, directory, status}.
// Stops after `limit` entries and sets *truncated.
- (nullable NSArray<NSDictionary *> *)childrenOf:(NSString *)dir
                                           limit:(NSUInteger)limit
                                       truncated:(nullable BOOL *)truncated
                                           error:(NSString *_Nullable *_Nullable)error;

// Moves each path to the target state. With wait, blocks until every path reports the target
// status or `timeout` elapses; without it, returns once each request is sent. Results are
// {path, result, status, error?}, in input order.
- (NSArray<NSDictionary *> *)apply:(OOTarget)target
                             paths:(NSArray<NSString *> *)paths
                              wait:(BOOL)wait
                           timeout:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
