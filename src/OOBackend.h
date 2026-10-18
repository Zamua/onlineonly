#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the service needs from the Dropbox client. Paths are absolute and resolved.
@protocol OOBackend <NSObject>
// An OOStatus value; OOStatusNoReply when Dropbox does not answer.
- (int)statusOf:(NSString *)path;
// {verb: account instance} for the verbs Dropbox offers on this path, or nil on no reply.
- (nullable NSDictionary<NSString *, NSString *> *)verbsFor:(NSString *)path;
// YES once Dropbox has acknowledged the request; the change itself lands asynchronously.
- (BOOL)perform:(NSString *)verb instance:(NSString *)instance path:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
