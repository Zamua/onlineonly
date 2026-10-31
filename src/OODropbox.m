// Wire format: an NSPortMessage whose msgid is the request type and whose components are
// [int64 request id, NSKeyedArchiver payload]. Dropbox replies on the message's receive port
// with the same id; acknowledgements carry an empty payload.
#import "OODropbox.h"
#include <unistd.h>

// NSMachBootstrapServer and NSPortMessage are deprecated but remain the only Foundation API for
// named Mach ports, and the Finder extension uses them on the other end.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

enum {
  kHello = 0x00,
  kWatchSet = 0x64,
  kStatus = 0x65,
  kContextMenu = 0x66,
  kAction = 0x68,
};

static const NSTimeInterval kReplyTimeout = 10;

// Every status and context-menu reply carries its key, even for paths outside Dropbox, so a
// reply without it is malformed rather than an answer.
static NSKeyedUnarchiver *OpenReply(NSData *reply, NSString *key, NSString **error) {
  if (!reply.length) {
    if (error) *error = @"no reply from Dropbox";
    return nil;
  }
  NSError *e;
  NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:reply error:&e];
  if (!u) {
    if (error) *error = [NSString stringWithFormat:@"unreadable reply from Dropbox: %@", e.localizedDescription];
    return nil;
  }
  u.requiresSecureCoding = YES;
  if (![u containsValueForKey:key]) {
    if (error) *error = [NSString stringWithFormat:@"reply from Dropbox has no %@", key];
    return nil;
  }
  return u;
}

NSString *OOTargetVerb(OOTarget target) {
  return target == OOTargetOnlineOnly ? @"dod_evict" : @"dod_recall";
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

BOOL OOStatusFromReply(NSData *reply, OOStatus *status, NSString **error) {
  NSKeyedUnarchiver *u = OpenReply(reply, @"status", error);
  if (u) *status = (OOStatus)[u decodeIntForKey:@"status"];
  return u != nil;
}

NSDictionary<NSString *, NSString *> *OOVerbsFromReply(NSData *reply, NSString **error) {
  NSKeyedUnarchiver *u = OpenReply(reply, @"menu", error);
  if (!u) return nil;
  NSString *menu = [u decodeObjectOfClass:[NSString class] forKey:@"menu"];
  if (!menu) {
    if (error) *error = [NSString stringWithFormat:@"unreadable reply from Dropbox: %@", u.error.localizedDescription ?: @"menu is not a string"];
    return nil;
  }
  return OOParseMenu(menu);
}

@interface OODropbox () <NSMachPortDelegate>
- (instancetype)initWithRemote:(NSPort *)remote;
@end

@implementation OODropbox {
  NSPort *_remote;
  NSMachPort *_local;
  int64_t _nextId;
  int64_t _waitingId;
  NSData *_reply;
}

+ (instancetype)connect {
  NSString *name = [NSString stringWithFormat:@"G7HH3F8CAK.com.getdropbox.dropbox.sync.%u.finder_server", getuid()];
  NSPort *remote = [[NSMachBootstrapServer sharedInstance] portForName:name];
  if (!remote) return nil;
  OODropbox *d = [[self alloc] initWithRemote:remote];
  NSString *ver = [[NSBundle bundleWithPath:@"/Applications/Dropbox.app"] objectForInfoDictionaryKey:@"CFBundleVersion"];
  if (![d send:kHello payload:@{@"version": ver ?: @""}]) return nil;
  return d;
}

- (instancetype)initWithRemote:(NSPort *)remote {
  if ((self = [super init])) {
    _remote = remote;
    _local = (NSMachPort *)[NSMachPort port];
    _local.delegate = self;
    _nextId = 1;
    [[NSRunLoop currentRunLoop] addPort:_local forMode:NSDefaultRunLoopMode];
  }
  return self;
}

- (void)dealloc {
  [[NSRunLoop currentRunLoop] removePort:_local forMode:NSDefaultRunLoopMode];
  [_local invalidate];
}

- (void)handlePortMessage:(NSPortMessage *)m {
  NSArray *c = m.components;
  if (c.count < 2 || ![c[0] isKindOfClass:[NSData class]] || [c[0] length] != 8) return;
  int64_t rid;
  memcpy(&rid, [c[0] bytes], 8);
  if (rid == _waitingId && [c[1] isKindOfClass:[NSData class]]) _reply = c[1];
}

// The reply payload (empty for acknowledgements), or nil on timeout.
- (NSData *)send:(uint32_t)type payload:(NSDictionary *)payload {
  NSMutableData *data = [NSMutableData new];
  NSKeyedArchiver *a = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
  for (NSString *k in payload) [a encodeObject:payload[k] forKey:k];
  [a finishEncoding];

  int64_t rid = _nextId++;
  _waitingId = rid;
  _reply = nil;
  NSPortMessage *m = [[NSPortMessage alloc] initWithSendPort:_remote
                                                 receivePort:_local
                                                  components:@[[NSData dataWithBytes:&rid length:8], data]];
  m.msgid = type;
  if (![m sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:kReplyTimeout]]) return nil;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kReplyTimeout];
  while (!_reply && deadline.timeIntervalSinceNow > 0)
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  return _reply;
}

- (BOOL)status:(OOStatus *)status of:(NSString *)path error:(NSString **)error {
  return OOStatusFromReply([self send:kStatus payload:@{@"url": [NSURL fileURLWithPath:path]}], status, error);
}

// The menu supplies the account instance the action must name, and is the check that Dropbox
// offers the action at all.
- (OORequestResult)request:(OOTarget)target for:(NSString *)path error:(NSString **)error {
  NSArray *pathlist = @[[NSURL fileURLWithPath:path]];
  NSDictionary *verbs = OOVerbsFromReply([self send:kContextMenu payload:@{@"pathlist": pathlist}], error);
  if (!verbs) return OORequestUnanswered;
  NSString *verb = OOTargetVerb(target);
  NSString *instance = verbs[verb];
  if (!instance) return OORequestNotOffered;
  if (![self send:kAction payload:@{@"action": verb, @"host_int": instance, @"pathlist": pathlist}]) {
    if (error) *error = @"no reply from Dropbox";
    return OORequestUnanswered;
  }
  return OORequestSent;
}

- (NSArray<NSString *> *)roots {
  NSKeyedUnarchiver *u = OpenReply([self send:kWatchSet payload:@{}], @"watch_set", NULL);
  NSSet *set = [u decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [NSURL class], [NSString class], nil] forKey:@"watch_set"];
  NSMutableArray *paths = [NSMutableArray new];
  for (id url in set)
    if ([url isKindOfClass:[NSURL class]]) [paths addObject:[[url path] stringByStandardizingPath]];
  return [paths sortedArrayUsingSelector:@selector(compare:)];
}

@end
