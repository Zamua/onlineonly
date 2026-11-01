#import <Foundation/Foundation.h>
#import "../src/OODropbox.h"
#import "../src/OOJob.h"
#import "../src/OOMCP.h"
#import "../src/OOService.h"

static int failures = 0, checks = 0;

#define CHECK(cond)                                                     \
  do {                                                                  \
    checks++;                                                           \
    if (!(cond)) {                                                      \
      failures++;                                                       \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);   \
    }                                                                   \
  } while (0)

#define CHECK_EQ(a, b) CHECK([(a) isEqual:(b)])

// In-memory Dropbox: per-path status and the actions its menu offers. A request lands after
// `settleAfter` further status reads, standing in for Dropbox applying it asynchronously. Like
// the real client, it drops a request made while the path is syncing, and drops the next
// `dropNext` requests outright.
@interface FakeBackend : NSObject <OOBackend>
@property NSMutableDictionary<NSString *, NSNumber *> *statuses;
// [target, path] per acknowledged request.
@property NSMutableArray<NSArray *> *requested;
@property int settleAfter;
@property BOOL silent;
// Status reads for these paths get no reply.
@property NSMutableSet<NSString *> *silentPaths;
// Status requests answer, but context-menu requests get no reply.
@property BOOL menuSilent;
// Dropbox answers the context-menu request but offers no actions.
@property BOOL menuEmpty;
// How many more requests it acknowledges once the menu offers the action; -1 for all.
@property int acks;
@property int dropNext;
// Sets a status outright, dropping any change still in flight.
- (void)set:(NSString *)path to:(OOStatus)status;
// Reports syncing for `reads` status reads, then `status`.
- (void)syncing:(NSString *)path reads:(int)reads then:(OOStatus)status;
@end

@implementation FakeBackend {
  NSMutableDictionary<NSString *, NSArray *> *_inFlight;
}

- (instancetype)init {
  if ((self = [super init])) {
    _statuses = [NSMutableDictionary new];
    _requested = [NSMutableArray new];
    _silentPaths = [NSMutableSet new];
    _inFlight = [NSMutableDictionary new];
    _acks = -1;
  }
  return self;
}

- (void)set:(NSString *)path to:(OOStatus)status {
  [_inFlight removeObjectForKey:path];
  _statuses[path] = @(status);
}

- (void)syncing:(NSString *)path reads:(int)reads then:(OOStatus)status {
  _statuses[path] = @(OOStatusSyncing);
  _inFlight[path] = @[@(status), @(reads)];
}

- (OOStatus)current:(NSString *)path {
  return _statuses[path] ? (OOStatus)_statuses[path].intValue : OOStatusNone;
}

- (BOOL)status:(OOStatus *)status of:(NSString *)path error:(NSString **)error {
  if (_silent || [_silentPaths containsObject:path]) {
    if (error) *error = @"no reply from Dropbox";
    return NO;
  }
  NSArray *f = _inFlight[path];
  if (f) {
    int left = [f[1] intValue];
    if (left <= 0) {
      _statuses[path] = f[0];
      [_inFlight removeObjectForKey:path];
    } else {
      _inFlight[path] = @[f[0], @(left - 1)];
    }
  }
  *status = [self current:path];
  return YES;
}

// Like the real menu: nothing outside Dropbox, and only the action that changes the state.
- (BOOL)offers:(OOTarget)target for:(NSString *)path {
  OOStatus s = [self current:path];
  if (_menuEmpty || s == OOStatusNone) return NO;
  return s != OOTargetStatus(target);
}

