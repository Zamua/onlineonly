#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Status codes the Dropbox client reports for a path (the Finder badge it would show).
typedef NS_ENUM(int, OOStatus) {
  OOStatusNoReply = -1,
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

NSString *OOStatusName(int status);

// Context-menu verb that moves a path to the target state.
NSString *OOTargetVerb(OOTarget target);

// The Finder menu title for the target action.
NSString *OOTargetTitle(OOTarget target);

// Status Dropbox reports once the target state is reached.
OOStatus OOTargetStatus(OOTarget target);

// Parses Dropbox's encoded context menu ("Title~Tooltip~verb-instance|...", submenus
// percent-encoded inline) into {verb: account instance}.
NSDictionary<NSString *, NSString *> *OOParseMenu(NSString *menu);

NS_ASSUME_NONNULL_END
