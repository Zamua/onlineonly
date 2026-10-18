// Wire format: an NSPortMessage whose msgid is the request type and whose components are
// [int64 request id, NSKeyedArchiver payload]. Dropbox replies on the message's receive port
// with the same id; acknowledgements carry an empty payload.
#import "OODropbox.h"
#import "OODomain.h"
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

- (NSKeyedUnarchiver *)request:(uint32_t)type payload:(NSDictionary *)payload {
  NSData *d = [self send:type payload:payload];
  if (!d.length) return nil;
  NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:d error:NULL];
  u.requiresSecureCoding = YES;
  return u;
}

- (int)statusOf:(NSString *)path {
  NSKeyedUnarchiver *u = [self request:kStatus payload:@{@"url": [NSURL fileURLWithPath:path]}];
  return u ? [u decodeIntForKey:@"status"] : OOStatusNoReply;
}

- (NSDictionary<NSString *, NSString *> *)verbsFor:(NSString *)path {
  NSKeyedUnarchiver *u = [self request:kContextMenu payload:@{@"pathlist": @[[NSURL fileURLWithPath:path]]}];
  NSString *menu = [u decodeObjectOfClass:[NSString class] forKey:@"menu"];
  return menu ? OOParseMenu(menu) : nil;
}

- (BOOL)perform:(NSString *)verb instance:(NSString *)instance path:(NSString *)path {
  return [self send:kAction payload:@{
    @"action": verb,
    @"host_int": instance,
    @"pathlist": @[[NSURL fileURLWithPath:path]],
  }] != nil;
}

- (NSArray<NSString *> *)roots {
  NSKeyedUnarchiver *u = [self request:kWatchSet payload:@{}];
  NSSet *set = [u decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [NSURL class], [NSString class], nil] forKey:@"watch_set"];
  NSMutableArray *paths = [NSMutableArray new];
  for (id url in set)
    if ([url isKindOfClass:[NSURL class]]) [paths addObject:[[url path] stringByStandardizingPath]];
  return [paths sortedArrayUsingSelector:@selector(compare:)];
}

@end
