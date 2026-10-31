#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the service needs from the Dropbox client. Paths are absolute and resolved.
@protocol OOBackend <NSObject>
// An OOStatus value; OOStatusNoReply when Dropbox gives no usable answer, with *error saying why.
- (int)statusOf:(NSString *)path error:(NSString *_Nullable *_Nullable)error;
// {verb: account instance} for the verbs Dropbox offers on this path, empty when it offers none;
// nil when Dropbox gives no usable answer, with *error saying why.
- (nullable NSDictionary<NSString *, NSString *> *)verbsFor:(NSString *)path
                                                       error:(NSString *_Nullable *_Nullable)error;
// YES once Dropbox has acknowledged the request; the change itself lands asynchronously.
- (BOOL)perform:(NSString *)verb instance:(NSString *)instance path:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
