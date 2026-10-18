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

static NSArray *Tools(void) {
  return @[
    @{
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
    },
    @{
      @"name": @"make_online_only",
      @"title": @"Make online-only",
      @"description": @"Free disk space by making files or folders online-only: Dropbox deletes the local copies, leaving 0-byte placeholders, and keeps the content in the cloud. Folders apply recursively. Programs that read a placeholder get an empty file, so do not use this on anything in active use (code checkouts, app data, files a running program needs). Reverse it with make_available_offline.",
      @"inputSchema": ApplySchema(),
      @"annotations": @{@"readOnlyHint": @NO, @"destructiveHint": @YES, @"idempotentHint": @YES, @"openWorldHint": @NO},
    },
    @{
      @"name": @"make_available_offline",
      @"title": @"Make available offline",
      @"description": @"Download files or folders from Dropbox and keep them on this computer (Dropbox's \"Make available offline\"). Folders apply recursively; a large folder can take a while and use a lot of disk space.",
      @"inputSchema": ApplySchema(),
      @"annotations": @{@"readOnlyHint": @NO, @"destructiveHint": @NO, @"idempotentHint": @YES, @"openWorldHint": @NO},
    },
  ];
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
    NSString *name = params[@"name"];
    id args = params[@"arguments"] ?: @{};
    if (![name isKindOfClass:[NSString class]] || ![[Tools() valueForKey:@"name"] containsObject:name])
      return [self error:kInvalidParams message:[NSString stringWithFormat:@"Unknown tool: %@", name] id:rid];
    if (![args isKindOfClass:[NSDictionary class]])
      return [self result:ToolResult(@"arguments must be an object", YES) id:rid];
    return [self result:[self callTool:name args:args] id:rid];
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

- (NSDictionary *)callTool:(NSString *)name args:(NSDictionary *)args {
  NSArray *paths = args[@"paths"];
  BOOL validPaths = [paths isKindOfClass:[NSArray class]] && paths.count > 0;
  for (id p in validPaths ? paths : @[]) validPaths = validPaths && [p isKindOfClass:[NSString class]] && [p length] > 0;
  if (!validPaths) return ToolResult(@"paths must be a non-empty array of path strings", YES);

  id<OOBackend> backend = _connector();
  if (!backend) return ToolResult(@"Dropbox is not running on this computer, or it is not the classic client with a ~/Dropbox folder.", YES);
  OOService *service = [[OOService alloc] initWithBackend:backend];
  service.pollInterval = _pollInterval;

  if ([name isEqualToString:@"get_sync_status"]) {
    BOOL children = [args[@"include_children"] respondsToSelector:@selector(boolValue)] && [args[@"include_children"] boolValue];
    NSMutableArray *out = [NSMutableArray new];
    BOOL anyError = NO;
    for (NSString *p in paths) {
      NSMutableDictionary *r = [[service statusOf:p] mutableCopy];
      anyError = anyError || r[@"error"] != nil;
      BOOL isDir = NO;
      if (children && !r[@"error"] && [[NSFileManager defaultManager] fileExistsAtPath:r[@"path"] isDirectory:&isDir] && isDir) {
        BOOL truncated = NO;
        NSString *err;
        NSArray *kids = [service childrenOf:r[@"path"] limit:kChildLimit truncated:&truncated error:&err];
        if (kids) {
          r[@"children"] = kids;
          if (truncated) r[@"children_truncated"] = @YES;
        } else {
          r[@"children_error"] = err;
        }
      }
      [out addObject:r];
    }
    return ToolResult(@{@"results": out}, anyError);
  }

  OOTarget target = [name isEqualToString:@"make_online_only"] ? OOTargetOnlineOnly : OOTargetOffline;
  BOOL wait = [args[@"wait"] respondsToSelector:@selector(boolValue)] ? [args[@"wait"] boolValue] : YES;
  NSTimeInterval timeout = [args[@"timeout_seconds"] respondsToSelector:@selector(doubleValue)] ? [args[@"timeout_seconds"] doubleValue] : kDefaultTimeout;
  timeout = MAX(0, MIN(timeout, kMaxTimeout));
  NSArray *results = [service apply:target paths:paths wait:wait timeout:timeout];
  BOOL anyFailed = [[results valueForKey:@"result"] containsObject:OOResultFailed];
  return ToolResult(@{@"results": results}, anyFailed);
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
