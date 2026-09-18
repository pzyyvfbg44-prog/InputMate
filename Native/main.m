#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString *const IMEnabledKey = @"enabled";
static NSString *const IMMapButtonsKey = @"mapSideButtons";
static NSString *const IMAutoScrollKey = @"automaticScrollDirection";
static NSString *const IMCopyButtonKey = @"copyButton";
static NSString *const IMPasteButtonKey = @"pasteButton";

static NSString *IMVersionString(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version ?: @"Development";
}

typedef NS_ENUM(NSInteger, IMScrollSource) {
    IMScrollSourceMouse,
    IMScrollSourceTrackpad,
};

@interface IMEventController : NSObject
@property(nonatomic, copy) void (^stateChanged)(BOOL running);
@property(nonatomic, copy) void (^bindingCaptured)(NSString *key, NSInteger button);
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) BOOL gestureMonitoringAvailable;
@property(nonatomic, copy, nullable, readonly) NSString *capturingKey;
@property(nonatomic, copy, readonly) NSString *lastScrollSummary;
- (void)start;
- (void)stop;
- (void)restart;
- (void)reloadPreferences;
- (void)beginCapturingButtonForKey:(NSString *)key;
- (CGEventRef _Nullable)handleType:(CGEventType)type event:(CGEventRef)event;
@end

static CGEventRef IMEventCallback(CGEventTapProxy proxy,
                                  CGEventType type,
                                  CGEventRef event,
                                  void *userInfo) {
    (void)proxy;
    IMEventController *controller = (__bridge IMEventController *)userInfo;
    return [controller handleType:type event:event];
}

@implementation IMEventController {
    CFMachPortRef _activeTap;
    CFMachPortRef _gestureTap;
    CFRunLoopSourceRef _activeSource;
    CFRunLoopSourceRef _gestureSource;
    NSTimeInterval _lastTouchUptime;
    NSUInteger _touchingFingers;
    IMScrollSource _lastSource;
    NSString *_capturingKey;
    NSString *_lastScrollSummary;
    BOOL _enabled;
    BOOL _mapSideButtons;
    BOOL _automaticScrollDirection;
    BOOL _systemNaturalScrolling;
    NSInteger _copyButton;
    NSInteger _pasteButton;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastTouchUptime = -DBL_MAX;
        _lastSource = IMScrollSourceMouse;
        _lastScrollSummary = @"尚未收到滚动事件";
        [self reloadPreferences];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)running {
    return _activeTap != NULL;
}

- (BOOL)gestureMonitoringAvailable {
    return _gestureTap != NULL;
}

- (NSString *)capturingKey {
    return _capturingKey;
}

- (NSString *)lastScrollSummary {
    return _lastScrollSummary;
}

- (void)beginCapturingButtonForKey:(NSString *)key {
    _capturingKey = [key copy];
    if (self.stateChanged) self.stateChanged(self.running);
}

- (void)reloadPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _enabled = [defaults boolForKey:IMEnabledKey];
    _mapSideButtons = [defaults boolForKey:IMMapButtonsKey];
    _automaticScrollDirection = [defaults boolForKey:IMAutoScrollKey];
    _systemNaturalScrolling = [defaults boolForKey:@"com.apple.swipescrolldirection"];
    _copyButton = [defaults integerForKey:IMCopyButtonKey];
    _pasteButton = [defaults integerForKey:IMPasteButtonKey];
}

- (void)restart {
    [self reloadPreferences];
    [self stop];
    if (_enabled) {
        [self start];
    } else if (self.stateChanged) {
        self.stateChanged(NO);
    }
}

