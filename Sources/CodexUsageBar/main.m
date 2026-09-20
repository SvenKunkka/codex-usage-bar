#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString * const CUBErrorDomain = @"io.github.svenkunkka.codex-usage-bar";

static NSURL *FindCodexExecutable(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *override = NSProcessInfo.processInfo.environment[@"CODEX_USAGE_BAR_CLI"];
    if (override.length && [fm isExecutableFileAtPath:override]) {
        return [NSURL fileURLWithPath:override];
    }

    NSString *home = NSHomeDirectory();
    NSArray<NSString *> *candidates = @[
        [home stringByAppendingPathComponent:@".local/bin/codex"],
        [home stringByAppendingPathComponent:@".nvm/current/bin/codex"],
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex",
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/Applications/Codex.app/Contents/MacOS/codex"
    ];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return [NSURL fileURLWithPath:path];
    }
    return nil;
}

static NSDictionary *ParseRateLimitResponse(NSDictionary *response, NSError **error) {
    NSDictionary *serverError = response[@"error"];
    if ([serverError isKindOfClass:NSDictionary.class]) {
        NSString *message = serverError[@"message"] ?: @"Codex 返回未知错误";
        if (error) *error = [NSError errorWithDomain:CUBErrorDomain code:2
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
        return nil;
    }

    NSDictionary *result = response[@"result"];
    if (![result isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:CUBErrorDomain code:3
                                             userInfo:@{NSLocalizedDescriptionKey: @"Codex 响应缺少 result"}];
        return nil;
    }

    NSMutableArray<NSDictionary *> *buckets = NSMutableArray.array;
    NSDictionary *byID = result[@"rateLimitsByLimitId"];
    if ([byID isKindOfClass:NSDictionary.class]) {
        [byID enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *value, BOOL *stop) {
            if (![value isKindOfClass:NSDictionary.class]) return;
            NSMutableDictionary *bucket = value.mutableCopy;
            if (![bucket[@"limitId"] isKindOfClass:NSString.class]) bucket[@"limitId"] = key;
            [buckets addObject:bucket.copy];
        }];
    } else {
        NSDictionary *legacy = result[@"rateLimits"];
        if ([legacy isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *bucket = legacy.mutableCopy;
            if (![bucket[@"limitId"] isKindOfClass:NSString.class]) bucket[@"limitId"] = @"codex";
            [buckets addObject:bucket.copy];
        }
    }

    if (!buckets.count) {
        if (error) *error = [NSError errorWithDomain:CUBErrorDomain code:4
                                             userInfo:@{NSLocalizedDescriptionKey: @"没有可显示的额度窗口"}];
        return nil;
    }

    [buckets sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *aID = a[@"limitId"] ?: @"";
        NSString *bID = b[@"limitId"] ?: @"";
        if ([aID isEqualToString:@"codex"] && ![bID isEqualToString:@"codex"]) return NSOrderedAscending;
        if (![aID isEqualToString:@"codex"] && [bID isEqualToString:@"codex"]) return NSOrderedDescending;
        return [aID localizedStandardCompare:bID];
    }];
    return @{ @"buckets": buckets.copy, @"fetchedAt": NSDate.date };
}

static NSDictionary *FetchRateLimits(NSError **error) {
    NSURL *executable = FindCodexExecutable();
    if (!executable) {
        if (error) *error = [NSError errorWithDomain:CUBErrorDomain code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"未找到 Codex CLI。请先安装或打开 Codex。"
        }];
        return nil;
    }

    NSTask *task = NSTask.new;
    task.executableURL = executable;
    task.arguments = @[@"app-server", @"--stdio"];
    NSPipe *input = NSPipe.pipe;
    NSPipe *output = NSPipe.pipe;
    NSPipe *errors = NSPipe.pipe;
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = errors;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = launchError;
        return nil;
    }

    NSArray *messages = @[
        @{ @"method": @"initialize", @"id": @1, @"params": @{
            @"clientInfo": @{ @"name": @"codex_usage_bar", @"title": @"Codex Usage Bar", @"version": @"0.1.0" }
        }},
        @{ @"method": @"initialized", @"params": @{} },
        @{ @"method": @"account/rateLimits/read", @"id": @2 }
    ];
    for (NSDictionary *message in messages) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
        [input.fileHandleForWriting writeData:json];
        [input.fileHandleForWriting writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }

    __block BOOL completed = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!completed && task.running) [task terminate];
    });

    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *parsed = nil;
    while (task.running && !parsed) {
        NSData *data = output.fileHandleForReading.availableData;
        if (!data.length) break;
        [buffer appendData:data];

        while (YES) {
            const uint8_t *bytes = buffer.bytes;
            NSUInteger newline = NSNotFound;
            for (NSUInteger i = 0; i < buffer.length; i++) {
                if (bytes[i] == '\n') { newline = i; break; }
            }
            if (newline == NSNotFound) break;
            NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline)];
            [buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
            NSDictionary *object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([object[@"id"] integerValue] == 2) {
                parsed = ParseRateLimitResponse(object, error);
                break;
            }
        }
    }
    completed = YES;
    if (task.running) [task terminate];
    [input.fileHandleForWriting closeFile];

    if (!parsed && (!error || !*error)) {
        NSData *errorData = errors.fileHandleForReading.availableData;
        NSString *message = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        message = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!message.length) message = @"读取 Codex 用量超时或未返回数据。";
        if (error) *error = [NSError errorWithDomain:CUBErrorDomain code:5
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return parsed;
}