- (OORequestResult)request:(OOTarget)target for:(NSString *)path error:(NSString **)error {
  if (_silent || _menuSilent) {
    if (error) *error = @"no reply from Dropbox";
    return OORequestUnanswered;
  }
  if (![self offers:target for:path]) return OORequestNotOffered;
  if (_acks == 0) {
    if (error) *error = @"no reply from Dropbox";
    return OORequestUnanswered;
  }
  if (_acks > 0) _acks--;
  [_requested addObject:@[@(target), path]];
  if ([self current:path] == OOStatusSyncing) return OORequestSent;
  if (_dropNext > 0) {
    _dropNext--;
    return OORequestSent;
  }
  _inFlight[path] = @[@(OOTargetStatus(target)), @(_settleAfter)];
  return OORequestSent;
}

@end

static NSString *TempDir(void) {
  NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  [[NSFileManager defaultManager] createDirectoryAtPath:[d stringByAppendingPathComponent:@"sub"]
                            withIntermediateDirectories:YES attributes:nil error:NULL];
  [@"x" writeToFile:[d stringByAppendingPathComponent:@"a.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  [@"" writeToFile:[d stringByAppendingPathComponent:@".hidden"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  return OOResolvePath(d, NULL);
}

static void TestParseMenu(void) {
  // Menu parsing extracts {verb: instance} from the encoded context menu.
  NSDictionary *v = OOParseMenu(@"Copy Dropbox link~Copy a link~copy_link-10000000001|Make online-only~~dod_evict-10000000001|junk|Make available offline~~dod_recall-7");
  CHECK_EQ(v[@"copy_link"], @"10000000001");
  CHECK_EQ(v[@"dod_evict"], @"10000000001");
  CHECK_EQ(v[@"dod_recall"], @"7");
  CHECK(v.count == 3);

  // Submenus are percent-encoded inline and parsed recursively.
  NSString *inner = [@"Make online-only~~dod_evict-9" stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
  v = OOParseMenu([NSString stringWithFormat:@"More~submenu~%@", inner]);
  CHECK_EQ(v[@"dod_evict"], @"9");

  // Malformed actions are skipped rather than misparsed.
  CHECK(OOParseMenu(@"A~~noinstance|B~~-5|C~~verb-").count == 0);
  CHECK(OOParseMenu(@"").count == 0);
}


static NSData *Archive(void (^fill)(NSKeyedArchiver *)) {
  NSKeyedArchiver *a = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
  fill(a);
  [a finishEncoding];
  return a.encodedData;
}

static void TestReplies(void) {
  NSString *err;

  // A missing reply, an undecodable one and one without the expected key are each named,
  // never passed off as a status or as "no verbs offered".
  OOStatus status = OOStatusLocked;
  CHECK(!OOStatusFromReply(nil, &status, &err));
  CHECK_EQ(err, @"no reply from Dropbox");

  err = nil;
  CHECK(!OOStatusFromReply([@"garbage" dataUsingEncoding:NSUTF8StringEncoding], &status, &err));
  CHECK([err hasPrefix:@"unreadable reply from Dropbox"]);

  err = nil;
  NSData *noStatus = Archive(^(NSKeyedArchiver *a) { [a encodeObject:@"x" forKey:@"other"]; });
  CHECK(!OOStatusFromReply(noStatus, &status, &err));
  CHECK_EQ(err, @"reply from Dropbox has no status");

  err = nil;
  NSData *online = Archive(^(NSKeyedArchiver *a) { [a encodeInt:OOStatusOnlineOnly forKey:@"status"]; });
  CHECK(OOStatusFromReply(online, &status, &err) && status == OOStatusOnlineOnly);
  CHECK(err == nil);

  // Status 0 is a real answer (not in a Dropbox folder), distinct from a missing key.
  NSData *none = Archive(^(NSKeyedArchiver *a) { [a encodeInt:0 forKey:@"status"]; });
  CHECK(OOStatusFromReply(none, &status, &err) && status == OOStatusNone);

  err = nil;
  CHECK(OOVerbsFromReply(nil, &err) == nil);
  CHECK_EQ(err, @"no reply from Dropbox");

  err = nil;
  CHECK(OOVerbsFromReply(noStatus, &err) == nil);
  CHECK_EQ(err, @"reply from Dropbox has no menu");

  err = nil;
  NSData *menu = Archive(^(NSKeyedArchiver *a) { [a encodeObject:@"Make online-only~~dod_evict-7" forKey:@"menu"]; });
  CHECK_EQ(OOVerbsFromReply(menu, &err), (@{@"dod_evict": @"7"}));
  CHECK(err == nil);
}

static void TestStatusNames(void) {
  // Status names cover every code the Finder extension knows.
  CHECK_EQ(OOStatusName(OOStatusOnlineOnly), @"online-only");
  CHECK_EQ(OOStatusName(OOStatusOffline), @"offline");
  CHECK_EQ(OOStatusName(OOStatusLocal), @"local");
  CHECK_EQ(OOStatusName(OOStatusLocked), @"locked");
  CHECK_EQ(OOStatusName(7), @"unknown(7)");
  CHECK_EQ(OOTargetVerb(OOTargetOnlineOnly), @"dod_evict");
  CHECK_EQ(OOTargetVerb(OOTargetOffline), @"dod_recall");
}

static void TestApply(void) {
  NSString *dir = TempDir();
  NSString *file = [dir stringByAppendingPathComponent:@"a.txt"];
  FakeBackend *fake = [FakeBackend new];
  OOService *svc = [[OOService alloc] initWithBackend:fake];
  svc.pollInterval = 0;

  // A requested change is sent for the target, without waiting.
  [fake set:file to:OOStatusLocal];
  OOApplyResult *r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:5][0];
  CHECK(r.outcome == OOOutcomeRequested);
  CHECK_EQ(fake.requested.lastObject, (@[@(OOTargetOnlineOnly), file]));

  // Waiting returns done once the backend reports the target status.
  [fake set:file to:OOStatusLocal];
  fake.settleAfter = 3;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK(r.outcome == OOOutcomeDone);
  CHECK(r.hasStatus && r.status == OOStatusOnlineOnly);

  // A path already in the target state is reported, not re-sent.
  NSUInteger sent = fake.requested.count;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK(r.outcome == OOOutcomeAlready);
  CHECK(fake.requested.count == sent);

  // A change that never lands within the timeout is pending, not failed.
  [fake set:file to:OOStatusOnlineOnly];
  fake.settleAfter = 1000000;
  r = [svc apply:OOTargetOffline paths:@[file] wait:YES timeout:0][0];
  CHECK(r.outcome == OOOutcomePending);

  // Paths outside Dropbox, missing paths and a silent Dropbox each fail with a reason.
  [fake.statuses removeAllObjects];
  r = [svc apply:OOTargetOffline paths:@[file] wait:NO timeout:0][0];
  CHECK(r.outcome == OOOutcomeFailed);
  CHECK_EQ(r.error, @"not in a Dropbox folder");
  r = [svc apply:OOTargetOffline paths:@[@"/nonexistent/onlineonly"] wait:NO timeout:0][0];
  CHECK(r.outcome == OOOutcomeFailed);
  fake.silent = YES;
  r = [svc apply:OOTargetOffline paths:@[file] wait:NO timeout:0][0];
  CHECK_EQ(r.error, @"no reply from Dropbox");
  fake.silent = NO;

  // An unanswered menu request is a missing reply, not a verb Dropbox declined to offer.
  [fake set:file to:OOStatusLocal];
  fake.menuSilent = YES;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:0][0];
  CHECK(r.outcome == OOOutcomeFailed);
  CHECK_EQ(r.error, @"no reply from Dropbox");
  fake.menuSilent = NO;

  // An action Dropbox never acknowledges fails with the adapter's reason.
  fake.acks = 0;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:0][0];
  CHECK(r.outcome == OOOutcomeFailed);
  CHECK_EQ(r.error, @"no reply from Dropbox");
  fake.acks = -1;

  // An answered menu without the action is what "does not offer" means.
  fake.menuEmpty = YES;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:0][0];
  CHECK_EQ(r.error, @"Dropbox does not offer Make online-only for this path");
  fake.menuEmpty = NO;

  // A status read with no answer carries the reason rather than passing as a status.
  fake.silent = YES;
  CHECK_EQ([svc statusOf:file].error, @"no reply from Dropbox");
  fake.silent = NO;

  // A path that is still syncing is requested only once it settles, since Dropbox drops
  // requests made mid-sync.
  [fake.requested removeAllObjects];
  [fake syncing:file reads:3 then:OOStatusLocal];
  fake.settleAfter = 1;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK(r.outcome == OOOutcomeDone);
  CHECK(fake.requested.count == 1);

  // Without wait, the request is still held until the path settles.
  [fake.requested removeAllObjects];
  [fake syncing:file reads:3 then:OOStatusOnlineOnly];
  r = [svc apply:OOTargetOffline paths:@[file] wait:NO timeout:5][0];
  CHECK(r.outcome == OOOutcomeRequested);
  CHECK(fake.requested.count == 1);

  // A path that keeps syncing past the hold is pending and was never requested.
  [fake.requested removeAllObjects];
  [fake syncing:file reads:1000000 then:OOStatusLocal];
  svc.settleTimeout = 0;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:5][0];
  CHECK(r.outcome == OOOutcomePending);
  CHECK(fake.requested.count == 0);

  // A dropped request is re-sent (resend timing itself is pinned in TestJob).
  [fake set:file to:OOStatusLocal];
  fake.dropNext = 1;
  fake.settleAfter = 0;
  svc.resendInterval = 0;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK(r.outcome == OOOutcomeDone);
  CHECK(fake.requested.count == 2);

  // Results keep input order across mixed outcomes.
  [fake set:file to:OOStatusOffline];
  NSArray<OOApplyResult *> *rs = [svc apply:OOTargetOffline paths:@[@"/nonexistent/x", file] wait:NO timeout:0];
  CHECK(rs[0].outcome == OOOutcomeFailed);
  CHECK(rs[1].outcome == OOOutcomeAlready);
}