- (void)start {
    if (self.running || !_enabled) {
        return;
    }

    CGEventMask gestureMask = (CGEventMask)NSEventMaskGesture;
    CGEventMask activeMask = CGEventMaskBit(kCGEventScrollWheel)
        | CGEventMaskBit(kCGEventOtherMouseDown)
        | CGEventMaskBit(kCGEventOtherMouseUp);

    _gestureTap = CGEventTapCreate(kCGSessionEventTap,
                                   kCGTailAppendEventTap,
                                   kCGEventTapOptionListenOnly,
                                   gestureMask,
                                   IMEventCallback,
                                   (__bridge void *)self);
    _activeTap = CGEventTapCreate(kCGHIDEventTap,
                                  kCGHeadInsertEventTap,
                                  kCGEventTapOptionDefault,
                                  activeMask,
                                  IMEventCallback,
                                  (__bridge void *)self);
    if (!_activeTap) {
        _activeTap = CGEventTapCreate(kCGSessionEventTap,
                                      kCGHeadInsertEventTap,
                                      kCGEventTapOptionDefault,
                                      activeMask,
                                      IMEventCallback,
                                      (__bridge void *)self);
    }

    if (!_activeTap) {
        [self stop];
        if (self.stateChanged) self.stateChanged(NO);
        return;
    }

    _activeSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _activeTap, 0);
    if (_gestureTap) {
        _gestureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _gestureTap, 0);
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), _activeSource, kCFRunLoopCommonModes);
    if (_gestureSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), _gestureSource, kCFRunLoopCommonModes);
    }
    CGEventTapEnable(_activeTap, true);
    if (_gestureTap) CGEventTapEnable(_gestureTap, true);

    if (self.stateChanged) self.stateChanged(YES);
}

- (void)stop {
    if (_activeSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _activeSource, kCFRunLoopCommonModes);
        CFRelease(_activeSource);
        _activeSource = NULL;
    }
    if (_gestureSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _gestureSource, kCFRunLoopCommonModes);
        CFRelease(_gestureSource);
        _gestureSource = NULL;
    }
    if (_activeTap) {
        CFRelease(_activeTap);
        _activeTap = NULL;
    }
    if (_gestureTap) {
        CFRelease(_gestureTap);
        _gestureTap = NULL;
    }
    _touchingFingers = 0;
}

- (CGEventRef)handleType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (_activeTap) CGEventTapEnable(_activeTap, true);
        if (_gestureTap) CGEventTapEnable(_gestureTap, true);
        return event;
    }

    if (type == (CGEventType)NSEventTypeGesture) {
        [self recordGesture:event];
        return event;
    }

    if (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) {
        return [self handleButtonType:type event:event];
    }

    if (type == kCGEventScrollWheel) {
        [self handleScroll:event];
    }
    return event;
}

- (void)recordGesture:(CGEventRef)event {
    NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
    if (!nsEvent) return;
    NSUInteger count = [[nsEvent touchesMatchingPhase:NSTouchPhaseTouching inView:nil] count];
    if (count < 2) return;

    _touchingFingers = MAX(_touchingFingers, count);
    _lastTouchUptime = NSProcessInfo.processInfo.systemUptime;
}

- (CGEventRef)handleButtonType:(CGEventType)type event:(CGEventRef)event {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!_enabled || !_mapSideButtons) {
        return event;
    }

    int64_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    if (_capturingKey) {
        if (type == kCGEventOtherMouseDown) {
            NSString *capturedKey = _capturingKey;
            _capturingKey = nil;
            [defaults setInteger:button forKey:capturedKey];
            [defaults setBool:YES forKey:IMMapButtonsKey];
            [self reloadPreferences];
            if (self.bindingCaptured) self.bindingCaptured(capturedKey, button);
            if (self.stateChanged) self.stateChanged(self.running);
        }
        // Do not let the button navigate while it is being learned.
        return NULL;
    }

    BOOL isCopy = button == _copyButton;
    BOOL isPaste = button == _pasteButton;
    if (!isCopy && !isPaste) return event;

    if (type == kCGEventOtherMouseDown) {
        [self sendCommandShortcut:isCopy ? 8 : 9];
    }
    return NULL;
}

- (void)sendCommandShortcut:(CGKeyCode)keyCode {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!source) return;
    CGEventRef down = CGEventCreateKeyboardEvent(source, keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, keyCode, false);
    if (down && up) {
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    CFRelease(source);
}

- (IMScrollSource)sourceForContinuous:(BOOL)continuous
                              fingers:(NSUInteger)fingers
                              elapsed:(NSTimeInterval)elapsed
                             momentum:(BOOL)momentum {
    if (!continuous) {
        _lastSource = IMScrollSourceMouse;
    } else if (fingers >= 2 && elapsed < 0.222) {
        _lastSource = IMScrollSourceTrackpad;
    } else if (!momentum && elapsed > 0.333) {
        _lastSource = IMScrollSourceMouse;
    }
    return _lastSource;
}

