// DirectVolumeTap — 独立版（自包含，注入即生效）
// 不依赖任何设置页/配置：把 dylib 注入哪个 App，就在哪个 App 生效。
//   ① 三指长按 → 弹出设置覆盖层，点选/替换「音量+」「音量-」两个点击坐标
//      （红点=音量+点的地方，绿点=音量-点的地方；默认屏幕中心上+=红、下-=绿）
//   ② 触发：音量键（物理/蓝牙翻页器）→ KVO outputVolume（需激活静音音频会话）
//   ③ 点击：PTFakeMetaTouch 原生库（fakeTouchId:AtPoint:withTouchPhase:），王跳跳同款
//   ④ 复位：到顶/底自动拉回中间 0.3，防止按键失效
// 日志：写固定路径 + App 沙盒 + NSLog，便于排查

#import "ptftouch/PTFakeMetaTouch.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVAudioEngine.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdarg.h>

// ---------- 日志：多路径 + NSLog ----------
static NSString *LogPath1 = @"/var/mobile/Library/Preferences/com.yourname.directvolumetap.log";
static void LogDVT(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    FILE *f = fopen(LogPath1.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
    @try {
        NSString *home = NSHomeDirectory();
        if (home.length) {
            NSString *p = [home stringByAppendingPathComponent:@"directvolumetap.log"];
            FILE *g = fopen(p.UTF8String, "a");
            if (g) { fputs(line.UTF8String, g); fclose(g); }
        }
    } @catch (NSException *e) {}
    NSLog(@"%@", line);
}

// ---------- NSUserDefaults（独立 suite，不与 VolumeKeyTapper 混） ----------
static NSUserDefaults *Defaults(void) {
    static NSUserDefaults *d = nil;
    static dispatch_once_t on;
    dispatch_once(&on, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yourname.directvolumetap"]; });
    return d;
}

// =====================================================
// AutoSkipSettingsCenter（三指设置界面 + 点选坐标）
// =====================================================
@interface AutoSkipSettingsCenter : NSObject
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) UILabel *statusTip;
@property (nonatomic, strong) NSMutableArray<NSValue *> *points; // CGPoint，[0]=音量+红，[1]=音量-绿
+ (instancetype)shared;
- (void)installGestureInWindow:(UIWindow *)window;
- (void)onThreeFingerTap:(UIGestureRecognizer *)gr;
- (void)showOverlayInWindow:(UIWindow *)window;
- (void)onOverlayTapToPick:(UITapGestureRecognizer *)gr;
- (void)refreshMarkersInWindow:(UIWindow *)window;
- (void)btnAddPoint;
- (void)btnDelLast;
- (void)btnClose;
@end

@implementation AutoSkipSettingsCenter

+ (instancetype)shared {
    static AutoSkipSettingsCenter *s = nil;
    static dispatch_once_t on;
    dispatch_once(&on, ^{ s = [AutoSkipSettingsCenter new]; });
    return s;
}

// 载入坐标；若无保存则用默认 = 屏幕中心上+=红、下-=绿
- (void)loadPoints {
    self.points = [NSMutableArray array];
    NSDictionary *d = [Defaults() dictionaryRepresentation];
    if (d[@"xPlus"] && d[@"yPlus"]) {
        [self.points addObject:[NSValue valueWithCGPoint:CGPointMake([d[@"xPlus"] intValue], [d[@"yPlus"] intValue])]];
    }
    if (d[@"xMinus"] && d[@"yMinus"]) {
        [self.points addObject:[NSValue valueWithCGPoint:CGPointMake([d[@"xMinus"] intValue], [d[@"yMinus"] intValue])]];
    }
    if (self.points.count == 0) {
        // 默认：屏幕中心上下两段
        CGSize scr = [UIScreen mainScreen].bounds.size;
        if (scr.width > 0 && scr.height > 0) {
            CGFloat cx = scr.width / 2;
            [self.points addObject:[NSValue valueWithCGPoint:CGPointMake(cx, scr.height * 0.30)]];
            [self.points addObject:[NSValue valueWithCGPoint:CGPointMake(cx, scr.height * 0.70)]];
            LogDVT(@"未保存坐标，使用默认: +=(%.0f,%.0f) -=(%.0f,%.0f)",
                   cx, scr.height*0.30, cx, scr.height*0.70);
        }
    } else {
        LogDVT(@"加载坐标: +=(%.0f,%.0f) -=(%.0f,%.0f)",
               self.points.count>0 ? self.points[0].CGPointValue.x : -1,
               self.points.count>0 ? self.points[0].CGPointValue.y : -1,
               self.points.count>1 ? self.points[1].CGPointValue.x : -1,
               self.points.count>1 ? self.points[1].CGPointValue.y : -1);
    }
}

// 保存（points[0]→+, points[1]→-）
- (void)savePoints {
    NSUserDefaults *d = Defaults();
    if (self.points.count > 0) {
        CGPoint p = self.points[0].CGPointValue;
        [d setInteger:(NSInteger)p.x forKey:@"xPlus"];
        [d setInteger:(NSInteger)p.y forKey:@"yPlus"];
    }
    if (self.points.count > 1) {
        CGPoint p = self.points[1].CGPointValue;
        [d setInteger:(NSInteger)p.x forKey:@"xMinus"];
        [d setInteger:(NSInteger)p.y forKey:@"yMinus"];
    }
    [d synchronize];
    LogDVT(@"已保存坐标 %lu 个点", (unsigned long)self.points.count);
}

// 三指手势回调：显示设置覆盖层
- (void)onThreeFingerTap:(UIGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UIWindow *w = gr.view.window ?: [UIApplication sharedApplication].keyWindow;
    LogDVT(@"三指手势触发 → 显示设置界面");
    [self showOverlayInWindow:w];
}

// 显示设置覆盖层
- (void)showOverlayInWindow:(UIWindow *)window {
    if (!window) { LogDVT(@"覆盖层失败: 无窗口"); return; }
    if (self.overlay) [self.overlay removeFromSuperview];

    UIView *ov = [[UIView alloc] initWithFrame:window.bounds];
    ov.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    ov.userInteractionEnabled = YES;
    self.overlay = ov;

    // 顶部提示条
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, window.bounds.size.width, 44)];
    tip.text = @"点屏幕: 第1个=红+ 第2个=绿- | 已满则就近替换 | 右上角完成";
    tip.textColor = [UIColor whiteColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
    tip.font = [UIFont boldSystemFontOfSize:15];
    self.statusTip = tip;
    [ov addSubview:tip];

    // 完成按钮
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(window.bounds.size.width - 90, 40, 80, 40);
    [close setTitle:@"完成" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.backgroundColor = [UIColor systemBlueColor];
    close.layer.cornerRadius = 8;
    [close addTarget:self action:@selector(btnClose) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:close];

    // 删除最后一个点
    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    del.frame = CGRectMake(16, window.bounds.size.height - 80, 110, 44);
    [del setTitle:@"删除最后一点" forState:UIControlStateNormal];
    [del setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    del.backgroundColor = [UIColor systemRedColor];
    del.layer.cornerRadius = 8;
    [del addTarget:self action:@selector(btnDelLast) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:del];

    // 点选手势
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(onOverlayTapToPick:)];
    [ov addGestureRecognizer:tap];

    [window addSubview:ov];
    [self refreshMarkersInWindow:window];
    LogDVT(@"设置界面已显示");
}

// 覆盖层点选 → 记录坐标（最多2点，已满就近替换）
- (void)onOverlayTapToPick:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    UIView *ov = gr.view;
    if (!ov) return;
    CGPoint loc = [gr locationInView:ov];
    if (self.points.count < 2) {
        [self.points addObject:[NSValue valueWithCGPoint:loc]];
    } else {
        CGFloat dP = hypot(loc.x - self.points[0].CGPointValue.x, loc.y - self.points[0].CGPointValue.y);
        CGFloat dM = hypot(loc.x - self.points[1].CGPointValue.x, loc.y - self.points[1].CGPointValue.y);
        NSUInteger idx = (dP <= dM) ? 0 : 1;
        self.points[idx] = [NSValue valueWithCGPoint:loc];
    }
    LogDVT(@"★设置坐标: +=(%.0f,%.0f) -=(%.0f,%.0f)",
           self.points.count>0 ? self.points[0].CGPointValue.x : -1,
           self.points.count>0 ? self.points[0].CGPointValue.y : -1,
           self.points.count>1 ? self.points[1].CGPointValue.x : -1,
           self.points.count>1 ? self.points[1].CGPointValue.y : -1);
    [self savePoints];
    [self refreshMarkersInWindow:ov.window ?: [UIApplication sharedApplication].keyWindow];
    self.statusTip.text = [NSString stringWithFormat:@"红+ :(%.0f,%.0f)  绿- :(%.0f,%.0f) | 右上角完成",
                           self.points.count>0 ? self.points[0].CGPointValue.x : 0,
                           self.points.count>0 ? self.points[0].CGPointValue.y : 0,
                           self.points.count>1 ? self.points[1].CGPointValue.x : 0,
                           self.points.count>1 ? self.points[1].CGPointValue.y : 0];
}