static double RemainingPercent(NSDictionary *window) {
    NSNumber *used = window[@"usedPercent"];
    return MAX(0, MIN(100, 100.0 - used.doubleValue));
}

@interface CodexUsageBarDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL refreshing;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@end

@implementation CodexUsageBarDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"Codex …";
    self.statusItem.button.toolTip = @"Codex 剩余用量";
    [self showLoadingMenu];
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(refresh)
                                                userInfo:nil repeats:YES];
}

- (void)showLoadingMenu {
    NSMenu *menu = NSMenu.new;
    NSMenuItem *loading = [[NSMenuItem alloc] initWithTitle:@"正在读取 Codex 用量…" action:nil keyEquivalent:@""];
    loading.enabled = NO;
    [menu addItem:loading];
    [menu addItem:NSMenuItem.separatorItem];
    [self addControlsToMenu:menu];
    self.statusItem.menu = menu;
}

- (void)refresh {
    if (self.refreshing) return;
    self.refreshing = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *snapshot = FetchRateLimits(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.refreshing = NO;
            if (snapshot) [weakSelf renderSnapshot:snapshot];
            else [weakSelf renderError:error];
        });
    });
}

- (void)renderSnapshot:(NSDictionary *)snapshot {
    NSArray<NSDictionary *> *buckets = snapshot[@"buckets"];
    NSDictionary *preferred = nil;
    for (NSDictionary *bucket in buckets) {
        if ([bucket[@"limitId"] isEqual:@"codex"]) { preferred = bucket[@"primary"]; break; }
    }
    if (!preferred) preferred = buckets.firstObject[@"primary"];
    self.statusItem.button.title = preferred
        ? [NSString stringWithFormat:@"Codex %.0f%%", RemainingPercent(preferred)]
        : @"Codex --";

    NSMenu *menu = NSMenu.new;
    [buckets enumerateObjectsUsingBlock:^(NSDictionary *bucket, NSUInteger idx, BOOL *stop) {
        if (buckets.count > 1) {
            NSString *name = bucket[@"limitName"] ?: bucket[@"limitId"];
            NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
            heading.enabled = NO;
            [menu addItem:heading];
        }
        [self addWindow:bucket[@"primary"] fallbackTitle:@"主要额度" toMenu:menu];
        [self addWindow:bucket[@"secondary"] fallbackTitle:@"次要额度" toMenu:menu];
        if (idx + 1 < buckets.count) [menu addItem:NSMenuItem.separatorItem];
    }];

    [menu addItem:NSMenuItem.separatorItem];
    NSString *updatedTitle = [NSString stringWithFormat:@"更新于 %@", [self.timeFormatter stringFromDate:snapshot[@"fetchedAt"]]];
    NSMenuItem *updated = [[NSMenuItem alloc] initWithTitle:updatedTitle action:nil keyEquivalent:@""];
    updated.enabled = NO;
    [menu addItem:updated];
    [self addControlsToMenu:menu];
    self.statusItem.menu = menu;
}

- (void)renderError:(NSError *)error {
    self.statusItem.button.title = @"Codex --";
    NSMenu *menu = NSMenu.new;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:error.localizedDescription ?: @"无法读取用量"
                                                  action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
    [menu addItem:NSMenuItem.separatorItem];
    [self addControlsToMenu:menu];
    self.statusItem.menu = menu;
}