- (void)handleScroll:(CGEventRef)event {
    if (!_enabled || !_automaticScrollDirection) {
        return;
    }

    NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
    if (!nsEvent) return;

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval elapsed = now - _lastTouchUptime;
    NSUInteger fingers = _touchingFingers;
    _touchingFingers = 0;
    BOOL continuous = CGEventGetIntegerValueField(
        event, kCGScrollWheelEventIsContinuous
    ) != 0;
    int64_t momentumPhase = CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase);
    int64_t scrollPhase = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    int64_t scrollCount = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollCount);
    BOOL hasTrackpadPhase = momentumPhase != 0 || scrollPhase != 0 || scrollCount != 0;
    BOOL momentum = nsEvent.momentumPhase != NSEventPhaseNone || momentumPhase != 0;
    IMScrollSource source;
    if (hasTrackpadPhase) {
        source = IMScrollSourceTrackpad;
        _lastSource = source;
    } else {
        source = [self sourceForContinuous:continuous
                                  fingers:fingers
                                  elapsed:elapsed
                                 momentum:momentum];
    }

    BOOL systemNatural = _systemNaturalScrolling;
    BOOL shouldReverse = source == IMScrollSourceMouse ? systemNatural : !systemNatural;

    int64_t axis1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    int64_t axis2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
    _lastScrollSummary = [NSString stringWithFormat:@"%@ | %@ | 系统自然:%@ | Y:%lld",
                          source == IMScrollSourceMouse ? @"鼠标" : @"触控板",
                          continuous ? @"连续" : @"离散",
                          systemNatural ? @"开" : @"关",
                          axis1];

    if (!shouldReverse) return;

    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, -axis1);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, -axis2);
    if (!continuous) return;

    int64_t point1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t point2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    double fixedDelta1 = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
    double fixedDelta2 = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);

    CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, -fixedDelta1);
    CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, -fixedDelta2);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, -point1);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, -point2);
}

@end

@interface IMAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation IMAppDelegate {
    NSStatusItem *_statusItem;
    IMEventController *_eventController;
    NSTimer *_permissionTimer;
    BOOL _lastListenAccess;
    NSMenuItem *_scrollDebugItem;
    NSWindow *_settingsWindow;
    NSTextField *_settingsStatusLabel;
    NSTextField *_settingsPermissionLabel;
    NSTextField *_copyBindingLabel;
    NSTextField *_pasteBindingLabel;
    NSTextField *_settingsScrollDiagnosticLabel;
    NSButton *_settingsEnabledCheck;
    NSButton *_settingsButtonsCheck;
    NSButton *_settingsScrollCheck;
    NSButton *_settingsLaunchCheck;
    NSButton *_copyRecordButton;
    NSButton *_pasteRecordButton;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        IMEnabledKey: @YES,
        IMMapButtonsKey: @YES,
        IMAutoScrollKey: @YES,
        IMCopyButtonKey: @3,
        IMPasteButtonKey: @4,
    }];

    _eventController = [[IMEventController alloc] init];
    __weak typeof(self) weakSelf = self;
    _eventController.stateChanged = ^(BOOL running) {
        (void)running;
        [weakSelf rebuildMenu];
    };
    _eventController.bindingCaptured = ^(NSString *key, NSInteger button) {
        [weakSelf didCaptureBindingForKey:key button:button];
    };

    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    _statusItem.button.image = [NSImage imageWithSystemSymbolName:@"computermouse"
                                         accessibilityDescription:@"InputMate"];
    _statusItem.button.toolTip = @"InputMate";
    [self rebuildMenu];
    _lastListenAccess = CGPreflightListenEventAccess();

    if (AXIsProcessTrusted() && CGPreflightPostEventAccess()) {
        [_eventController start];
    } else {
        [self requestRequiredPermissions];
    }

    _permissionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                       target:self
                                                     selector:@selector(refreshPermission)
                                                     userInfo:nil
                                                      repeats:YES];

}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_permissionTimer invalidate];
    [_eventController stop];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                    hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    [self showSettings];
    return YES;
}