// 添加一个点（预留接口：覆盖层中心）
- (void)btnAddPoint {
    UIView *ov = self.overlay;
    if (!ov) return;
    CGPoint loc = CGPointMake(ov.bounds.size.width/2, ov.bounds.size.height/2);
    if (self.points.count < 2) {
        [self.points addObject:[NSValue valueWithCGPoint:loc]];
    } else {
        self.points[0] = [NSValue valueWithCGPoint:loc];
    }
    [self savePoints];
    [self refreshMarkersInWindow:ov.window ?: [UIApplication sharedApplication].keyWindow];
}

// 删除最后一个点
- (void)btnDelLast {
    if (self.points.count) {
        [self.points removeLastObject];
        [self savePoints];
        [self refreshMarkersInWindow:self.overlay.window];
    }
}

// 关闭设置界面
- (void)btnClose {
    [self.overlay removeFromSuperview];
    self.overlay = nil;
    LogDVT(@"设置界面已关闭，当前 %lu 个坐标生效", (unsigned long)self.points.count);
}

// 画标记点：第0点=红+，第1点=绿-
- (void)refreshMarkersInWindow:(UIWindow *)window {
    if (!window || !self.overlay) return;
    for (UIView *v in [self.overlay subviews]) if (v.tag == 999) [v removeFromSuperview];
    for (NSUInteger i = 0; i < self.points.count; i++) {
        CGPoint p = self.points[i].CGPointValue;
        BOOL isPlus = (i == 0);
        UILabel *dot = [[UILabel alloc] initWithFrame:CGRectMake(p.x - 22, p.y - 22, 44, 44)];
        dot.tag = 999;
        dot.layer.cornerRadius = 22;
        dot.layer.masksToBounds = YES;
        dot.layer.borderWidth = 3;
        dot.layer.borderColor = [UIColor whiteColor].CGColor;
        dot.backgroundColor = isPlus ? [UIColor systemRedColor] : [UIColor systemGreenColor];
        dot.text = isPlus ? @"+" : @"-";
        dot.textColor = [UIColor whiteColor];
        dot.textAlignment = NSTextAlignmentCenter;
        dot.font = [UIFont boldSystemFontOfSize:22];
        [self.overlay addSubview:dot];
        [self.overlay bringSubviewToFront:dot];
    }
}

