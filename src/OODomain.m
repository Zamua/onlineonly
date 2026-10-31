#import "OODomain.h"

NSString *OOStatusName(OOStatus status) {
  switch (status) {
    case OOStatusNone: return @"none";
    case OOStatusOffline: return @"offline";
    case OOStatusSyncing: return @"syncing";
    case OOStatusError: return @"error";
    case OOStatusIgnored: return @"ignored";
    case OOStatusOnlineOnly: return @"online-only";
    case OOStatusMixed: return @"mixed";
    case OOStatusLocal: return @"local";
    case OOStatusLocked: return @"locked";
    default: return [NSString stringWithFormat:@"unknown(%d)", status];
  }
}

NSString *OOTargetTitle(OOTarget target) {
  return target == OOTargetOnlineOnly ? @"Make online-only" : @"Make available offline";
}

OOStatus OOTargetStatus(OOTarget target) {
  return target == OOTargetOnlineOnly ? OOStatusOnlineOnly : OOStatusOffline;
}