// The apply lifecycle as event sequences, with time passed in.
static void TestJob(void) {
  NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1000];
  NSDate *(^at)(NSTimeInterval) = ^(NSTimeInterval s) { return [t0 dateByAddingTimeInterval:s]; };
  OOApplyPolicy waiting = {.target = OOTargetOnlineOnly, .wait = YES, .resendInterval = 15};
  OOApplyPolicy once = {.target = OOTargetOnlineOnly, .wait = NO, .resendInterval = 15};
  BOOL request = NO;

  // Unsent, settled: ask. Acknowledged with wait: Sent. Target reached: done.
  OOJob *j = [OOJob unsent:@"/p"];
  j = [j next:[OOJobEvent polledStatus:OOStatusLocal at:t0] policy:waiting request:&request];
  CHECK(request && j.phase == OOJobUnsent);
  j = [j next:[OOJobEvent answered:OORequestSent error:nil at:t0] policy:waiting request:&request];
  CHECK(!request && j.phase == OOJobSent);
  j = [j next:[OOJobEvent polledStatus:OOStatusOnlineOnly at:at(1)] policy:waiting request:&request];
  CHECK(j.phase == OOJobFinal && j.result.outcome == OOOutcomeDone);

  // A Sent path that has not moved is asked again only once resendInterval has passed, and
  // an unanswered resend leaves it Sent with the clock where it was.
  j = [[[OOJob unsent:@"/p"] next:[OOJobEvent polledStatus:OOStatusLocal at:t0] policy:waiting request:&request]
          next:[OOJobEvent answered:OORequestSent error:nil at:t0] policy:waiting request:&request];
  j = [j next:[OOJobEvent polledStatus:OOStatusLocal at:at(14.9)] policy:waiting request:&request];
  CHECK(!request && j.phase == OOJobSent);
  j = [j next:[OOJobEvent polledStatus:OOStatusLocal at:at(15)] policy:waiting request:&request];
  CHECK(request);
  j = [j next:[OOJobEvent answered:OORequestUnanswered error:@"no reply from Dropbox" at:at(15)] policy:waiting request:&request];
  CHECK(j.phase == OOJobSent);
  j = [j next:[OOJobEvent polledStatus:OOStatusLocal at:at(16)] policy:waiting request:&request];
  CHECK(request);
  j = [j next:[OOJobEvent timedOut] policy:waiting request:&request];
  CHECK(j.result.outcome == OOOutcomePending && j.result.error == nil && j.result.status == OOStatusLocal);

  // Syncing holds the request, and a timeout then reports it was never sent.
  j = [[OOJob unsent:@"/p"] next:[OOJobEvent polledStatus:OOStatusSyncing at:t0] policy:once request:&request];
  CHECK(!request && j.phase == OOJobUnsent);
  j = [j next:[OOJobEvent timedOut] policy:once request:&request];
  CHECK(j.result.outcome == OOOutcomePending);
  CHECK_EQ(j.result.error, @"still syncing; not requested yet");

  // Without wait, an acknowledged request is final.
  j = [[[OOJob unsent:@"/p"] next:[OOJobEvent polledStatus:OOStatusLocal at:t0] policy:once request:&request]
          next:[OOJobEvent answered:OORequestSent error:nil at:t0] policy:once request:&request];
  CHECK(j.result.outcome == OOOutcomeRequested && j.result.status == OOStatusLocal);

  // Already there; a first request refused or unanswered; a status Dropbox does not give.
  j = [[OOJob unsent:@"/p"] next:[OOJobEvent polledStatus:OOStatusOnlineOnly at:t0] policy:once request:&request];
  CHECK(!request && j.result.outcome == OOOutcomeAlready);
  OOJob *(^refused)(OOStatus, OORequestResult) = ^(OOStatus s, OORequestResult r) {
    BOOL ask;
    return [[[OOJob unsent:@"/p"] next:[OOJobEvent polledStatus:s at:t0] policy:once request:&ask]
               next:[OOJobEvent answered:r error:@"no reply from Dropbox" at:t0] policy:once request:&ask];
  };
  CHECK_EQ(refused(OOStatusNone, OORequestNotOffered).result.error, @"not in a Dropbox folder");
  CHECK_EQ(refused(OOStatusLocal, OORequestNotOffered).result.error, @"Dropbox does not offer Make online-only for this path");
  CHECK_EQ(refused(OOStatusLocal, OORequestUnanswered).result.error, @"no reply from Dropbox");
  j = [[OOJob unsent:@"/p"] next:[OOJobEvent polledError:@"no reply from Dropbox"] policy:once request:&request];
  CHECK(j.result.outcome == OOOutcomeFailed && !j.result.hasStatus);

  // Events with nothing to act on: a final job, an answer nobody asked for, a timeout before
  // any status.
  OOJob *done = [OOJob path:@"/x" failure:@"No such file or directory"];
  CHECK([done next:[OOJobEvent polledStatus:OOStatusLocal at:t0] policy:once request:&request] == done && !request);
  j = [OOJob unsent:@"/p"];
  CHECK([j next:[OOJobEvent answered:OORequestSent error:nil at:t0] policy:once request:&request] == j);
  CHECK_EQ([j next:[OOJobEvent timedOut] policy:once request:&request].result.error, @"no status from Dropbox before the timeout");
}