// 安装三指长按手势
- (void)installGestureInWindow:(UIWindow *)window {
    if (!window) return;
    UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(onThreeFingerTap:)];
    gr.numberOfTouchesRequired = 3;
    gr.minimumPressDuration = 0.5;
    [window addGestureRecognizer:gr];
    LogDVT(@"三指长按手势已安装");
}

@end

// =====================================================
// 音量键触发 → 点击坐标（PTFakeMetaTouch）
// =====================================================
static UIWindow *FindKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.connectedScenes) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
                return [ws.windows firstObject];
            }
        }
    }
    return app.keyWindow;
}

static void ShowToast(NSString *msg) {
    UIWindow *w = FindKeyWindow();
    if (!w) return;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(w.bounds.size.width/2 - 160, 200, 320, 64)];
    l.text = msg;
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:18];
    l.numberOfLines = 2;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
    l.layer.cornerRadius = 12;
    l.layer.masksToBounds = YES;
    l.layer.borderWidth = 2;
    l.layer.borderColor = [UIColor systemYellowColor].CGColor;
    [w addSubview:l];
    [w bringSubviewToFront:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
}

// 按方向点击：delta>0 点红+(音量+)，delta<0 点绿-(音量-)
static void TapPoints(float delta) {
    AutoSkipSettingsCenter *c = [AutoSkipSettingsCenter shared];
    BOOL isPlus = (delta > 0);
    NSValue *target = isPlus ? (c.points.count > 0 ? c.points[0] : nil)
                             : (c.points.count > 1 ? c.points[1] : nil);
    if (!target) {
        LogDVT(@"音量%@：无对应坐标（请三指长按设置）", isPlus ? @"+" : @"-");
        ShowToast([NSString stringWithFormat:@"音量%@ 未设坐标，三指长按设置", isPlus ? @"+" : @"-"]);
        return;
    }
    CGPoint p = target.CGPointValue;
    UIWindow *w = FindKeyWindow();
    if (!w) { LogDVT(@"音量触发：无 keyWindow"); return; }
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    LogDVT(@"音量%@→点击 (%d, %d) pointId=%ld", isPlus ? @"+" : @"-", (int)p.x, (int)p.y, (long)pid);
    ShowToast([NSString stringWithFormat:@"音量%@ 已点击 (%.0f,%.0f)", isPlus ? @"+" : @"-", p.x, p.y]);
}

