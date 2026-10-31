#import "OODomain.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OORequestResult) {
  OORequestSent,        // Dropbox acknowledged; the change itself lands asynchronously
  OORequestNotOffered,  // Dropbox's menu for the path does not offer the action
  OORequestUnanswered,  // no usable reply from Dropbox; *error says why
};

// What the service needs from the Dropbox client. Paths are absolute and resolved.
@protocol OOBackend <NSObject>
// NO when Dropbox gives no usable answer, with *error saying why.
- (BOOL)status:(OOStatus *)status of:(NSString *)path error:(NSString *_Nullable *_Nullable)error;
// Moves the path toward target the way its Finder menu item would, only if Dropbox offers it.
- (OORequestResult)request:(OOTarget)target for:(NSString *)path error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
