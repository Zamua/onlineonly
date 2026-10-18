#import <Foundation/Foundation.h>
#import "OODropbox.h"
#import "OOMCP.h"
#import "OOService.h"
#import "version.h"
#include <sysexits.h>

static void Usage(void) {
  fprintf(stderr,
          "usage: onlineonly status  [--json] <path>...\n"
          "       onlineonly ls      [--json] <folder>\n"
          "       onlineonly online  [-w] [-t secs] [--json] <path>...   make online-only\n"
          "       onlineonly offline [-w] [-t secs] [--json] <path>...   make available offline\n"
          "       onlineonly roots                                       list Dropbox sync roots\n"
          "       onlineonly mcp                                         run the MCP server on stdio\n"
          "       onlineonly --version\n"
          "\n"
          "  -w       wait until Dropbox reports the new state\n"
          "  -t secs  how long -w waits (default 600)\n"
          "  --json   machine-readable output\n");
  exit(EX_USAGE);
}

static void PrintJSON(id obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                              options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes | NSJSONWritingSortedKeys
                                                error:NULL];
  printf("%s\n", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String);
}

static OODropbox *ConnectOrExit(void) {
  OODropbox *d = [OODropbox connect];
  if (!d) {
    fprintf(stderr, "onlineonly: cannot reach Dropbox (is the desktop app running?)\n");
    exit(EX_UNAVAILABLE);
  }
  return d;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) Usage();
    NSString *cmd = @(argv[1]);
    if ([cmd isEqualToString:@"--version"] || [cmd isEqualToString:@"version"]) {
      printf("onlineonly %s\n", ONLINEONLY_VERSION);
      return 0;
    }
    if ([cmd isEqualToString:@"mcp"]) {
      OOMCPServer *server = [[OOMCPServer alloc] initWithConnector:^id<OOBackend> { return [OODropbox connect]; }
                                                           version:@ONLINEONLY_VERSION];
      return [server runStdio];
    }

    BOOL wait = NO, json = NO;
    NSTimeInterval timeout = 600;
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    for (int i = 2; i < argc; i++) {
      NSString *a = @(argv[i]);
      if ([a isEqualToString:@"--"]) {
        for (i++; i < argc; i++) [paths addObject:@(argv[i])];
      } else if ([a isEqualToString:@"-w"] || [a isEqualToString:@"--wait"]) {
        wait = YES;
      } else if ([a isEqualToString:@"--json"]) {
        json = YES;
      } else if ([a isEqualToString:@"-t"] || [a isEqualToString:@"--timeout"]) {
        if (++i >= argc) Usage();
        timeout = atof(argv[i]);
      } else if ([a hasPrefix:@"-"] && a.length > 1) {
        Usage();
      } else {
        [paths addObject:a];
      }
    }

    if ([cmd isEqualToString:@"roots"]) {
      for (NSString *r in [ConnectOrExit() roots]) printf("%s\n", r.UTF8String);
      return 0;
    }
    if (!paths.count) Usage();
    OODropbox *dropbox = ConnectOrExit();
    OOService *service = [[OOService alloc] initWithBackend:dropbox];
    int rc = 0;

    if ([cmd isEqualToString:@"status"]) {
      NSMutableArray *results = [NSMutableArray new];
      for (NSString *p in paths) {
        NSDictionary *r = [service statusOf:p];
        [results addObject:r];
        if (r[@"error"]) {
          rc = 1;
          if (!json) fprintf(stderr, "onlineonly: %s: %s\n", p.UTF8String, [r[@"error"] UTF8String]);
        } else if (!json) {
          printf("%-12s %s\n", [r[@"status"] UTF8String], [r[@"path"] UTF8String]);
        }
      }
      if (json) PrintJSON(@{@"results": results});
    } else if ([cmd isEqualToString:@"ls"]) {
      if (paths.count != 1) Usage();
      NSString *err;
      NSArray *kids = [service childrenOf:paths[0] limit:NSUIntegerMax truncated:NULL error:&err];
      if (!kids) {
        fprintf(stderr, "onlineonly: %s: %s\n", paths[0].UTF8String, err.UTF8String);
        return 1;
      }
      if (json) PrintJSON(@{@"results": kids});
      for (NSDictionary *k in json ? @[] : kids)
        printf("%-12s %s%s\n", [k[@"status"] UTF8String], [k[@"name"] UTF8String], [k[@"directory"] boolValue] ? "/" : "");
    } else if ([cmd isEqualToString:@"online"] || [cmd isEqualToString:@"offline"]) {
      OOTarget target = [cmd isEqualToString:@"online"] ? OOTargetOnlineOnly : OOTargetOffline;
      NSArray *results = [service apply:target paths:paths wait:wait timeout:timeout];
      for (NSDictionary *r in results) {
        NSString *result = r[@"result"];
        if ([result isEqualToString:OOResultFailed] || [result isEqualToString:OOResultPending]) rc = 1;
        if (json) continue;
        const char *path = [r[@"path"] UTF8String];
        if ([result isEqualToString:OOResultFailed])
          fprintf(stderr, "onlineonly: %s: %s\n", path, [r[@"error"] UTF8String]);
        else if ([result isEqualToString:OOResultPending])
          fprintf(stderr, "onlineonly: %s: timed out waiting (status: %s)\n", path, [r[@"status"] UTF8String]);
        else if ([result isEqualToString:OOResultAlready])
          printf("already %s: %s\n", [r[@"status"] UTF8String], path);
        else if ([result isEqualToString:OOResultDone])
          printf("%-12s %s\n", [r[@"status"] UTF8String], path);
        else
          printf("requested %s: %s\n", cmd.UTF8String, path);
      }
      if (json) PrintJSON(@{@"results": results});
    } else {
      Usage();
    }
    return rc;
  }
}