// 去抖 250ms
static CFAbsoluteTime gLastTap = 0;
static void TapPointsDebounced(float delta) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastTap < 0.25) { LogDVT(@"去抖：忽略本次触发"); return; }
    gLastTap = now;
    TapPoints(delta);
}

// 复位：到顶/底拉回中间 0.3（双保险 MPVolumeView + AVSystemController）
static MPVolumeView *gVolView = nil;
static void SetSystemVolume(float v) {
    @try {
        if (!gVolView) {
            gVolView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 0, 0)];
            UIWindow *w = FindKeyWindow();
            if (w) [w addSubview:gVolView];
        }
        for (UIView *s in gVolView.subviews) {
            if ([s isKindOfClass:[UISlider class]]) {
                [(UISlider *)s setValue:v animated:NO];
                break;
            }
        }
    } @catch (NSException *e) {
        LogDVT(@"MPVolumeView复位失败: %@", e);
    }
    @try {
        Class c = NSClassFromString(@"AVSystemController");
        id controller = [c performSelector:NSSelectorFromString(@"sharedAVSystemController")];
        [controller performSelector:NSSelectorFromString(@"setVolumeTo:") withObject:@(v)];
    } @catch (NSException *e) {
        LogDVT(@"AVSystemController复位失败: %@", e);
    }
}

static const float kResetVolume = 0.3f;
static const float kBoundHigh = 0.85f;
static const float kBoundLow  = 0.15f;
static BOOL VolumeNeedsReset(float v) { return (v > kBoundHigh || v < kBoundLow); }

static void DoReset(float oldVol, float nowVol) {
    if (VolumeNeedsReset(nowVol) || VolumeNeedsReset(oldVol)) {
        LogDVT(@"音量接近边界(%.2f→%.2f)，复位到 %.1f", oldVol, nowVol, kResetVolume);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SetSystemVolume(kResetVolume); });
    }
}

// 监听
@interface DirectVolumeObserver : NSObject
@end
@implementation DirectVolumeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"outputVolume"]) return;
    NSNumber *oldN = change[NSKeyValueChangeOldKey];
    NSNumber *newN = change[NSKeyValueChangeNewKey];
    if (!oldN || !newN) return;
    float old = oldN.floatValue, now = newN.floatValue;
    float delta = now - old;
    if (fabsf(delta) < 0.0005f) return;
    LogDVT(@"音量%@ delta=%+.2f 当前=%0.2f → 触发", delta > 0 ? @"+" : @"-", delta, now);
    TapPointsDebounced(delta);
    DoReset(old, now);
}
- (void)volChanged:(NSNotification *)notif {
    // 兜底，KVO 已负责
}
@end