static void TestChildren(void) {
  // Listing skips dot files, marks folders, and honors the limit.
  NSString *dir = TempDir();
  OOService *svc = [[OOService alloc] initWithBackend:[FakeBackend new]];
  OOListing *l = [svc childrenOf:dir limit:10];
  NSMutableArray *names = [NSMutableArray new], *dirs = [NSMutableArray new];
  for (OOEntry *e in l.entries) {
    [names addObject:e.name];
    [dirs addObject:@(e.directory)];
  }
  CHECK_EQ(names, (@[@"a.txt", @"sub"]));
  CHECK_EQ(dirs, (@[@NO, @YES]));
  CHECK(!l.truncated && !l.error);
  l = [svc childrenOf:dir limit:1];
  CHECK(l.entries.count == 1 && l.truncated);
  l = [svc childrenOf:@"/nonexistent/onlineonly" limit:1];
  CHECK(l.error.length && l.entries.count == 0);

  // A folder read with children carries its listing; a file never does.
  CHECK([svc statusOf:dir childLimit:10].children.entries.count == 2);
  CHECK([svc statusOf:[dir stringByAppendingPathComponent:@"a.txt"] childLimit:10].children == nil);
}

static id Call(OOMCPServer *s, NSString *line) {
  NSString *out = [s handleLine:line];
  return out ? [NSJSONSerialization JSONObjectWithData:[out dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
}

static NSString *Req(int rid, NSString *method, id params) {
  NSMutableDictionary *m = [@{@"jsonrpc": @"2.0", @"id": @(rid), @"method": method} mutableCopy];
  if (params) m[@"params"] = params;
  return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:m options:0 error:NULL] encoding:NSUTF8StringEncoding];
}

