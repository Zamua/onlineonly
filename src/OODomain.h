#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Status codes the Dropbox client reports for a path (the Finder badge it would show). Other
// codes can arrive from a newer client; OOStatusName names them unknown(N).
typedef NS_ENUM(int, OOStatus) {
  OOStatusNone = 0,
  OOStatusOffline = 1,
  OOStatusSyncing = 2,
  OOStatusError = 3,
  OOStatusIgnored = 4,
  OOStatusOnlineOnly = 5,
  OOStatusMixed = 6,
  OOStatusLocal = 8,
  OOStatusLocked = 99,
};

typedef NS_ENUM(NSInteger, OOTarget) {
  OOTargetOnlineOnly,
  OOTargetOffline,
};

NSString *OOStatusName(OOStatus status);

// The Finder menu title for the target action.
NSString *OOTargetTitle(OOTarget target);

// Status Dropbox reports once the target state is reached.
OOStatus OOTargetStatus(OOTarget target);

NS_ASSUME_NONNULL_END
