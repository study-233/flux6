// Hardened P0 host: links only system frameworks and delegates Sparkle loading
// to an ordinary-user helper. This fixture has no privileged-service interface.
#import <AppKit/AppKit.h>
#import <unistd.h>

@interface HostDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSTask *agent;
@end

@implementation HostDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSDictionary *entry = @{@"event": @"launched", @"version": version, @"pid": @(getpid()), @"role": @"hardened-host"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
    NSString *resultPath = [bundle objectForInfoDictionaryKey:@"ProbeResultPath"];
    FILE *file = fopen(resultPath.fileSystemRepresentation, "a");
    if (!file) exit(10);
    fwrite(json.bytes, 1, json.length, file);
    fputc('\n', file);
    fclose(file);
    if ([version isEqualToString:@"2"]) {
        [NSApp terminate:nil];
        return;
    }
    self.agent = [NSTask new];
    self.agent.executableURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/FreeV6UpdateAgent.app/Contents/MacOS/UpdateProbe"];
    NSError *error = nil;
    if (![self.agent launchAndReturnError:&error]) {
        fprintf(stderr, "Cannot launch test agent: %s\n", error.description.UTF8String);
        exit(11);
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (geteuid() == 0) return 12;
        NSApplication *application = [NSApplication sharedApplication];
        HostDelegate *delegate = [HostDelegate new];
        application.delegate = delegate;
        [application run];
        return 0;
    }
}