- (void)addWindow:(NSDictionary *)window fallbackTitle:(NSString *)fallbackTitle toMenu:(NSMenu *)menu {
    if (![window isKindOfClass:NSDictionary.class]) return;
    NSString *title = [self titleForMinutes:[window[@"windowDurationMins"] integerValue]] ?: fallbackTitle;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:
        [NSString stringWithFormat:@"%@：剩余 %.0f%%", title, RemainingPercent(window)]
                                                  action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];

    NSNumber *resetTimestamp = window[@"resetsAt"];
    if ([resetTimestamp isKindOfClass:NSNumber.class]) {
        NSDate *resetDate = [NSDate dateWithTimeIntervalSince1970:resetTimestamp.doubleValue];
        NSString *resetTitle = [NSString stringWithFormat:@"    重置：%@", [self.dateFormatter stringFromDate:resetDate]];
        NSMenuItem *reset = [[NSMenuItem alloc] initWithTitle:resetTitle action:nil keyEquivalent:@""];
        reset.enabled = NO;
        [menu addItem:reset];
    }
}

- (void)addControlsToMenu:(NSMenu *)menu {
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"立即刷新" action:@selector(refresh) keyEquivalent:@"r"];
    refresh.target = self;
    [menu addItem:refresh];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"登录时启动" action:@selector(toggleLaunchAtLogin:)
                                             keyEquivalent:@""];
    login.target = self;
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 Codex Usage Bar" action:@selector(quit)
                                            keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = service.status == SMAppServiceStatusEnabled
        ? [service unregisterAndReturnError:&error]
        : [service registerAndReturnError:&error];
    if (success) {
        sender.state = service.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    } else {
        NSAlert *alert = NSAlert.new;
        alert.messageText = @"无法修改登录启动设置";
        alert.informativeText = error.localizedDescription ?: @"请在系统设置中检查登录项权限。";
        [alert runModal];
    }
}

- (void)quit { [NSApplication.sharedApplication terminate:nil]; }

- (NSString *)titleForMinutes:(NSInteger)minutes {
    if (minutes <= 0) return nil;
    if (minutes % 10080 == 0) return [NSString stringWithFormat:@"%ld 周额度", (long)(minutes / 10080)];
    if (minutes % 1440 == 0) return [NSString stringWithFormat:@"%ld 天额度", (long)(minutes / 1440)];
    if (minutes % 60 == 0) return [NSString stringWithFormat:@"%ld 小时额度", (long)(minutes / 60)];
    return [NSString stringWithFormat:@"%ld 分钟额度", (long)minutes];
}

- (NSDateFormatter *)dateFormatter {
    if (!_dateFormatter) {
        _dateFormatter = NSDateFormatter.new;
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        _dateFormatter.dateFormat = @"M月d日 HH:mm";
    }
    return _dateFormatter;
}

- (NSDateFormatter *)timeFormatter {
    if (!_timeFormatter) {
        _timeFormatter = NSDateFormatter.new;
        _timeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        _timeFormatter.dateFormat = @"HH:mm:ss";
    }
    return _timeFormatter;
}
@end

static int RunSelfTest(void) {
    NSDictionary *sample = @{
        @"id": @2,
        @"result": @{ @"rateLimitsByLimitId": @{
            @"codex_other": @{ @"limitId": @"codex_other", @"primary": @{ @"usedPercent": @42, @"windowDurationMins": @60 } },
            @"codex": @{ @"limitId": @"codex", @"primary": @{ @"usedPercent": @25.5, @"windowDurationMins": @300 },
                           @"secondary": @{ @"usedPercent": @60, @"windowDurationMins": @10080 } }
        }}
    };
    NSError *error = nil;
    NSDictionary *snapshot = ParseRateLimitResponse(sample, &error);
    NSArray *buckets = snapshot[@"buckets"];
    if (error || buckets.count != 2 || ![buckets.firstObject[@"limitId"] isEqual:@"codex"] ||
        fabs(RemainingPercent(buckets.firstObject[@"primary"]) - 74.5) > 0.001) {
        fprintf(stderr, "Self-test failed\n");
        return 1;
    }
    printf("Self-test passed\n");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return RunSelfTest();
        if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
            NSError *error = nil;
            NSDictionary *snapshot = FetchRateLimits(&error);
            if (!snapshot) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot[@"buckets"] options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }

        NSApplication *app = NSApplication.sharedApplication;
        CodexUsageBarDelegate *delegate = CodexUsageBarDelegate.new;
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