- (NSMenuItem *)toggleItem:(NSString *)title state:(BOOL)state action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = state ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    _scrollDebugItem.title = [NSString stringWithFormat:@"最近滚动：%@",
                              _eventController.lastScrollSummary];
}

- (NSTextField *)settingsLabel:(NSString *)text
                           size:(CGFloat)size
                         weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    return label;
}

- (NSStackView *)horizontalRowWithLabel:(NSTextField *)label button:(NSButton *)button {
    NSStackView *row = [NSStackView stackViewWithViews:@[label, button]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentHuggingPriority:NSLayoutPriorityRequired
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

- (NSBox *)settingsCardWithTitle:(NSString *)title
                             body:(NSArray<NSView *> *)body {
    NSBox *box = [[NSBox alloc] init];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.borderColor = [NSColor separatorColor];
    box.borderWidth = 1;
    box.cornerRadius = 10;
    box.fillColor = [NSColor controlBackgroundColor];
    box.contentViewMargins = NSMakeSize(16, 14);

    NSTextField *titleLabel = [self settingsLabel:title size:15 weight:NSFontWeightSemibold];
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:titleLabel];
    [views addObjectsFromArray:body];
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 9;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:box.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor],
    ]];
    return box;
}

- (void)buildSettingsWindowIfNeeded {
    if (_settingsWindow) return;

    _settingsWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 620, 570)
                  styleMask:NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _settingsWindow.title = @"InputMate 设置";
    _settingsWindow.releasedWhenClosed = NO;
    _settingsWindow.minSize = NSMakeSize(560, 540);
    _settingsWindow.backgroundColor = NSColor.windowBackgroundColor;

    NSView *content = _settingsWindow.contentView;
    NSImageView *icon = [[NSImageView alloc] init];
    icon.image = NSApp.applicationIconImage;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.accessibilityLabel = @"InputMate";
    [icon.widthAnchor constraintEqualToConstant:46].active = YES;
    [icon.heightAnchor constraintEqualToConstant:46].active = YES;

    NSTextField *appTitle = [self settingsLabel:@"InputMate" size:25 weight:NSFontWeightBold];
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, appTitle]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 14;

    _settingsStatusLabel = [self settingsLabel:@"" size:14 weight:NSFontWeightSemibold];
    _settingsPermissionLabel = [self settingsLabel:@"" size:12 weight:NSFontWeightRegular];
    _settingsPermissionLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *accessibilityButton = [NSButton buttonWithTitle:@"打开辅助功能设置"
                                                      target:self
                                                      action:@selector(openAccessibilitySettings)];
    NSButton *inputButton = [NSButton buttonWithTitle:@"打开输入监控设置"
                                              target:self
                                              action:@selector(openInputMonitoringSettings)];
    NSStackView *permissionButtons = [NSStackView stackViewWithViews:@[accessibilityButton, inputButton]];
    permissionButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    permissionButtons.spacing = 8;
    NSBox *statusCard = [self settingsCardWithTitle:@"运行状态"
                                              body:@[_settingsStatusLabel,
                                                     _settingsPermissionLabel,
                                                     permissionButtons]];

    _copyBindingLabel = [self settingsLabel:@"" size:13 weight:NSFontWeightMedium];
    _pasteBindingLabel = [self settingsLabel:@"" size:13 weight:NSFontWeightMedium];
    _copyRecordButton = [NSButton buttonWithTitle:@"录制按键…"
                                           target:self
                                           action:@selector(bindCopyButton)];
    _pasteRecordButton = [NSButton buttonWithTitle:@"录制按键…"
                                            target:self
                                            action:@selector(bindPasteButton)];
    NSStackView *copyRow = [self horizontalRowWithLabel:_copyBindingLabel button:_copyRecordButton];
    NSStackView *pasteRow = [self horizontalRowWithLabel:_pasteBindingLabel button:_pasteRecordButton];
    NSBox *buttonCard = [self settingsCardWithTitle:@"鼠标侧键"
                                              body:@[copyRow, pasteRow]];

    _settingsScrollCheck = [NSButton checkboxWithTitle:@"触控板自然滚动，鼠标传统滚动"
                                                  target:self
                                                  action:@selector(settingsScrollChanged:)];
    _settingsScrollDiagnosticLabel = [self settingsLabel:@"" size:12 weight:NSFontWeightRegular];
    _settingsScrollDiagnosticLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *restartButton = [NSButton buttonWithTitle:@"重启事件监听"
                                                target:self
                                                action:@selector(restartEventListener)];
    NSBox *scrollCard = [self settingsCardWithTitle:@"滚动方向"
                                              body:@[_settingsScrollCheck,
                                                     _settingsScrollDiagnosticLabel,
                                                     restartButton]];

    _settingsEnabledCheck = [NSButton checkboxWithTitle:@"启用 InputMate"
                                                  target:self
                                                  action:@selector(settingsEnabledChanged:)];
    _settingsButtonsCheck = [NSButton checkboxWithTitle:@"启用侧键复制 / 粘贴"
                                                  target:self
                                                  action:@selector(settingsButtonsChanged:)];
    _settingsLaunchCheck = [NSButton checkboxWithTitle:@"登录时自动启动"
                                                 target:self
                                                 action:@selector(settingsLaunchChanged:)];
    NSBox *generalCard = [self settingsCardWithTitle:@"通用"
                                               body:@[_settingsEnabledCheck,
                                                      _settingsButtonsCheck,
                                                      _settingsLaunchCheck]];

    NSTextField *version = [self settingsLabel:
        [NSString stringWithFormat:@"InputMate %@ · macOS 13+", IMVersionString()]
                                          size:11
                                        weight:NSFontWeightRegular];
    version.textColor = NSColor.tertiaryLabelColor;
    version.alignment = NSTextAlignmentCenter;

    NSStackView *mainStack = [NSStackView stackViewWithViews:@[
        header, statusCard, buttonCard, scrollCard, generalCard, version
    ]];
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.alignment = NSLayoutAttributeLeading;
    mainStack.spacing = 14;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:mainStack];
    [NSLayoutConstraint activateConstraints:@[
        [mainStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [mainStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [mainStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:22],
        [mainStack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-18],
        [statusCard.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [buttonCard.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [scrollCard.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [generalCard.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [version.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
    ]];
}

- (void)refreshSettingsWindow {
    if (!_settingsWindow) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL trusted = AXIsProcessTrusted() && CGPreflightPostEventAccess();
    BOOL listening = CGPreflightListenEventAccess();
    _settingsStatusLabel.stringValue = _eventController.running
        ? @"● InputMate 正在监听输入"
        : @"● InputMate 当前未监听输入";
    _settingsStatusLabel.textColor = _eventController.running
        ? NSColor.systemGreenColor
        : NSColor.systemRedColor;
    _settingsPermissionLabel.stringValue = [NSString stringWithFormat:
        @"辅助功能：%@    输入监控：%@",
        trusted ? @"已授权" : @"未授权",
        listening ? @"已授权" : @"未授权"];
    NSInteger copyButton = [defaults integerForKey:IMCopyButtonKey];
    NSInteger pasteButton = [defaults integerForKey:IMPasteButtonKey];
    _copyBindingLabel.stringValue = [NSString stringWithFormat:@"复制（⌘C）  ·  鼠标键 %ld", (long)copyButton];
    _pasteBindingLabel.stringValue = [NSString stringWithFormat:@"粘贴（⌘V）  ·  鼠标键 %ld", (long)pasteButton];
    _copyRecordButton.title = [_eventController.capturingKey isEqualToString:IMCopyButtonKey]
        ? @"等待按键…" : @"重新录制…";
    _pasteRecordButton.title = [_eventController.capturingKey isEqualToString:IMPasteButtonKey]
        ? @"等待按键…" : @"重新录制…";
    _settingsScrollDiagnosticLabel.stringValue = [NSString stringWithFormat:
        @"最近一次输入：%@", _eventController.lastScrollSummary];
    _settingsEnabledCheck.state = [defaults boolForKey:IMEnabledKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsButtonsCheck.state = [defaults boolForKey:IMMapButtonsKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsScrollCheck.state = [defaults boolForKey:IMAutoScrollKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsLaunchCheck.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    _copyRecordButton.enabled = _eventController.running;
    _pasteRecordButton.enabled = _eventController.running;
}

- (void)showSettings {
    [self buildSettingsWindowIfNeeded];
    [self refreshSettingsWindow];
    [_settingsWindow center];
    [_settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)rebuildMenu {
    if (!_statusItem) return;
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    NSString *statusText;
    if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess()) {
        statusText = @"状态：需要辅助功能权限";
    } else if (_eventController.capturingKey) {
        statusText = [_eventController.capturingKey isEqualToString:IMCopyButtonKey]
            ? @"状态：请按下用于“复制”的鼠标键"
            : @"状态：请按下用于“粘贴”的鼠标键";
    } else if (_eventController.running) {
        statusText = _eventController.gestureMonitoringAvailable
            ? @"状态：正在运行"
            : @"状态：侧键可用，滚动识别需输入监控权限";
    } else {
        statusText = @"状态：已停用";
    }
    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:statusText action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];

    [menu addItem:NSMenuItem.separatorItem];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [menu addItem:[self toggleItem:@"启用 InputMate"
                             state:[defaults boolForKey:IMEnabledKey]
                            action:@selector(toggleEnabled)]];
    [menu addItem:[self toggleItem:@"侧键：复制 / 粘贴"
                             state:[defaults boolForKey:IMMapButtonsKey]
                            action:@selector(toggleButtons)]];

    NSString *mappingText = [NSString stringWithFormat:@"当前侧键：%ld → 复制，%ld → 粘贴",
                             (long)[defaults integerForKey:IMCopyButtonKey],
                             (long)[defaults integerForKey:IMPasteButtonKey]];
    NSMenuItem *mapping = [[NSMenuItem alloc] initWithTitle:mappingText action:nil keyEquivalent:@""];
    mapping.enabled = NO;
    [menu addItem:mapping];
    NSMenuItem *bindCopy = [[NSMenuItem alloc] initWithTitle:@"录制“复制”侧键…"
                                                     action:@selector(bindCopyButton)
                                              keyEquivalent:@""];
    bindCopy.target = self;
    [menu addItem:bindCopy];
    NSMenuItem *bindPaste = [[NSMenuItem alloc] initWithTitle:@"录制“粘贴”侧键…"
                                                      action:@selector(bindPasteButton)
                                               keyEquivalent:@""];
    bindPaste.target = self;
    [menu addItem:bindPaste];
    [menu addItem:[self toggleItem:@"触控板自然 / 鼠标传统滚动"
                             state:[defaults boolForKey:IMAutoScrollKey]
                            action:@selector(toggleAutoScroll)]];
    _scrollDebugItem = [[NSMenuItem alloc] initWithTitle:
        [NSString stringWithFormat:@"最近滚动：%@", _eventController.lastScrollSummary]
                                                   action:nil
                                            keyEquivalent:@""];
    _scrollDebugItem.enabled = NO;
    [menu addItem:_scrollDebugItem];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"打开设置…"
                                                         action:@selector(showSettings)
                                                  keyEquivalent:@","];
    settingsItem.target = self;
    [menu addItem:settingsItem];
    if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess()) {
        NSMenuItem *permission = [[NSMenuItem alloc] initWithTitle:@"授予辅助功能权限…"
                                                           action:@selector(openAccessibilitySettings)
                                                    keyEquivalent:@""];
        permission.target = self;
        [menu addItem:permission];
    }
    if (!CGPreflightListenEventAccess()) {
        NSMenuItem *inputPermission = [[NSMenuItem alloc] initWithTitle:@"授予输入监控权限…"
                                                                action:@selector(openInputMonitoringSettings)
                                                         keyEquivalent:@""];
        inputPermission.target = self;
        [menu addItem:inputPermission];
    }

    BOOL loginEnabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    [menu addItem:[self toggleItem:@"登录时自动启动"
                             state:loginEnabled
                            action:@selector(toggleLaunchAtLogin)]];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 InputMate"
                                                 action:@selector(quit)
                                          keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    _statusItem.menu = menu;
    [self refreshSettingsWindow];
}

- (void)refreshPermission {
    [_eventController reloadPreferences];
    BOOL listenAccess = CGPreflightListenEventAccess();
    if (listenAccess != _lastListenAccess) {
        _lastListenAccess = listenAccess;
        if (AXIsProcessTrusted()
            && CGPreflightPostEventAccess()
            && [NSUserDefaults.standardUserDefaults boolForKey:IMEnabledKey]) {
            [_eventController restart];
        }
        return;
    }
    if (AXIsProcessTrusted()
        && CGPreflightPostEventAccess()
        && [NSUserDefaults.standardUserDefaults boolForKey:IMEnabledKey]
        && !_eventController.running) {
        [_eventController start];
    }
    [self refreshSettingsWindow];
}

- (void)requestRequiredPermissions {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    CGRequestPostEventAccess();
    CGRequestListenEventAccess();
}

- (void)ensureReadyForBinding:(NSString *)key {
    if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess() || !_eventController.running) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"需要辅助功能权限";
        alert.informativeText = @"先在系统设置中允许 InputMate，然后再录制鼠标侧键。";
        [alert addButtonWithTitle:@"打开系统设置"];
        [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [self openAccessibilitySettings];
        return;
    }
    [_eventController beginCapturingButtonForKey:key];
    _statusItem.button.image = [NSImage imageWithSystemSymbolName:@"record.circle"
                                         accessibilityDescription:@"正在录制鼠标键"];
    _statusItem.button.toolTip = [key isEqualToString:IMCopyButtonKey]
        ? @"请按下用于复制的鼠标键"
        : @"请按下用于粘贴的鼠标键";
}

- (void)didCaptureBindingForKey:(NSString *)key button:(NSInteger)button {
    _statusItem.button.image = [NSImage imageWithSystemSymbolName:@"computermouse"
                                         accessibilityDescription:@"InputMate"];
    NSString *action = [key isEqualToString:IMCopyButtonKey] ? @"复制" : @"粘贴";
    _statusItem.button.toolTip = [NSString stringWithFormat:@"已将鼠标键 %ld 绑定为%@",
                                  (long)button, action];
    [self rebuildMenu];
}

- (void)settingsEnabledChanged:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                          forKey:IMEnabledKey];
    [_eventController restart];
    [self rebuildMenu];
}

- (void)settingsButtonsChanged:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                          forKey:IMMapButtonsKey];
    [_eventController reloadPreferences];
    [self rebuildMenu];
}

- (void)settingsScrollChanged:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                          forKey:IMAutoScrollKey];
    [_eventController reloadPreferences];
    [self rebuildMenu];
}