static void TestMCP(void) {
  NSString *dir = TempDir();
  NSString *file = [dir stringByAppendingPathComponent:@"a.txt"];
  FakeBackend *fake = [FakeBackend new];
  [fake set:dir to:OOStatusOffline];
  [fake set:file to:OOStatusLocal];
  __block BOOL running = YES;
  OOMCPServer *s = [[OOMCPServer alloc] initWithConnector:^id<OOBackend> { return running ? fake : nil; } version:@"9.9.9"];
  s.pollInterval = 0;

  // initialize echoes a supported protocol version and falls back to the latest otherwise.
  NSDictionary *r = Call(s, Req(1, @"initialize", @{@"protocolVersion": @"2025-06-18", @"capabilities": @{}, @"clientInfo": @{@"name": @"t", @"version": @"1"}}));
  CHECK_EQ(r[@"id"], @1);
  CHECK_EQ(r[@"result"][@"protocolVersion"], @"2025-06-18");
  CHECK_EQ(r[@"result"][@"serverInfo"][@"version"], @"9.9.9");
  CHECK(r[@"result"][@"capabilities"][@"tools"] != nil);
  r = Call(s, Req(2, @"initialize", @{@"protocolVersion": @"1999-01-01"}));
  CHECK_EQ(r[@"result"][@"protocolVersion"], @"2025-11-25");

  // Notifications and stray responses get no reply.
  CHECK([s handleLine:@"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"] == nil);
  CHECK([s handleLine:@"{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}"] == nil);

  // Protocol errors map to the JSON-RPC codes.
  CHECK_EQ(Call(s, @"{not json")[@"error"][@"code"], @(-32700));
  CHECK_EQ(Call(s, @"[1,2]")[@"error"][@"code"], @(-32600));
  CHECK_EQ(Call(s, Req(3, @"resources/list", nil))[@"error"][@"code"], @(-32601));
  CHECK_EQ(Call(s, Req(4, @"tools/call", @{@"name": @"nope", @"arguments": @{}}))[@"error"][@"code"], @(-32602));
  CHECK_EQ(Call(s, Req(5, @"ping", nil))[@"result"], @{});

  // tools/list exposes the three tools with schemas and annotations.
  NSArray *tools = Call(s, Req(6, @"tools/list", nil))[@"result"][@"tools"];
  CHECK_EQ([tools valueForKey:@"name"], (@[@"get_sync_status", @"make_online_only", @"make_available_offline"]));
  for (NSDictionary *t in tools) {
    CHECK_EQ(t[@"inputSchema"][@"type"], @"object");
    CHECK_EQ(t[@"inputSchema"][@"required"], @[@"paths"]);
  }
  CHECK_EQ(tools[0][@"annotations"][@"readOnlyHint"], @YES);
  CHECK_EQ(tools[1][@"annotations"][@"destructiveHint"], @YES);

  // get_sync_status returns structured results, with children on request.
  r = Call(s, Req(7, @"tools/call", @{@"name": @"get_sync_status", @"arguments": @{@"paths": @[dir], @"include_children": @YES}}))[@"result"];
  CHECK_EQ(r[@"isError"], @NO);
  NSDictionary *first = r[@"structuredContent"][@"results"][0];
  CHECK_EQ(first[@"status"], @"offline");
  CHECK_EQ([first[@"children"] valueForKey:@"name"], (@[@"a.txt", @"sub"]));
  CHECK_EQ(first[@"children"][0][@"status"], @"local");
  CHECK([r[@"content"][0][@"text"] containsString:@"\"offline\""]);

  // make_online_only waits for the change by default.
  fake.settleAfter = 2;
  r = Call(s, Req(8, @"tools/call", @{@"name": @"make_online_only", @"arguments": @{@"paths": @[file]}}))[@"result"];
  CHECK_EQ(r[@"isError"], @NO);
  CHECK_EQ(r[@"structuredContent"][@"results"][0][@"result"], @"done");

  // wait=false only requests the change.
  r = Call(s, Req(9, @"tools/call", @{@"name": @"make_available_offline", @"arguments": @{@"paths": @[file], @"wait": @NO}}))[@"result"];
  CHECK_EQ(r[@"structuredContent"][@"results"][0][@"result"], @"requested");

  // Bad arguments, failed paths and a stopped Dropbox are tool errors the model can read.
  r = Call(s, Req(10, @"tools/call", @{@"name": @"make_online_only", @"arguments": @{@"paths": @"not-an-array"}}))[@"result"];
  CHECK_EQ(r[@"isError"], @YES);
  r = Call(s, Req(11, @"tools/call", @{@"name": @"make_online_only", @"arguments": @{@"paths": @[@"/nonexistent/x"]}}))[@"result"];
  CHECK_EQ(r[@"isError"], @YES);
  // Arguments of the wrong type are errors, not defaults; null counts as absent. An argument
  // error is a bare message, so a result with structuredContent got past parsing.
  NSString *(^argError)(NSString *, NSDictionary *) = ^NSString *(NSString *n, NSDictionary *a) {
    NSDictionary *res = Call(s, Req(13, @"tools/call", @{@"name": n, @"arguments": a}))[@"result"];
    return res[@"structuredContent"] ? nil : res[@"content"][0][@"text"];
  };
  CHECK_EQ(argError(@"get_sync_status", (@{@"paths": @[dir], @"include_children": @"yes"})), @"include_children must be a boolean");
  CHECK_EQ(argError(@"make_online_only", (@{@"paths": @[file], @"wait": @1})), @"wait must be a boolean");
  CHECK_EQ(argError(@"make_online_only", (@{@"paths": @[file], @"timeout_seconds": @"5"})), @"timeout_seconds must be a number from 0 to 600");
  CHECK_EQ(argError(@"make_online_only", (@{@"paths": @[file], @"timeout_seconds": @YES})), @"timeout_seconds must be a number from 0 to 600");
  CHECK_EQ(argError(@"make_online_only", (@{@"paths": @[file], @"timeout_seconds": @601})), @"timeout_seconds must be a number from 0 to 600");
  CHECK(argError(@"make_available_offline", (@{@"paths": @[file], @"wait": [NSNull null], @"extra": @1})) == nil);
  CHECK_EQ(argError(@"get_sync_status", (@{@"paths": @[@""]})), @"paths must be a non-empty array of path strings");

  running = NO;
  r = Call(s, Req(12, @"tools/call", @{@"name": @"get_sync_status", @"arguments": @{@"paths": @[dir]}}))[@"result"];
  CHECK_EQ(r[@"isError"], @YES);
  CHECK([r[@"content"][0][@"text"] containsString:@"not running"]);
}


