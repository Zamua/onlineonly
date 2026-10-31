#import "OOMCP.h"
#import "OOService.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *const kLatestProtocol = @"2025-11-25";

// Under the 60-second tool-call timeout several MCP clients default to.
static const NSTimeInterval kDefaultTimeout = 45;
static const NSTimeInterval kMaxTimeout = 600;
static const NSUInteger kChildLimit = 500;

enum {
  kParseError = -32700,
  kInvalidRequest = -32600,
  kMethodNotFound = -32601,
  kInvalidParams = -32602,
};

static NSDictionary *PathsSchema(void) {
  return @{
    @"type": @"array",
    @"items": @{@"type": @"string"},
    @"minItems": @1,
    @"description": @"Files or folders inside the local Dropbox folder. Absolute, ~/..., or relative to the server's working directory.",
  };
}

static NSDictionary *ApplySchema(void) {
  return @{
    @"type": @"object",
    @"properties": @{
      @"paths": PathsSchema(),
      @"wait": @{
        @"type": @"boolean",
        @"default": @YES,
        @"description": @"Block until Dropbox reports the new state (or timeout_seconds passes). Paths still changing are returned with result \"pending\".",
      },
      @"timeout_seconds": @{
        @"type": @"number",
        @"default": @(kDefaultTimeout),
        @"minimum": @0,
        @"maximum": @(kMaxTimeout),
        @"description": @"How long to wait when wait is true.",
      },
    },
    @"required": @[@"paths"],
    @"additionalProperties": @NO,
  };
}

typedef NS_ENUM(NSInteger, OOTool) {
  OOToolGetSyncStatus,
  OOToolMakeOnlineOnly,
  OOToolMakeAvailableOffline,
};

// tools/list order. Definitions and dispatch are exhaustive switches over OOTool, so a listed
// tool cannot lack either.
static const OOTool kTools[] = {OOToolGetSyncStatus, OOToolMakeOnlineOnly, OOToolMakeAvailableOffline};

static NSDictionary *ToolDefinition(OOTool tool) {
  switch (tool) {
    case OOToolGetSyncStatus:
      return @{
        @"name": @"get_sync_status",
        @"title": @"Get Dropbox sync status",
        @"description": @"Report whether files or folders in the local Dropbox folder are on disk or online-only: \"online-only\" (a 0-byte placeholder on disk, content in the cloud), \"offline\" (downloaded and kept on this computer), \"local\" (downloaded, but Dropbox may reclaim the space), \"syncing\", \"mixed\", \"error\", \"ignored\", \"locked\", or \"none\" (not managed by Dropbox). A folder's status is its own setting; its children can differ, so set include_children to see each entry.",
        @"inputSchema": @{
          @"type": @"object",
          @"properties": @{
            @"paths": PathsSchema(),
            @"include_children": @{
              @"type": @"boolean",
              @"default": @NO,
              @"description": @"For folders, also list the status of each immediate child.",
            },
          },
          @"required": @[@"paths"],
          @"additionalProperties": @NO,
        },
        @"annotations": @{@"readOnlyHint": @YES, @"openWorldHint": @NO},
      };
    case OOToolMakeOnlineOnly:
      return @{
        @"name": @"make_online_only",
        @"title": @"Make online-only",
        @"description": @"Free disk space by making files or folders online-only: Dropbox deletes the local copies, leaving 0-byte placeholders, and keeps the content in the cloud. Folders apply recursively. Programs that read a placeholder get an empty file, so do not use this on anything in active use (code checkouts, app data, files a running program needs). Reverse it with make_available_offline.",
        @"inputSchema": ApplySchema(),
        @"annotations": @{@"readOnlyHint": @NO, @"destructiveHint": @YES, @"idempotentHint": @YES, @"openWorldHint": @NO},
      };
    case OOToolMakeAvailableOffline:
      return @{
        @"name": @"make_available_offline",
        @"title": @"Make available offline",
        @"description": @"Download files or folders from Dropbox and keep them on this computer (Dropbox's \"Make available offline\"). Folders apply recursively; a large folder can take a while and use a lot of disk space.",
        @"inputSchema": ApplySchema(),
        @"annotations": @{@"readOnlyHint": @NO, @"destructiveHint": @NO, @"idempotentHint": @YES, @"openWorldHint": @NO},
      };
  }
}