- (void)settingsLaunchChanged:(NSButton *)sender {
    BOOL wantsEnabled = sender.state == NSControlStateValueOn;
    BOOL isEnabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    if (wantsEnabled != isEnabled) [self toggleLaunchAtLogin];
}

- (void)restartEventListener {
    [_eventController restart];
    [self rebuildMenu];
}

- (void)bindCopyButton {
    [self ensureReadyForBinding:IMCopyButtonKey];
}

- (void)bindPasteButton {
    [self ensureReadyForBinding:IMPasteButtonKey];
}

- (void)toggleEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:IMEnabledKey] forKey:IMEnabledKey];
    [_eventController restart];
    [self rebuildMenu];
}

- (void)toggleButtons {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:IMMapButtonsKey] forKey:IMMapButtonsKey];
    [_eventController reloadPreferences];
    [self rebuildMenu];
}

- (void)toggleAutoScroll {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:IMAutoScrollKey] forKey:IMAutoScrollKey];
    [_eventController reloadPreferences];
    [self rebuildMenu];
}

- (void)openAccessibilitySettings {
    [self requestRequiredPermissions];
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)openInputMonitoringSettings {
    CGRequestListenEventAccess();
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)toggleLaunchAtLogin {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = service.status == SMAppServiceStatusEnabled
        ? [service unregisterAndReturnError:&error]
        : [service registerAndReturnError:&error];
    if (!success) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"无法更新登录项";
        alert.informativeText = error.localizedDescription ?: @"未知错误";
        [alert runModal];
    }
    [self rebuildMenu];
}

- (void)quit {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--version") == 0) {
            puts(IMVersionString().UTF8String);
            return 0;
        }
        NSApplication *application = NSApplication.sharedApplication;
        IMAppDelegate *delegate = [[IMAppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
