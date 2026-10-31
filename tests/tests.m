#import <Foundation/Foundation.h>
#import "../src/OODomain.h"
#import "../src/OODropbox.h"
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

// In-memory Dropbox: per-path status and offered verbs. A performed verb lands after
// `settleAfter` further status reads, standing in for Dropbox applying it asynchronously.
// Like the real client, it drops a verb performed while the path is syncing, and drops the
// next `dropNext` verbs outright.
@interface FakeBackend : NSObject <OOBackend>
@property NSMutableDictionary<NSString *, NSNumber *> *statuses;
@property NSMutableArray<NSArray *> *performed;
@property int settleAfter;
@property BOOL silent;
// Status requests answer, but context-menu requests get no reply.
@property BOOL menuSilent;
// Dropbox answers the context-menu request but offers no verbs.
@property BOOL menuEmpty;
@property int dropNext;
// Sets a status outright, dropping any change still in flight.
- (void)set:(NSString *)path to:(int)status;
// Reports syncing for `reads` status reads, then `status`.
- (void)syncing:(NSString *)path reads:(int)reads then:(int)status;
@end

@implementation FakeBackend {
  NSMutableDictionary<NSString *, NSArray *> *_inFlight;
}

- (instancetype)init {
  if ((self = [super init])) {
    _statuses = [NSMutableDictionary new];
    _performed = [NSMutableArray new];
    _inFlight = [NSMutableDictionary new];
  }
  return self;
}

- (void)set:(NSString *)path to:(int)status {
  [_inFlight removeObjectForKey:path];
  _statuses[path] = @(status);
}

- (void)syncing:(NSString *)path reads:(int)reads then:(int)status {
  _statuses[path] = @(OOStatusSyncing);
  _inFlight[path] = @[@(status), @(reads)];
}

- (int)statusOf:(NSString *)path error:(NSString **)error {
  if (_silent) {
    if (error) *error = @"no reply from Dropbox";
    return OOStatusNoReply;
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
  return _statuses[path] ? _statuses[path].intValue : OOStatusNone;
}

- (NSDictionary<NSString *, NSString *> *)verbsFor:(NSString *)path error:(NSString **)error {
  if (_silent || _menuSilent) {
    if (error) *error = @"no reply from Dropbox";
    return nil;
  }
  if (_menuEmpty) return @{};
  int s = _statuses[path] ? _statuses[path].intValue : OOStatusNone;
  if (s == OOStatusNone) return @{@"copy_link": @"42"};
  if (s == OOStatusOnlineOnly) return @{@"dod_recall": @"42", @"copy_link": @"42"};
  if (s == OOStatusOffline) return @{@"dod_evict": @"42"};
  return @{@"dod_evict": @"42", @"dod_recall": @"42"};
}

- (BOOL)perform:(NSString *)verb instance:(NSString *)instance path:(NSString *)path {
  [_performed addObject:@[verb, instance, path]];
  if (_statuses[path].intValue == OOStatusSyncing) return YES;
  if (_dropNext > 0) {
    _dropNext--;
    return YES;
  }
  int to = [verb isEqualToString:@"dod_evict"] ? OOStatusOnlineOnly : OOStatusOffline;
  _inFlight[path] = @[@(to), @(_settleAfter)];
  return YES;
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
  CHECK(OOStatusFromReply(nil, &err) == OOStatusNoReply);
  CHECK_EQ(err, @"no reply from Dropbox");

  err = nil;
  CHECK(OOStatusFromReply([@"garbage" dataUsingEncoding:NSUTF8StringEncoding], &err) == OOStatusNoReply);
  CHECK([err hasPrefix:@"unreadable reply from Dropbox"]);

  err = nil;
  NSData *noStatus = Archive(^(NSKeyedArchiver *a) { [a encodeObject:@"x" forKey:@"other"]; });
  CHECK(OOStatusFromReply(noStatus, &err) == OOStatusNoReply);
  CHECK_EQ(err, @"reply from Dropbox has no status");

  err = nil;
  NSData *online = Archive(^(NSKeyedArchiver *a) { [a encodeInt:OOStatusOnlineOnly forKey:@"status"]; });
  CHECK(OOStatusFromReply(online, &err) == OOStatusOnlineOnly);
  CHECK(err == nil);

  // Status 0 is a real answer (not in a Dropbox folder), distinct from a missing key.
  NSData *none = Archive(^(NSKeyedArchiver *a) { [a encodeInt:0 forKey:@"status"]; });
  CHECK(OOStatusFromReply(none, &err) == OOStatusNone);

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

  // A requested change sends the offered verb with its account instance, without waiting.
  [fake set:file to:OOStatusLocal];
  NSDictionary *r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultRequested);
  CHECK_EQ(fake.performed.lastObject, (@[@"dod_evict", @"42", file]));

  // Waiting returns done once the backend reports the target status.
  [fake set:file to:OOStatusLocal];
  fake.settleAfter = 3;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultDone);
  CHECK_EQ(r[@"status"], @"online-only");

  // A path already in the target state is reported, not re-sent.
  NSUInteger sent = fake.performed.count;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultAlready);
  CHECK(fake.performed.count == sent);

  // A change that never lands within the timeout is pending, not failed.
  [fake set:file to:OOStatusOnlineOnly];
  fake.settleAfter = 1000000;
  r = [svc apply:OOTargetOffline paths:@[file] wait:YES timeout:0.05][0];
  CHECK_EQ(r[@"result"], OOResultPending);

  // Paths outside Dropbox, missing paths and a silent Dropbox each fail with a reason.
  [fake.statuses removeAllObjects];
  r = [svc apply:OOTargetOffline paths:@[file] wait:NO timeout:0][0];
  CHECK_EQ(r[@"result"], OOResultFailed);
  CHECK_EQ(r[@"error"], @"not in a Dropbox folder");
  r = [svc apply:OOTargetOffline paths:@[@"/nonexistent/onlineonly"] wait:NO timeout:0][0];
  CHECK_EQ(r[@"result"], OOResultFailed);
  fake.silent = YES;
  r = [svc apply:OOTargetOffline paths:@[file] wait:NO timeout:0][0];
  CHECK_EQ(r[@"error"], @"no reply from Dropbox");
  fake.silent = NO;

  // An unanswered menu request is a missing reply, not a verb Dropbox declined to offer.
  [fake set:file to:OOStatusLocal];
  fake.menuSilent = YES;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:0][0];
  CHECK_EQ(r[@"result"], OOResultFailed);
  CHECK_EQ(r[@"error"], @"no reply from Dropbox");
  fake.menuSilent = NO;

  // An answered menu without the verb is what "does not offer" means.
  fake.menuEmpty = YES;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:0][0];
  CHECK_EQ(r[@"error"], @"Dropbox does not offer Make online-only for this path");
  fake.menuEmpty = NO;

  // A status read with no answer carries the reason rather than passing as a status.
  fake.silent = YES;
  CHECK_EQ([svc statusOf:file][@"error"], @"no reply from Dropbox");
  fake.silent = NO;

  // A path that is still syncing is requested only once it settles, since Dropbox drops
  // requests made mid-sync.
  [fake.performed removeAllObjects];
  [fake syncing:file reads:3 then:OOStatusLocal];
  fake.settleAfter = 1;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultDone);
  CHECK(fake.performed.count == 1);

  // Without wait, the request is still held until the path settles.
  [fake.performed removeAllObjects];
  [fake syncing:file reads:3 then:OOStatusOnlineOnly];
  r = [svc apply:OOTargetOffline paths:@[file] wait:NO timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultRequested);
  CHECK(fake.performed.count == 1);

  // A path that keeps syncing past the hold is pending and was never requested.
  [fake.performed removeAllObjects];
  [fake syncing:file reads:1000000 then:OOStatusLocal];
  svc.settleTimeout = 0.05;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:NO timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultPending);
  CHECK(fake.performed.count == 0);

  // A dropped request is re-sent once the settled path has not moved for resendInterval.
  [fake set:file to:OOStatusLocal];
  fake.dropNext = 1;
  svc.resendInterval = 0.01;
  r = [svc apply:OOTargetOnlineOnly paths:@[file] wait:YES timeout:5][0];
  CHECK_EQ(r[@"result"], OOResultDone);
  CHECK(fake.performed.count == 2);

  // Results keep input order across mixed outcomes.
  [fake set:file to:OOStatusOffline];
  NSArray *rs = [svc apply:OOTargetOffline paths:@[@"/nonexistent/x", file] wait:NO timeout:0];
  CHECK_EQ(rs[0][@"result"], OOResultFailed);
  CHECK_EQ(rs[1][@"result"], OOResultAlready);
}