static BOOL ToolNamed(id name, OOTool *tool) {
  for (size_t i = 0; i < sizeof kTools / sizeof *kTools; i++) {
    if ([ToolDefinition(kTools[i])[@"name"] isEqual:name]) {
      *tool = kTools[i];
      return YES;
    }
  }
  return NO;
}

// tools/call arguments, checked against the tool's schema once, before anything runs. Keys the
// schema does not name are ignored; JSON null counts as absent.
@interface OOToolArgs : NSObject
@property NSArray<NSString *> *paths;
@property BOOL includeChildren;
@property BOOL wait;
@property NSTimeInterval timeout;
@end

@implementation OOToolArgs
@end

static BOOL IsBool(id v) {
  return [v isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID();
}

static id Arg(NSDictionary *args, NSString *key) {
  id v = args[key];
  return v == [NSNull null] ? nil : v;
}

// nil when the arguments fit the tool's schema, otherwise what is wrong with them.
static NSString *ParseArgs(OOTool tool, NSDictionary *args, OOToolArgs *out) {
  NSArray *paths = Arg(args, @"paths");
  BOOL validPaths = [paths isKindOfClass:[NSArray class]] && paths.count > 0;
  for (id p in validPaths ? paths : @[]) validPaths = validPaths && [p isKindOfClass:[NSString class]] && [p length] > 0;
  if (!validPaths) return @"paths must be a non-empty array of path strings";
  out.paths = paths;

  switch (tool) {
    case OOToolGetSyncStatus: {
      id children = Arg(args, @"include_children");
      if (children && !IsBool(children)) return @"include_children must be a boolean";
      out.includeChildren = [children boolValue];
      return nil;
    }
    case OOToolMakeOnlineOnly:
    case OOToolMakeAvailableOffline: {
      id wait = Arg(args, @"wait"), timeout = Arg(args, @"timeout_seconds");
      if (wait && !IsBool(wait)) return @"wait must be a boolean";
      if (timeout && (![timeout isKindOfClass:[NSNumber class]] || IsBool(timeout) ||
                      [timeout doubleValue] < 0 || [timeout doubleValue] > kMaxTimeout))
        return [NSString stringWithFormat:@"timeout_seconds must be a number from 0 to %g", kMaxTimeout];
      out.wait = wait ? [wait boolValue] : YES;
      out.timeout = timeout ? [timeout doubleValue] : kDefaultTimeout;
      return nil;
    }
  }
}

static NSArray *Tools(void) {
  NSMutableArray *tools = [NSMutableArray new];
  for (size_t i = 0; i < sizeof kTools / sizeof *kTools; i++) [tools addObject:ToolDefinition(kTools[i])];
  return tools;
}

static NSString *Serialize(id obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingWithoutEscapingSlashes | NSJSONWritingSortedKeys error:NULL];
  return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSDictionary *ToolResult(id payload, BOOL isError) {
  NSString *text = [payload isKindOfClass:[NSString class]] ? payload : Serialize(payload);
  NSMutableDictionary *r = [@{
    @"content": @[@{@"type": @"text", @"text": text}],
    @"isError": @(isError),
  } mutableCopy];
  if ([payload isKindOfClass:[NSDictionary class]]) r[@"structuredContent"] = payload;
  return r;
}

@implementation OOMCPServer {
  OOConnector _connector;
  NSString *_version;
}

- (instancetype)initWithConnector:(OOConnector)connector version:(NSString *)version {
  if ((self = [super init])) {
    _connector = connector;
    _version = version;
    _pollInterval = 1;
  }
  return self;
}

- (NSString *)handleLine:(NSString *)line {
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  id msg = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (!msg) return [self error:kParseError message:@"Parse error" id:[NSNull null]];
  if (![msg isKindOfClass:[NSDictionary class]])
    return [self error:kInvalidRequest message:@"Expected a single JSON-RPC object" id:[NSNull null]];

  id rid = msg[@"id"];
  NSString *method = msg[@"method"];
  if (![method isKindOfClass:[NSString class]]) {
    // A response to a request this server never sends; nothing to answer.
    if (msg[@"result"] || msg[@"error"]) return nil;
    return [self error:kInvalidRequest message:@"Missing method" id:rid ?: [NSNull null]];
  }
  if (!rid) return nil;  // notification

  id params = msg[@"params"];
  if (params && ![params isKindOfClass:[NSDictionary class]])
    return [self error:kInvalidParams message:@"params must be an object" id:rid];

  if ([method isEqualToString:@"initialize"]) return [self result:[self initialize:params] id:rid];
  if ([method isEqualToString:@"ping"]) return [self result:@{} id:rid];
  if ([method isEqualToString:@"tools/list"]) return [self result:@{@"tools": Tools()} id:rid];
  if ([method isEqualToString:@"tools/call"]) {
    OOTool tool;
    if (!ToolNamed(params[@"name"], &tool))
      return [self error:kInvalidParams message:[NSString stringWithFormat:@"Unknown tool: %@", params[@"name"]] id:rid];
    id args = params[@"arguments"] ?: @{};
    if (![args isKindOfClass:[NSDictionary class]])
      return [self result:ToolResult(@"arguments must be an object", YES) id:rid];
    OOToolArgs *parsed = [OOToolArgs new];
    NSString *invalid = ParseArgs(tool, args, parsed);
    if (invalid) return [self result:ToolResult(invalid, YES) id:rid];
    return [self result:[self call:tool args:parsed] id:rid];
  }
  return [self error:kMethodNotFound message:[NSString stringWithFormat:@"Method not found: %@", method] id:rid];
}

- (NSDictionary *)initialize:(NSDictionary *)params {
  NSSet *known = [NSSet setWithObjects:@"2024-11-05", @"2025-03-26", @"2025-06-18", kLatestProtocol, nil];
  NSString *requested = params[@"protocolVersion"];
  NSString *version = [requested isKindOfClass:[NSString class]] && [known containsObject:requested] ? requested : kLatestProtocol;
  return @{
    @"protocolVersion": version,
    @"capabilities": @{@"tools": @{@"listChanged": @NO}},
    @"serverInfo": @{@"name": @"onlineonly", @"title": @"onlineonly (unofficial Dropbox online-only control)", @"version": _version},
    @"instructions": @"Controls which files in the local Dropbox folder are stored on disk versus online-only. Check get_sync_status before changing anything, and never make online-only a folder that programs are actively using.",
  };
}

- (NSDictionary *)call:(OOTool)tool args:(OOToolArgs *)args {
  id<OOBackend> backend = _connector();
  if (!backend) return ToolResult(@"Dropbox is not running on this computer, or it is not the classic client with a ~/Dropbox folder.", YES);
  OOService *service = [[OOService alloc] initWithBackend:backend];
  service.pollInterval = _pollInterval;

  switch (tool) {
    case OOToolGetSyncStatus: return [self statusWith:service args:args];
    case OOToolMakeOnlineOnly: return [self apply:OOTargetOnlineOnly with:service args:args];
    case OOToolMakeAvailableOffline: return [self apply:OOTargetOffline with:service args:args];
  }
}

- (NSDictionary *)statusWith:(OOService *)service args:(OOToolArgs *)args {
  NSMutableArray<OOStatusReport *> *reports = [NSMutableArray new];
  BOOL anyError = NO;
  for (NSString *p in args.paths) {
    OOStatusReport *r = args.includeChildren ? [service statusOf:p childLimit:kChildLimit] : [service statusOf:p];
    anyError = anyError || r.error;
    [reports addObject:r];
  }
  return ToolResult(OOResultsJSON(reports), anyError);
}

- (NSDictionary *)apply:(OOTarget)target with:(OOService *)service args:(OOToolArgs *)args {
  NSArray<OOApplyResult *> *results = [service apply:target paths:args.paths wait:args.wait timeout:args.timeout];
  BOOL anyFailed = NO;
  for (OOApplyResult *r in results) anyFailed = anyFailed || r.outcome == OOOutcomeFailed;
  return ToolResult(OOResultsJSON(results), anyFailed);
}

- (NSString *)result:(id)result id:(id)rid {
  return Serialize(@{@"jsonrpc": @"2.0", @"id": rid, @"result": result});
}

- (NSString *)error:(int)code message:(NSString *)message id:(id)rid {
  return Serialize(@{@"jsonrpc": @"2.0", @"id": rid, @"error": @{@"code": @(code), @"message": message}});
}

- (int)runStdio {
  signal(SIGPIPE, SIG_IGN);
  char *buf = NULL;
  size_t cap = 0;
  ssize_t n;
  while ((n = getline(&buf, &cap, stdin)) > 0) {
    @autoreleasepool {
      NSString *raw = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
      NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (raw && !line.length) continue;
      NSString *response = [self handleLine:line ?: @""];
      if (!response) continue;
      if (fprintf(stdout, "%s\n", response.UTF8String) < 0 || fflush(stdout) != 0) break;
    }
  }
  free(buf);
  return 0;
}

@end
