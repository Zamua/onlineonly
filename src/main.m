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
      NSMutableArray<OOStatusReport *> *reports = [NSMutableArray new];
      for (NSString *p in paths) {
        OOStatusReport *r = [service statusOf:p];
        [reports addObject:r];
        if (r.error) rc = 1;
        if (json) continue;
        if (r.error) fprintf(stderr, "onlineonly: %s: %s\n", p.UTF8String, r.error.UTF8String);
        else printf("%-12s %s\n", OOStatusName(r.status).UTF8String, r.path.UTF8String);
      }
      if (json) PrintJSON(OOResultsJSON(reports));
    } else if ([cmd isEqualToString:@"ls"]) {
      if (paths.count != 1) Usage();
      OOListing *listing = [service childrenOf:paths[0] limit:NSUIntegerMax];
      if (listing.error) {
        fprintf(stderr, "onlineonly: %s: %s\n", paths[0].UTF8String, listing.error.UTF8String);
        return 1;
      }
      for (OOEntry *e in listing.entries) {
        if (e.report.error) rc = 1;
        if (json) continue;
        if (e.report.error) fprintf(stderr, "onlineonly: %s: %s\n", e.report.path.UTF8String, e.report.error.UTF8String);
        else printf("%-12s %s%s\n", OOStatusName(e.report.status).UTF8String, e.name.UTF8String, e.directory ? "/" : "");
      }
      if (json) PrintJSON(OOResultsJSON(listing.entries));
    } else if ([cmd isEqualToString:@"online"] || [cmd isEqualToString:@"offline"]) {
      OOTarget target = [cmd isEqualToString:@"online"] ? OOTargetOnlineOnly : OOTargetOffline;
      NSArray<OOApplyResult *> *results = [service apply:target paths:paths wait:wait timeout:timeout];
      for (OOApplyResult *r in results) {
        if (r.outcome == OOOutcomeFailed || r.outcome == OOOutcomePending) rc = 1;
        if (json) continue;
        const char *path = r.path.UTF8String, *status = OOStatusName(r.status).UTF8String;
        switch (r.outcome) {
          case OOOutcomeFailed: fprintf(stderr, "onlineonly: %s: %s\n", path, r.error.UTF8String); break;
          case OOOutcomePending: fprintf(stderr, "onlineonly: %s: timed out waiting (status: %s)\n", path, status); break;
          case OOOutcomeAlready: printf("already %s: %s\n", status, path); break;
          case OOOutcomeDone: printf("%-12s %s\n", status, path); break;
          case OOOutcomeRequested: printf("requested %s: %s\n", cmd.UTF8String, path); break;
        }
      }
      if (json) PrintJSON(OOResultsJSON(results));
    } else {
      Usage();
    }
    return rc;
  }
}
