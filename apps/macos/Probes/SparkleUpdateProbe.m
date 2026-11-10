// Isolated P0 fixture, never shipped in Flux6. A test user driver exercises
// Sparkle's actual downloader, signature verifier, installer and relauncher.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <unistd.h>

static void Record(NSString *event, NSDictionary *details) {
    NSMutableDictionary *entry = [details mutableCopy] ?: [NSMutableDictionary dictionary];
    entry[@"event"] = event;
    entry[@"pid"] = @(getpid());
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
    NSString *path = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ProbeResultPath"];
    FILE *file = fopen(path.fileSystemRepresentation, "a");
    if (!file) exit(10);
    fwrite(json.bytes, 1, json.length, file);
    fputc('\n', file);
    fclose(file);
}

static void RecordError(NSError *error) {
    NSMutableArray *causes = [NSMutableArray array];
    NSError *cause = error;
    for (int depth = 0; cause != nil && depth < 8; depth++) {
        [causes addObject:@{@"domain": cause.domain, @"code": @(cause.code)}];
        id next = cause.userInfo[NSUnderlyingErrorKey];
        cause = [next isKindOfClass:[NSError class]] ? next : nil;
    }
    Record(@"error", @{@"domain": error.domain, @"code": @(error.code), @"detail": error.description, @"causes": causes});
}

@interface ProbeDriver : NSObject <NSApplicationDelegate, SPUUserDriver>
@property(nonatomic, strong) SPUUpdater *updater;
@end

@implementation ProbeDriver
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSBundle *agent = [NSBundle mainBundle];
    BOOL externalHost = [[agent objectForInfoDictionaryKey:@"ProbeExternalHost"] boolValue];
    NSURL *hostURL = agent.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSBundle *bundle = externalHost ? [NSBundle bundleWithURL:hostURL] : agent;
    if (bundle == nil) exit(13);
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    Record(externalHost ? @"agent-launched" : @"launched", @{@"version": version});
    if ([[bundle objectForInfoDictionaryKey:@"ProbeLoadOnly"] boolValue] || [version isEqualToString:@"2"]) {
        [NSApp terminate:nil];
        return;
    }
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self delegate:nil];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) {
        RecordError(error);
        exit(11);
    }
    [self.updater checkForUpdates];
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { Record(@"checking", nil); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    Record(@"found", @{@"version": item.versionString});
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self showUpdaterError:error acknowledgement:acknowledgement];
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    RecordError(error);
    acknowledgement();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { Record(@"downloading", nil); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { Record(@"extracting", nil); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    Record(@"ready", nil);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    Record(@"installing", @{@"terminated": @(terminated)});
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    Record(@"installed", @{@"relaunched": @(relaunched)});
    acknowledgement();
    [NSApp terminate:nil];
}
- (void)dismissUpdateInstallation { Record(@"dismissed", nil); }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (geteuid() == 0) return 12;
        NSApplication *application = [NSApplication sharedApplication];
        ProbeDriver *driver = [ProbeDriver new];
        application.delegate = driver;
        [application run];
        return 0;
    }
}
