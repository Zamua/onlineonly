#import "OOBackend.h"

NS_ASSUME_NONNULL_BEGIN

// Decode Dropbox's reply payloads. A missing reply (nil), an undecodable one and one without the
// expected key each set *error, so none of them passes as a real status or an empty verb set.
int OOStatusFromReply(NSData *_Nullable reply, NSString *_Nullable *_Nullable error);
NSDictionary<NSString *, NSString *> *_Nullable OOVerbsFromReply(NSData *_Nullable reply,
                                                                 NSString *_Nullable *_Nullable error);

// OOBackend over the Mach port the Dropbox desktop client serves to its Finder extension.
@interface OODropbox : NSObject <OOBackend>
// nil when the Dropbox client is not running for this user.
+ (nullable instancetype)connect;
- (instancetype)init NS_UNAVAILABLE;
// Sync roots Dropbox watches (normally just the Dropbox folder).
- (NSArray<NSString *> *)roots;
@end

NS_ASSUME_NONNULL_END
