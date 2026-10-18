#import "OOBackend.h"

NS_ASSUME_NONNULL_BEGIN

// Returns a fresh backend per tool call (so a Dropbox restart is picked up), or nil when
// Dropbox is not running.
typedef id<OOBackend> _Nullable (^OOConnector)(void);

// MCP server over stdio: newline-delimited JSON-RPC 2.0, tools only.
@interface OOMCPServer : NSObject

- (instancetype)initWithConnector:(OOConnector)connector version:(NSString *)version;
- (instancetype)init NS_UNAVAILABLE;

// Poll interval for waiting tool calls; tests set it to 0.
@property NSTimeInterval pollInterval;

// One JSON-RPC message in, the serialized response out; nil when no response is due
// (notifications, stray responses).
- (nullable NSString *)handleLine:(NSString *)line;

// Serves stdin/stdout until EOF. Returns the process exit code.
- (int)runStdio;

@end

NS_ASSUME_NONNULL_END
