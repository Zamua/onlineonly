#import "OOBackend.h"
#import "OOResult.h"

NS_ASSUME_NONNULL_BEGIN

// Where one path stands in an apply call.
typedef NS_ENUM(NSInteger, OOJobPhase) {
  OOJobUnsent,  // not requested yet; held while Dropbox is still syncing the path
  OOJobSent,    // requested; waiting for the target status, re-sent if it does not move
  OOJobFinal,   // outcome decided
};

typedef NS_ENUM(NSInteger, OOJobEventKind) {
  OOJobPolled,    // a status read: status, or error when Dropbox did not answer
  OOJobAnswered,  // Dropbox's answer to the request a poll asked for
  OOJobTimedOut,  // the apply call's deadline passed
};

@interface OOJobEvent : NSObject
+ (instancetype)polledStatus:(OOStatus)status at:(NSDate *)now;
+ (instancetype)polledError:(NSString *)error;
+ (instancetype)answered:(OORequestResult)request error:(nullable NSString *)error at:(NSDate *)now;
+ (instancetype)timedOut;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) OOJobEventKind kind;
@property(readonly) OOStatus status;
@property(readonly) OORequestResult request;
@property(readonly, nullable) NSString *error;
@property(readonly, nullable) NSDate *at;
@end

typedef struct {
  OOTarget target;
  // Without wait, a request Dropbox acknowledges is final.
  BOOL wait;
  // How long a settled path may sit unchanged after a request before it is re-sent.
  NSTimeInterval resendInterval;
} OOApplyPolicy;

// One path's apply lifecycle. Immutable: -next: is the only transition, and every phase and
// event pair is decided in it.
@interface OOJob : NSObject
+ (instancetype)unsent:(NSString *)path;
// Final before Dropbox was asked anything (the path does not resolve).
+ (instancetype)path:(NSString *)path failure:(NSString *)error;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString *path;
@property(readonly) OOJobPhase phase;
// Set exactly when phase is Final.
@property(readonly, nullable) OOApplyResult *result;
// The successor after `event`. Sets *request when the caller must now send the request and
// report Dropbox's answer as the next event.
- (OOJob *)next:(OOJobEvent *)event policy:(OOApplyPolicy)policy request:(nullable BOOL *)request;
@end

NS_ASSUME_NONNULL_END