// The result JSON is a contract: the CLI's --json and the MCP tools' structuredContent both
// emit it, so each outcome's exact shape is pinned here.
static void TestResultContract(void) {
  NSString *dir = TempDir();
  NSString *file = [dir stringByAppendingPathComponent:@"a.txt"];
  NSString *sub = [dir stringByAppendingPathComponent:@"sub"];
  FakeBackend *fake = [FakeBackend new];
  [fake set:dir to:OOStatusOffline];
  [fake set:file to:OOStatusLocal];
  OOMCPServer *s = [[OOMCPServer alloc] initWithConnector:^id<OOBackend> { return fake; } version:@"t"];
  s.pollInterval = 0;
  id (^first)(NSString *, NSDictionary *) = ^id(NSString *n, NSDictionary *a) {
    return Call(s, Req(1, @"tools/call", @{@"name": n, @"arguments": a}))[@"result"][@"structuredContent"][@"results"][0];
  };

  CHECK_EQ(first(@"get_sync_status", @{@"paths": @[file]}), (@{@"path": file, @"status": @"local"}));
  CHECK_EQ(first(@"get_sync_status", @{@"paths": @[dir], @"include_children": @YES}), (@{
    @"path": dir,
    @"status": @"offline",
    @"children": @[
      @{@"path": file, @"name": @"a.txt", @"directory": @NO, @"status": @"local"},
      @{@"path": sub, @"name": @"sub", @"directory": @YES, @"status": @"none"},
    ],
  }));
  CHECK_EQ(first(@"get_sync_status", @{@"paths": @[@"/nonexistent/x"]}),
           (@{@"path": @"/nonexistent/x", @"error": @"No such file or directory"}));
  fake.silent = YES;
  CHECK_EQ(first(@"get_sync_status", @{@"paths": @[file]}), (@{@"path": file, @"error": @"no reply from Dropbox"}));
  fake.silent = NO;

  CHECK_EQ(first(@"make_online_only", @{@"paths": @[file], @"wait": @NO}),
           (@{@"path": file, @"result": @"requested", @"status": @"local"}));
  [fake set:file to:OOStatusOnlineOnly];
  CHECK_EQ(first(@"make_online_only", @{@"paths": @[file]}),
           (@{@"path": file, @"result": @"already", @"status": @"online-only"}));
  [fake.statuses removeObjectForKey:file];
  CHECK_EQ(first(@"make_online_only", @{@"paths": @[file], @"wait": @NO}),
           (@{@"path": file, @"result": @"failed", @"status": @"none", @"error": @"not in a Dropbox folder"}));
  CHECK_EQ(first(@"make_online_only", @{@"paths": @[@"/nonexistent/x"]}),
           (@{@"path": @"/nonexistent/x", @"result": @"failed", @"error": @"No such file or directory"}));
  [fake syncing:file reads:1000000 then:OOStatusLocal];
  CHECK_EQ(first(@"make_online_only", @{@"paths": @[file], @"timeout_seconds": @0}),
           (@{@"path": file, @"result": @"pending", @"status": @"syncing", @"error": @"still syncing; not requested yet"}));

  // A status Dropbox does not answer is an error, never a status value.
  fake.silent = YES;
  CHECK_EQ(first(@"make_online_only", @{@"paths": @[file]}),
           (@{@"path": file, @"result": @"failed", @"error": @"no reply from Dropbox"}));
  fake.silent = NO;
  [fake.silentPaths addObject:sub];
  CHECK_EQ(first(@"get_sync_status", @{@"paths": @[dir], @"include_children": @YES})[@"children"][1],
           (@{@"path": sub, @"name": @"sub", @"directory": @YES, @"error": @"no reply from Dropbox"}));
}

int main(void) {
  @autoreleasepool {
    TestParseMenu();
    TestStatusNames();
    TestReplies();
    TestApply();
    TestJob();
    TestChildren();
    TestMCP();
    TestResultContract();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
}
