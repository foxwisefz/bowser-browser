#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

// Standalone diagnostic declarations, checked with respondsToSelector before use.
@interface WKPreferences (PushProbe)
- (void)_setPushAPIEnabled:(BOOL)value;
- (void)_setNotificationsEnabled:(BOOL)value;
- (void)_setNotificationEventEnabled:(BOOL)value;
@end
@interface WKWebsiteDataStore (PushProbe)
- (void)set_delegate:(id)delegate;
- (void)_setServiceWorkerOverridePreferences:(WKPreferences *)preferences;
- (void)_processPushMessage:(NSDictionary *)message completionHandler:(void (^)(bool))completion;
- (void)_processPersistentNotificationClick:(NSDictionary *)message completionHandler:(void (^)(bool))completion;
@end

static void record(NSString *event, id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"event":event, @"value":value ?: [NSNull null]} options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

@interface Probe : NSObject <NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property WKWebsiteDataStore *store;
@property WKWebView *view;
@property NSWindow *window;
@property NSString *origin;
@property BOOL started;
@end
@implementation Probe
- (NSDictionary *)notificationPermissionsForWebsiteDataStore:(WKWebsiteDataStore *)store { return @{self.origin:@YES}; }
- (void)_webView:(WKWebView *)view requestNotificationPermissionForSecurityOrigin:(WKSecurityOrigin *)origin decisionHandler:(void (^)(BOOL))completion {
    record(@"permission_callback", origin.host);
    completion([origin.host isEqualToString:@"127.0.0.1"]);
}
- (void)websiteDataStore:(WKWebsiteDataStore *)store showNotification:(id)notification {
    // Capture native notification request; never present a real OS notification.
    record(@"native_notification", [notification valueForKey:@"title"]);
    if ([notification respondsToSelector:NSSelectorFromString(@"userInfo")] &&
        [store respondsToSelector:@selector(_processPersistentNotificationClick:completionHandler:)]) {
        [store _processPersistentNotificationClick:[notification valueForKey:@"userInfo"] completionHandler:^(bool ok) {
            record(@"native_click_result", @(ok));
        }];
    }
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.origin = NSProcessInfo.processInfo.environment[@"PROBE_ORIGIN"];
    self.store = [WKWebsiteDataStore dataStoreForIdentifier:NSUUID.UUID];
    record(@"webkit", [[NSBundle bundleForClass:WKWebView.class] objectForInfoDictionaryKey:@"CFBundleVersion"]);
    for (NSString *name in @[@"set_delegate:", @"_processPushMessage:completionHandler:", @"_setServiceWorkerOverridePreferences:"]) {
        if (![self.store respondsToSelector:NSSelectorFromString(name)]) { record(@"missing_selector", name); exit(2); }
    }
    [self.store set_delegate:self];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = self.store;
    for (NSString *name in @[@"_setPushAPIEnabled:", @"_setNotificationsEnabled:", @"_setNotificationEventEnabled:"]) {
        SEL selector = NSSelectorFromString(name);
        if (![config.preferences respondsToSelector:selector]) { record(@"missing_selector", name); exit(2); }
        ((void (*)(id, SEL, BOOL))[config.preferences methodForSelector:selector])(config.preferences, selector, YES);
    }
    [self.store _setServiceWorkerOverridePreferences:config.preferences];
    [config.userContentController addScriptMessageHandler:self name:@"probe"];
    self.view = [[WKWebView alloc] initWithFrame:NSMakeRect(0,0,500,300) configuration:config];
    self.view.navigationDelegate = self; self.view.UIDelegate = self;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,500,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Bowser Push Probe"; self.window.releasedWhenClosed = NO;
    self.window.contentView = self.view;
    [self.window orderBack:nil];
    [self.view loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[self.origin stringByAppendingString:@"/"]]]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ record(@"finished", @YES); [NSApp terminate:nil]; });
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    record(@"page", message.body);
    if ([message.body isKindOfClass:NSDictionary.class] && [message.body[@"event"] isEqual:@"ready"] && !self.started) {
        self.started = YES;
        // Destroy the actual WKWebView, not just hide it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.view.configuration.userContentController removeScriptMessageHandlerForName:@"probe"];
            [self.view stopLoading]; self.window.contentView = nil; self.view = nil; [self.window close];
            record(@"tab_destroyed", @YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                NSDictionary *payload = @{@"WebKitPushRegistrationURL":[NSURL URLWithString:[self.origin stringByAppendingString:@"/"]],
                    @"WebKitPushData":[@"bowser-proof-payload" dataUsingEncoding:NSUTF8StringEncoding],
                    @"WebKitPushPartition":@"", @"WebKitNotificationPayload":[NSNull null]};
                NSMutableDictionary *missing = [payload mutableCopy];
                missing[@"WebKitPushRegistrationURL"] = [NSURL URLWithString:[self.origin stringByAppendingString:@"/unregistered/"]];
                missing[@"WebKitPushData"] = [@"wrong-scope-payload" dataUsingEncoding:NSUTF8StringEncoding];
                [self.store _processPushMessage:missing completionHandler:^(bool ok) {
                    record(@"unregistered_scope_result", @(ok));
                    WKWebsiteDataStore *other = [WKWebsiteDataStore dataStoreForIdentifier:NSUUID.UUID];
                    NSMutableDictionary *otherPayload = [payload mutableCopy];
                    otherPayload[@"WebKitPushData"] = [@"wrong-store-payload" dataUsingEncoding:NSUTF8StringEncoding];
                    [other _processPushMessage:otherPayload completionHandler:^(bool otherOK) {
                        record(@"other_store_result", @(otherOK));
                        [self.store _processPushMessage:payload completionHandler:^(bool pushed) { record(@"push_dispatch_result", @(pushed)); }];
                    }];
                }];
            });
        });
    }
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { record(@"navigation_error", error.description); }
@end
int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Probe *probe = [Probe new]; app.delegate = probe; [app run];
    }
}
