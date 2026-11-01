#import "OOService.h"
#import "OOJob.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

NSString *OOResolvePath(NSString *path, NSString **error) {
  char buf[PATH_MAX];
  if (!realpath(path.stringByExpandingTildeInPath.fileSystemRepresentation, buf)) {
    if (error) *error = @(strerror(errno));
    return nil;
  }
  return @(buf);
}

@implementation OOService {
  id<OOBackend> _backend;
}

- (instancetype)initWithBackend:(id<OOBackend>)backend {
  if ((self = [super init])) {
    _backend = backend;
    _pollInterval = 1;
    _resendInterval = 15;
    _settleTimeout = 30;
  }
  return self;
}

- (OOStatusReport *)reportOfResolved:(NSString *)path {
  OOStatus status;
  NSString *err;
  if (![_backend status:&status of:path error:&err]) return [OOStatusReport path:path error:err];
  return [OOStatusReport path:path status:status];
}

- (OOStatusReport *)statusOf:(NSString *)path {
  NSString *err;
  NSString *p = OOResolvePath(path, &err);
  return p ? [self reportOfResolved:p] : [OOStatusReport path:path error:err];
}

- (OOStatusReport *)statusOf:(NSString *)path childLimit:(NSUInteger)limit {
  OOStatusReport *r = [self statusOf:path];
  BOOL isDir = NO;
  if (r.error || ![[NSFileManager defaultManager] fileExistsAtPath:r.path isDirectory:&isDir] || !isDir) return r;
  return [OOStatusReport path:r.path status:r.status children:[self childrenOf:r.path limit:limit]];
}

- (OOListing *)childrenOf:(NSString *)dir limit:(NSUInteger)limit {
  NSString *err;
  NSString *p = OOResolvePath(dir, &err);
  if (!p) return [OOListing error:err];
  NSError *e;
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:&e];
  if (!names) return [OOListing error:e.localizedDescription];
  NSMutableArray *entries = [NSMutableArray new];
  for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
    // Dot files and the Finder's "Icon\r" folder-icon file are not user content.
    if ([name hasPrefix:@"."] || [name isEqualToString:@"Icon\r"]) continue;
    if (entries.count == limit) return [OOListing entries:entries truncated:YES];
    NSString *child = [p stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:child isDirectory:&isDir];
    [entries addObject:[OOEntry name:name directory:isDir report:[self reportOfResolved:child]]];
  }
  return [OOListing entries:entries truncated:NO];
}

- (NSArray<OOApplyResult *> *)apply:(OOTarget)target
                              paths:(NSArray<NSString *> *)paths
                               wait:(BOOL)wait
                            timeout:(NSTimeInterval)timeout {
  OOApplyPolicy policy = {.target = target, .wait = wait, .resendInterval = _resendInterval};
  NSMutableArray<OOJob *> *jobs = [NSMutableArray new];
  for (NSString *path in paths) {
    NSString *err;
    NSString *p = OOResolvePath(path, &err);
    [jobs addObject:p ? [OOJob unsent:p] : [OOJob path:path failure:err]];
  }

  // Without wait, a path still syncing is held at most settleTimeout before it is pending.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait ? timeout : MIN(timeout, _settleTimeout)];
  for (;;) {
    BOOL open = NO;
    for (NSUInteger i = 0; i < jobs.count; i++) {
      if (jobs[i].phase == OOJobFinal) continue;
      jobs[i] = [self poll:jobs[i] policy:policy];
      open = open || jobs[i].phase != OOJobFinal;
    }
    if (!open) break;
    if (deadline.timeIntervalSinceNow <= 0) {
      for (NSUInteger i = 0; i < jobs.count; i++) jobs[i] = [jobs[i] next:[OOJobEvent timedOut] policy:policy request:NULL];
      break;
    }
    [NSThread sleepForTimeInterval:MIN(_pollInterval, MAX(deadline.timeIntervalSinceNow, 0))];
  }

  NSMutableArray<OOApplyResult *> *results = [NSMutableArray new];
  for (OOJob *job in jobs) [results addObject:job.result];
  return results;
}

// One status read, and the request it calls for.
- (OOJob *)poll:(OOJob *)job policy:(OOApplyPolicy)policy {
  OOStatus status;
  NSString *err;
  OOJobEvent *read = [_backend status:&status of:job.path error:&err] ? [OOJobEvent polledStatus:status at:[NSDate date]]
                                                                      : [OOJobEvent polledError:err];
  BOOL request = NO;
  job = [job next:read policy:policy request:&request];
  if (!request) return job;
  err = nil;
  OORequestResult answer = [_backend request:policy.target for:job.path error:&err];
  return [job next:[OOJobEvent answered:answer error:err at:[NSDate date]] policy:policy request:NULL];
}

@end