static void TestChildren(void) {
  // Listing skips dot files, marks folders, and honors the limit.
  NSString *dir = TempDir();
  OOService *svc = [[OOService alloc] initWithBackend:[FakeBackend new]];
  BOOL truncated = YES;
  NSArray *kids = [svc childrenOf:dir limit:10 truncated:&truncated error:NULL];
  CHECK_EQ([kids valueForKey:@"name"], (@[@"a.txt", @"sub"]));
  CHECK_EQ([kids valueForKey:@"directory"], (@[@NO, @YES]));
  CHECK(!truncated);
  kids = [svc childrenOf:dir limit:1 truncated:&truncated error:NULL];
  CHECK(kids.count == 1 && truncated);
  NSString *err;
  CHECK([svc childrenOf:@"/nonexistent/onlineonly" limit:1 truncated:NULL error:&err] == nil && err.length);
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
  CHECK_EQ(r[@"structuredContent"][@"results"][0][@"result"], OOResultDone);

  // wait=false only requests the change.
  r = Call(s, Req(9, @"tools/call", @{@"name": @"make_available_offline", @"arguments": @{@"paths": @[file], @"wait": @NO}}))[@"result"];
  CHECK_EQ(r[@"structuredContent"][@"results"][0][@"result"], OOResultRequested);

  // Bad arguments, failed paths and a stopped Dropbox are tool errors the model can read.
  r = Call(s, Req(10, @"tools/call", @{@"name": @"make_online_only", @"arguments": @{@"paths": @"not-an-array"}}))[@"result"];
  CHECK_EQ(r[@"isError"], @YES);
  r = Call(s, Req(11, @"tools/call", @{@"name": @"make_online_only", @"arguments": @{@"paths": @[@"/nonexistent/x"]}}))[@"result"];
  CHECK_EQ(r[@"isError"], @YES);
  running = NO;
  r = Call(s, Req(12, @"tools/call", @{@"name": @"get_sync_status", @"arguments": @{@"paths": @[dir]}}))[@"result"];
  CHECK_EQ(r[@"isError"], @YES);
  CHECK([r[@"content"][0][@"text"] containsString:@"not running"]);
}

int main(void) {
  @autoreleasepool {
    TestParseMenu();
    TestStatusNames();
    TestReplies();
    TestApply();
    TestChildren();
    TestMCP();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
}