// 第三重：hook UIApplication _handleKeyUIEvent: 捕获音量键
static IMP gOrigHandleKeyUIEvent = NULL;
static void dvtHandleKeyUIEvent(id self, SEL _cmd, id event) {
    @try {
        UIEvent *ev = (UIEvent *)event;
        long keyCode = [[ev valueForKey:@"keyCode"] longValue];
        if (keyCode == 0xE8 || keyCode == 0xE9) {
            LogDVT(@"★捕获音量键 keyCode=0x%lX", keyCode);
            TapPointsDebounced((keyCode == 0xE9) ? 0.05f : -0.05f);
        }
    } @catch (NSException *e) {
        LogDVT(@"key event hook 异常: %@", e);
    }
    if (gOrigHandleKeyUIEvent) {
        ((void(*)(id, SEL, id))gOrigHandleKeyUIEvent)(self, _cmd, event);
    }
}

static void InstallKeyHook(void) {
    Method m = class_getInstanceMethod([UIApplication class], sel_registerName("_handleKeyUIEvent:"));
    if (!m) { LogDVT(@"hook失败: 无 _handleKeyUIEvent:"); return; }
    gOrigHandleKeyUIEvent = method_getImplementation(m);
    method_setImplementation(m, (IMP)dvtHandleKeyUIEvent);
    LogDVT(@"已 hook _handleKeyUIEvent: 捕获音量键");
}

// 关键：保持音频会话活跃（KVO outputVolume 才触发）
static AVAudioEngine *gEngine = nil;
static void KeepAudioSessionActive(void) {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient error:&err];
    if (err) LogDVT(@"setCategory Ambient 失败: %@", err);
    [session setActive:YES error:&err];
    if (err) LogDVT(@"setActive 失败: %@", err);
    LogDVT(@"音频会话已激活，当前音量=%0.2f", session.outputVolume);
    @try {
        gEngine = [AVAudioEngine new];
        AVAudioPlayerNode *player = [AVAudioPlayerNode new];
        [gEngine attachNode:player];
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:44100
                                                               channels:1
                                                            interleaved:NO];
        [gEngine connect:player to:gEngine.mainMixerNode format:fmt];
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:44100];
        buf.frameLength = 44100;
        [player scheduleBuffer:buf atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
        [gEngine startAndReturnError:&err];
        if (err) LogDVT(@"静音引擎启动失败: %@", err);
        [player play];
        LogDVT(@"静音循环已启动，音频会话保持活跃");
    } @catch (NSException *e) {
        LogDVT(@"静音引擎异常: %@", e);
    }
}

// =====================================================
// constructor：注入自启动（注入即生效，无勾选判断）
// =====================================================
// constructor 在 dyld 注入时机执行，此时 App 主线程/UIKit/Foundation 未就绪，
// 任何 UIKit/Foundation 同步操作都会 SIGABRT。因此只 dispatch 到主队列，
// 全部初始化等 App 启动后执行。
static DirectVolumeObserver *gObs = nil;

__attribute__((constructor))
static void DirectTapInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            LogDVT(@"[DirectVolumeTap 已注入] 进程=%@ bundleID=%@",
                   NSProcessInfo.processInfo.processName,
                   [[NSBundle mainBundle] bundleIdentifier]);
            // 注入即生效：直接激活监听 + 静音会话 + 三指手势
            gObs = [DirectVolumeObserver new];
            [[AVAudioSession sharedInstance] addObserver:gObs
                                              forKeyPath:@"outputVolume"
                                                 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                                                 context:NULL];
            [[NSNotificationCenter defaultCenter] addObserver:gObs
                                                     selector:@selector(volChanged:)
                                                         name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                       object:nil];
            LogDVT(@"已监听音量 (KVO+系统通知) 当前=%0.2f", [AVAudioSession sharedInstance].outputVolume);
            InstallKeyHook();
            KeepAudioSessionActive();
            float bootVol = [AVAudioSession sharedInstance].outputVolume;
            if (VolumeNeedsReset(bootVol)) {
                LogDVT(@"启动时音量=%.2f 已在边界，复位到 %.1f", bootVol, kResetVolume);
                SetSystemVolume(kResetVolume);
            }
            [[AutoSkipSettingsCenter shared] loadPoints];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIWindow *w = [UIApplication sharedApplication].keyWindow;
                if (w) [[AutoSkipSettingsCenter shared] installGestureInWindow:w];
                else LogDVT(@"等待 UIApplication 就绪后装三指手势");
            });
        });
    });
}
