#import "OODomain.h"

NSString *OOStatusName(int status) {
  switch (status) {
    case OOStatusNoReply: return @"no-reply";
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

NSString *OOTargetVerb(OOTarget target) {
  return target == OOTargetOnlineOnly ? @"dod_evict" : @"dod_recall";
}

NSString *OOTargetTitle(OOTarget target) {
  return target == OOTargetOnlineOnly ? @"Make online-only" : @"Make available offline";
}

OOStatus OOTargetStatus(OOTarget target) {
  return target == OOTargetOnlineOnly ? OOStatusOnlineOnly : OOStatusOffline;
}

static void ParseInto(NSString *menu, NSMutableDictionary *verbs) {
  for (NSString *item in [menu componentsSeparatedByString:@"|"]) {
    NSArray<NSString *> *parts = [item componentsSeparatedByString:@"~"];
    if (parts.count < 3) continue;
    if ([parts containsObject:@"submenu"]) {
      NSString *inner = parts.lastObject.stringByRemovingPercentEncoding;
      if (inner) ParseInto(inner, verbs);
      continue;
    }
    NSString *action = parts[2];
    NSRange dash = [action rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location == NSNotFound || dash.location == 0 || NSMaxRange(dash) == action.length) continue;
    verbs[[action substringToIndex:dash.location]] = [action substringFromIndex:NSMaxRange(dash)];
  }
}

NSDictionary<NSString *, NSString *> *OOParseMenu(NSString *menu) {
  NSMutableDictionary *verbs = [NSMutableDictionary new];
  ParseInto(menu, verbs);
  return verbs;
}
