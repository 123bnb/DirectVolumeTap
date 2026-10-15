// DirectVolumeTap v1.0.3 — 独立版（自包含，注入即生效）
// 不依赖任何设置页/配置：把 dylib 注入哪个 App，就在哪个 App 生效。
//   ① 三指长按 → 弹出「菜单」：
//        - 音量键设置（可点进去）：出现一红一绿两个大圆点，可自由拖动，
//          上方绿点 = 音量键 + 的点击位置，下方红点 = 音量键 - 的点击位置；
//          底部有「保存」「复位」两个按钮（保存记录坐标并关闭；复位回到初始位置）。
//        - 调试开关（纯开关）：默认关闭。打开后，按物理音量键触发的点击
//          会在点击位置显示对应颜色的大圆点轨迹；关闭则点击完全隐形。
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

// ---------- 日志：多路径 + NSLog（v1.0.1：调试关时零 IO，对齐兄弟插件） ----------
static BOOL DebugEnabled(void);        // 前向声明，定义见下方
static UIWindow *FindKeyWindow(void);  // 前向声明，定义见下方（showDebugMarkerAtPoint 复用）
static NSString *LogPath1 = @"/var/mobile/Library/Preferences/com.yourname.directvolumetap.log";
static void LogDVT(NSString *fmt, ...) {
    if (!DebugEnabled()) return;   // v1.0.1：调试开关关（默认）时不写盘、不 NSLog，零热路径开销
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

// 调试开关默认关闭；打开时按音量键点击会显示轨迹标注
static BOOL DebugEnabled(void) {
    return [[Defaults() objectForKey:@"debugEnabled"] boolValue];
}

// =====================================================
// AutoSkipSettingsCenter（三指菜单 + 音量键设置子界面 + 调试开关）
// =====================================================
@interface AutoSkipSettingsCenter : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *menuView;        // 三指长按弹出的菜单
@property (nonatomic, strong) UIView *overlay;          // 音量键设置子界面覆盖层
@property (nonatomic, strong) UISwitch *debugSwitch;    // 调试开关
@property (nonatomic, strong) NSMutableArray<NSValue *> *points;  // [0]=音量+(绿,上) [1]=音量-(红,下)
@property (nonatomic, strong) NSMutableArray<UIView *> *dotViews; // 与 points 对应的圆点视图
+ (instancetype)shared;
- (void)installGestureInWindow:(UIWindow *)window;
- (void)onThreeFingerTap:(UIGestureRecognizer *)gr;
- (void)showMenuInWindow:(UIWindow *)window;
- (void)closeMenu;
- (void)openVolumeSettings;
- (void)closeVolumeSettings;
- (void)resetPoints;
- (void)refreshMarkers;
- (void)loadPoints;
- (void)savePoints;
- (void)onDotPan:(UIPanGestureRecognizer *)pan;
- (void)onDebugSwitchChanged:(UISwitch *)sw;
+ (BOOL)isDebugEnabled;
+ (CGPoint)pointForPlus;
+ (CGPoint)pointForMinus;
+ (void)showDebugMarkerAtPoint:(CGPoint)p isPlus:(BOOL)isPlus;
// v1.0.1：滑动模式（抄袭 PageTurnerDylib 的【滑动(手动)】）
- (void)toggleVolumeMode;                          // 菜单：音量键模式 点击模式 ↔ 滑动模式
- (void)openSwipeModeSettings;                     // 滑动模式设置页
- (void)onSwipePan:(UIPanGestureRecognizer *)pan;  // 录制滑动
- (void)resetSwipes;
- (void)onSwipeDone;
- (void)saveSwipes;
- (void)loadSwipes;
- (void)drawSwipeTrails;
- (void)drawPath:(NSArray *)pts color:(UIColor *)color alpha:(CGFloat)alpha;
+ (void)dvtBeginTrail:(BOOL)isPlus;
+ (void)dvtUpdateTrail:(NSArray *)pts upTo:(NSUInteger)count isPlus:(BOOL)isPlus;
+ (void)dvtEndTrail;
@property (nonatomic, strong) NSMutableArray *swipePlusPts;        // 音量+ 轨迹点(NSArray<[x,y,t]>)
@property (nonatomic, strong) NSMutableArray *swipeMinusPts;       // 音量- 轨迹点
@property (nonatomic, strong) NSMutableArray *currentRecording;
@property (nonatomic, assign) NSInteger recordStage;              // 0=录第一条 1=录第二条 2=满
@property (nonatomic, assign) CFAbsoluteTime recordStart;
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *swipeLayers;
@end

@implementation AutoSkipSettingsCenter

+ (instancetype)shared {
    static AutoSkipSettingsCenter *s = nil;
    static dispatch_once_t on;
    dispatch_once(&on, ^{ s = [AutoSkipSettingsCenter new]; });
    return s;
}

// 载入坐标；若无保存则用默认 = 屏幕中心：上方绿+=、下方红-=
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
        CGSize scr = [UIScreen mainScreen].bounds.size;
        if (scr.width > 0 && scr.height > 0) {
            CGFloat cx = scr.width / 2;
            // 上方绿点 = 音量+ ；下方红点 = 音量-
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

// 保存（points[0]=音量+绿，points[1]=音量-红）
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

// ---------- 三指长按 → 菜单 ----------
- (void)installGestureInWindow:(UIWindow *)window {
    if (!window) return;
    UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(onThreeFingerTap:)];
    gr.numberOfTouchesRequired = 3;
    gr.minimumPressDuration = 0.5;
    [window addGestureRecognizer:gr];
    LogDVT(@"三指长按手势已安装");
}

- (void)onThreeFingerTap:(UIGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UIWindow *w = gr.view.window ?: [UIApplication sharedApplication].keyWindow;
    LogDVT(@"三指手势触发 → 显示菜单");
    [self showMenuInWindow:w];
}

- (void)showMenuInWindow:(UIWindow *)window {
    if (!window) { LogDVT(@"菜单失败: 无窗口"); return; }
    [self closeMenu];
    [self closeVolumeSettings];

    UIView *mv = [[UIView alloc] initWithFrame:window.bounds];
    mv.userInteractionEnabled = YES;
    self.menuView = mv;

    // 点空白处关闭菜单（面板内/控件上的触摸交给控件自身，不触发关闭）
    UITapGestureRecognizer *bg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeMenu)];
    bg.delegate = self;
    [mv addGestureRecognizer:bg];

    // 菜单面板
    CGFloat pw = MIN(window.bounds.size.width - 40, 320);
    CGFloat ph = 256;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((window.bounds.size.width - pw)/2,
                                                             (window.bounds.size.height - ph)/2,
                                                             pw, ph)];
    panel.backgroundColor = [UIColor whiteColor];
    panel.layer.cornerRadius = 14;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.3;
    panel.layer.shadowOffset = CGSizeMake(0, 2);
    panel.layer.shadowRadius = 6;
    [mv addSubview:panel];

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 18, pw, 28)];
    title.text = @"设置";
    title.textColor = [UIColor darkGrayColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    [panel addSubview:title];

    // 左上角关闭按钮（关闭插件菜单）
    UIButton *closeTL = [UIButton buttonWithType:UIButtonTypeSystem];
    closeTL.frame = CGRectMake(10, 10, 56, 32);
    [closeTL setTitle:@"关闭" forState:UIControlStateNormal];
    [closeTL setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeTL.backgroundColor = [UIColor systemGrayColor];
    closeTL.layer.cornerRadius = 8;
    closeTL.titleLabel.font = [UIFont systemFontOfSize:14];
    [closeTL addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeTL];

    // 「音量键模式」整行：点击在 点击模式/滑动模式 之间切换
    BOOL isSwipe = [[[Defaults() objectForKey:@"mode"] description] isEqualToString:@"swipe"];
    UIButton *modeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    modeBtn.frame = CGRectMake(16, 56, pw - 32, 46);
    [modeBtn setTitle:[NSString stringWithFormat:@"音量键模式：%@", isSwipe ? @"滑动模式" : @"点击模式"] forState:UIControlStateNormal];
    [modeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    modeBtn.backgroundColor = [UIColor systemBlueColor];
    modeBtn.layer.cornerRadius = 10;
    [modeBtn addTarget:self action:@selector(toggleVolumeMode) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:modeBtn];

    // 当前模式入口：点击模式 / 滑动模式 二选一，点进入对应设置
    UIButton *modeEntry = [UIButton buttonWithType:UIButtonTypeSystem];
    modeEntry.frame = CGRectMake(16, 110, pw - 32, 46);
    [modeEntry setTitle:(isSwipe ? @"滑动模式 ▸ 点击设置" : @"点击模式 ▸ 点击设置") forState:UIControlStateNormal];
    [modeEntry setTitleColor:[UIColor darkGrayColor] forState:UIControlStateNormal];
    modeEntry.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
    modeEntry.layer.cornerRadius = 10;
    [modeEntry addTarget:self action:(isSwipe ? @selector(openSwipeModeSettings) : @selector(openVolumeSettings)) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:modeEntry];

    // 调试开关行
    UIView *dbgRow = [[UIView alloc] initWithFrame:CGRectMake(16, 168, pw - 32, 46)];
    dbgRow.layer.cornerRadius = 10;
    dbgRow.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
    [panel addSubview:dbgRow];
    UILabel *dbgLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, pw - 120, 46)];
    dbgLabel.text = @"轨迹可视化";
    dbgLabel.textColor = [UIColor darkGrayColor];
    dbgLabel.font = [UIFont systemFontOfSize:16];
    [dbgRow addSubview:dbgLabel];
    self.debugSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 32 - 62, 7, 51, 31)];
    self.debugSwitch.on = DebugEnabled();
    [self.debugSwitch addTarget:self action:@selector(onDebugSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [dbgRow addSubview:self.debugSwitch];

    [window addSubview:mv];
    LogDVT(@"菜单已显示");
}

- (void)closeMenu {
    if (self.menuView) { [self.menuView removeFromSuperview]; self.menuView = nil; }
}

// 背景手势只响应直接点在 menuView 空白上的触摸（面板/按钮/开关上的触摸不关闭菜单）
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    if (gr.view == self.menuView && touch.view == self.menuView) return YES;
    return NO;
}

// ---------- 音量键设置子界面 ----------
- (void)openVolumeSettings {
    [self closeMenu];
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) { LogDVT(@"设置失败: 无 keyWindow"); return; }

    UIView *ov = [[UIView alloc] initWithFrame:window.bounds];
    ov.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    ov.userInteractionEnabled = YES;
    self.overlay = ov;
    [window addSubview:ov];

    // 顶部提示条
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, window.bounds.size.width, 44)];
    tip.text = @"（点击模式）拖动圆点设定「音量+ / 音量-」点击位置";
    tip.textColor = [UIColor whiteColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
    tip.font = [UIFont boldSystemFontOfSize:15];
    [ov addSubview:tip];

    // 复位（左） / 保存（右）
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(20, window.bounds.size.height - 90, 120, 48);
    [reset setTitle:@"复位" forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reset.backgroundColor = [UIColor systemOrangeColor];
    reset.layer.cornerRadius = 10;
    [reset addTarget:self action:@selector(resetPoints) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:reset];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(window.bounds.size.width - 150, window.bounds.size.height - 90, 130, 48);
    [save setTitle:@"保存" forState:UIControlStateNormal];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.backgroundColor = [UIColor systemGreenColor];
    save.layer.cornerRadius = 10;
    [save addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:save];

    [self refreshMarkers];
    LogDVT(@"点击模式子界面已显示");
}

// ======== v1.0.1 滑动模式（抄袭 PageTurnerDylib 的【滑动(手动)】，完美复原真实滑动） ========
- (void)openSwipeModeSettings {
    [self closeMenu];
    UIWindow *window = FindKeyWindow();
    if (!window) { LogDVT(@"滑动模式设置失败: 无 keyWindow"); return; }
    [self loadSwipes];
    self.swipeLayers = [NSMutableArray array];

    UIView *ov = [[UIView alloc] initWithFrame:window.bounds];
    ov.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    ov.userInteractionEnabled = YES;
    self.overlay = ov;
    [window addSubview:ov];

    // 顶部提示条
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, 90, window.bounds.size.width, 60)];
    tip.text = @"（滑动模式）第一次滑动=音量+，第二次=音量-，轨迹不消失";
    tip.textColor = [UIColor whiteColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.numberOfLines = 2;
    tip.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
    tip.font = [UIFont boldSystemFontOfSize:14];
    [ov addSubview:tip];

    // 复位（左） / 完成（右）
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(20, window.bounds.size.height - 90, 120, 48);
    [reset setTitle:@"复位" forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reset.backgroundColor = [UIColor systemOrangeColor];
    reset.layer.cornerRadius = 10;
    [reset addTarget:self action:@selector(resetSwipes) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:reset];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(window.bounds.size.width - 150, window.bounds.size.height - 90, 130, 48);
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    done.backgroundColor = [UIColor systemGreenColor];
    done.layer.cornerRadius = 10;
    [done addTarget:self action:@selector(onSwipeDone) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:done];

    // 录制手势：整个覆盖层接收 pan（先录音量+，再录音量-）
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onSwipePan:)];
    [ov addGestureRecognizer:pan];

    [self drawSwipeTrails];
    LogDVT(@"滑动模式子界面已显示");
}

- (void)onSwipePan:(UIPanGestureRecognizer *)pan {
    if (!self.overlay) return;
    if (self.recordStage >= 2) return;   // 两条已录满，需复位才能重录
    CGPoint loc = [pan locationInView:self.overlay];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.currentRecording = [NSMutableArray array];
        self.recordStart = CFAbsoluteTimeGetCurrent();
        [self.currentRecording addObject:@[@(loc.x), @(loc.y), @0]];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (!self.currentRecording) return;
        NSArray *last = [self.currentRecording lastObject];
        CGPoint lp = CGPointMake([last[0] floatValue], [last[1] floatValue]);
        if (hypot(loc.x - lp.x, loc.y - lp.y) >= 3.0f) {   // 距离阈值，防过密
            float t = (CFAbsoluteTimeGetCurrent() - self.recordStart) * 1000.0f;
            [self.currentRecording addObject:@[@(loc.x), @(loc.y), @(t)]];
            [self drawSwipeTrails];   // 实时显示录制轨迹
        }
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        if (!self.currentRecording) return;
        float t = (CFAbsoluteTimeGetCurrent() - self.recordStart) * 1000.0f;
        [self.currentRecording addObject:@[@(loc.x), @(loc.y), @(t)]];
        if (self.recordStage == 0) self.swipePlusPts = [self.currentRecording mutableCopy];
        else if (self.recordStage == 1) self.swipeMinusPts = [self.currentRecording mutableCopy];
        self.recordStage++;
        self.currentRecording = nil;
        [self drawSwipeTrails];
        LogDVT(@"滑动录制完成 stage=%ld 点数=%lu", (long)(self.recordStage - 1), (unsigned long)self.swipePlusPts.count + self.swipeMinusPts.count);
    }
}

- (void)drawSwipeTrails {
    if (!self.overlay) return;
    for (CALayer *l in self.swipeLayers) [l removeFromSuperlayer];
    [self.swipeLayers removeAllObjects];
    [self drawPath:self.swipePlusPts color:[UIColor systemGreenColor] alpha:0.9];    // 音量+ 绿
    [self drawPath:self.swipeMinusPts color:[UIColor systemRedColor] alpha:0.9];    // 音量- 红
    if (self.currentRecording) [self drawPath:self.currentRecording color:[UIColor systemYellowColor] alpha:0.6];
}

- (void)drawPath:(NSArray *)pts color:(UIColor *)color alpha:(CGFloat)alpha {
    if (!pts || pts.count < 2) return;
    UIBezierPath *path = [UIBezierPath new];
    for (NSUInteger i = 0; i < pts.count; i++) {
        NSArray *p = pts[i];
        if (p.count < 2) continue;
        CGPoint pt = CGPointMake([p[0] floatValue], [p[1] floatValue]);
        if (i == 0) [path moveToPoint:pt]; else [path addLineToPoint:pt];
    }
    CAShapeLayer *sl = [CAShapeLayer new];
    sl.path = path.CGPath;
    sl.strokeColor = color.CGColor;
    sl.lineWidth = 6;
    sl.fillColor = [UIColor clearColor].CGColor;
    sl.lineCap = kCALineCapRound;
    sl.lineJoin = kCALineJoinRound;
    sl.opacity = alpha;
    [self.overlay.layer addSublayer:sl];
    [self.swipeLayers addObject:sl];
}

- (void)resetSwipes {
    self.swipePlusPts = [NSMutableArray array];
    self.swipeMinusPts = [NSMutableArray array];
    self.currentRecording = nil;
    self.recordStage = 0;
    [self drawSwipeTrails];
    LogDVT(@"滑动轨迹已复位，可重新录制");
}

- (void)onSwipeDone {
    [self saveSwipes];
    [self closeVolumeSettings];
    [self showMenuInWindow:[UIApplication sharedApplication].keyWindow];
}

- (void)saveSwipes {
    NSUserDefaults *d = Defaults();
    [d setObject:(self.swipePlusPts ?: @[]) forKey:@"swipePlus"];
    [d setObject:(self.swipeMinusPts ?: @[]) forKey:@"swipeMinus"];
    [d synchronize];
    LogDVT(@"已保存滑动轨迹 +:%lu -:%lu", (unsigned long)self.swipePlusPts.count, (unsigned long)self.swipeMinusPts.count);
}

- (void)loadSwipes {
    NSUserDefaults *d = Defaults();
    self.swipePlusPts = [NSMutableArray arrayWithArray:[d arrayForKey:@"swipePlus"] ?: @[]];
    self.swipeMinusPts = [NSMutableArray arrayWithArray:[d arrayForKey:@"swipeMinus"] ?: @[]];
    self.currentRecording = nil;
    self.recordStage = (self.swipeMinusPts.count ? 2 : (self.swipePlusPts.count ? 1 : 0));
}

- (void)toggleVolumeMode {
    NSString *cur = [[Defaults() objectForKey:@"mode"] description];
    [Defaults() setObject:([cur isEqualToString:@"swipe"] ? @"tap" : @"swipe") forKey:@"mode"];
    [Defaults() synchronize];
    LogDVT(@"音量键模式切换 -> %@", [cur isEqualToString:@"swipe"] ? @"点击模式" : @"滑动模式");
    [self closeMenu];
    [self showMenuInWindow:[UIApplication sharedApplication].keyWindow];
}

- (void)onSave {
    [self savePoints];
    [self closeVolumeSettings];
    // 保存后回到菜单，方便继续调调试开关或退出
    [self showMenuInWindow:[UIApplication sharedApplication].keyWindow];
}

- (void)closeVolumeSettings {
    if (self.overlay) { [self.overlay removeFromSuperview]; self.overlay = nil; }
    [self.dotViews removeAllObjects];
}

// 复位：圆点回到初始位置（屏幕上下中心），不关闭界面、不保存
- (void)resetPoints {
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat cx = scr.width / 2;
    if (self.points.count >= 2) {
        self.points[0] = [NSValue valueWithCGPoint:CGPointMake(cx, scr.height * 0.30)];
        self.points[1] = [NSValue valueWithCGPoint:CGPointMake(cx, scr.height * 0.70)];
    }
    [self refreshMarkers];
    LogDVT(@"已复位圆点到初始位置");
}

// 画大圆点：index0=绿+（上） index1=红-（下），可拖动
- (void)refreshMarkers {
    if (!self.overlay) return;
    for (UIView *v in self.dotViews) [v removeFromSuperview];
    self.dotViews = [NSMutableArray array];

    if (!self.points) [self loadPoints];
    for (NSUInteger i = 0; i < self.points.count; i++) {
        CGPoint p = self.points[i].CGPointValue;
        BOOL isPlus = (i == 0);
        CGFloat d = 66.0;
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(p.x - d/2, p.y - d/2, d, d)];
        dot.backgroundColor = isPlus ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        dot.layer.cornerRadius = d/2;
        dot.layer.masksToBounds = YES;
        dot.alpha = 0.85;
        dot.layer.borderWidth = 3;
        dot.layer.borderColor = [UIColor whiteColor].CGColor;

        UILabel *lb = [[UILabel alloc] initWithFrame:dot.bounds];
        lb.text = isPlus ? @"+" : @"-";
        lb.textColor = [UIColor whiteColor];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.font = [UIFont boldSystemFontOfSize:30];
        [dot addSubview:lb];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDotPan:)];
        [dot addGestureRecognizer:pan];

        [self.overlay addSubview:dot];
        [self.dotViews addObject:dot];
        LogDVT(@"圆点%d 位于 (%.0f,%.0f)", (int)i, p.x, p.y);
    }
}

// 拖动圆点 → 更新坐标
- (void)onDotPan:(UIPanGestureRecognizer *)pan {
    if (!pan.view) return;
    NSUInteger idx = [self.dotViews indexOfObject:pan.view];
    if (idx == NSNotFound || idx >= self.points.count) return;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint trans = [pan translationInView:self.overlay];
        CGPoint center = pan.view.center;
        CGPoint newCenter = CGPointMake(center.x + trans.x, center.y + trans.y);
        pan.view.center = newCenter;
        [pan setTranslation:CGPointZero inView:self.overlay];
        self.points[idx] = [NSValue valueWithCGPoint:newCenter];
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        LogDVT(@"圆点%d 最终位置 (%.0f,%.0f)", (int)idx, pan.view.center.x, pan.view.center.y);
    }
}

// ---------- 调试开关 ----------
- (void)onDebugSwitchChanged:(UISwitch *)sw {
    NSUserDefaults *d = Defaults();
    [d setBool:sw.on forKey:@"debugEnabled"];
    [d synchronize];
    LogDVT(@"轨迹可视化 -> %@", sw.on ? @"开" : @"关");
}

+ (BOOL)isDebugEnabled {
    return DebugEnabled();
}

// ---------- 坐标访问（供触发模块读取） ----------
+ (CGPoint)pointForPlus {
    AutoSkipSettingsCenter *c = [AutoSkipSettingsCenter shared];
    if (c.points.count > 0) return c.points[0].CGPointValue;
    return CGPointMake(NSNotFound, NSNotFound);
}
+ (CGPoint)pointForMinus {
    AutoSkipSettingsCenter *c = [AutoSkipSettingsCenter shared];
    if (c.points.count > 1) return c.points[1].CGPointValue;
    return CGPointMake(NSNotFound, NSNotFound);
}

// 调试轨迹：在点击位置显示对应颜色的大圆点，短暂停留后消失
// 关键：marker 必须 userInteractionEnabled=NO（触摸穿透，不拦截下层 App 的点击，
//       否则模拟触摸会点到自己身上导致无法连续点触）；并复用单个 marker，
//       避免同位置多次点击叠加变实。
+ (void)showDebugMarkerAtPoint:(CGPoint)p isPlus:(BOOL)isPlus {
    static UIView *gDebugMarker = nil;   // 复用一个 marker，防止叠加
    if (gDebugMarker) { [gDebugMarker removeFromSuperview]; gDebugMarker = nil; }

    UIWindow *w = FindKeyWindow();   // v1.0.1：复用下方 FindKeyWindow，去重复
    if (!w) return;

    CGFloat d = 66.0;
    UIView *marker = [[UIView alloc] initWithFrame:CGRectMake(p.x - d/2, p.y - d/2, d, d)];
    marker.backgroundColor = isPlus ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    marker.layer.cornerRadius = d/2;
    marker.layer.masksToBounds = YES;
    marker.alpha = 0.8;
    marker.layer.borderWidth = 3;
    marker.layer.borderColor = [UIColor whiteColor].CGColor;
    marker.userInteractionEnabled = NO;   // 触摸穿透，不拦截下层点击
    UILabel *lb = [[UILabel alloc] initWithFrame:marker.bounds];
    lb.text = isPlus ? @"+" : @"-";
    lb.textColor = [UIColor whiteColor];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.font = [UIFont boldSystemFontOfSize:30];
    [marker addSubview:lb];
    gDebugMarker = marker;
    [w addSubview:marker];
    [w bringSubviewToFront:marker];
    UIView *keepAlive = marker;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [keepAlive removeFromSuperview];
        if (gDebugMarker == keepAlive) gDebugMarker = nil;
    });
}

// v1.0.2：滑动回放轨迹可视化——抄袭 PageTurner deb 版的「逐点累积重绘 path」机制
// 原 showDebugSwipeTrail 在回放【全部结束】后才画整条线 → 「滑完才闪现」；
// 改为：回放每注入一点就实时延伸轨迹（对应 PT 的 PTRecTick / gRecTrailLayer 逐点更新 path）。
static CAShapeLayer *gDVTTrailLayer = nil;   // 回放轨迹层（复用，避免叠加）

// 回放开始：创建轨迹层并挂到 keyWindow
+ (void)dvtBeginTrail:(BOOL)isPlus {
    UIWindow *w = FindKeyWindow();
    if (!w) return;
    if (gDVTTrailLayer) { [gDVTTrailLayer removeFromSuperlayer]; gDVTTrailLayer = nil; }
    CAShapeLayer *sl = [CAShapeLayer layer];
    sl.strokeColor = (isPlus ? [UIColor systemGreenColor] : [UIColor systemRedColor]).CGColor;
    sl.fillColor   = [UIColor clearColor].CGColor;
    sl.lineWidth   = 6;
    sl.lineCap     = kCALineCapRound;
    sl.lineJoin    = kCALineJoinRound;
    sl.opacity     = 0.9;
    [w.layer addSublayer:sl];
    gDVTTrailLayer = sl;
}

// 回放过程中：把已注入的前 count 个点重绘成路径（逐点延伸，对应 PTRecTick）
+ (void)dvtUpdateTrail:(NSArray *)pts upTo:(NSUInteger)count isPlus:(BOOL)isPlus {
    if (!gDVTTrailLayer || !pts || count == 0) return;
    CGMutablePathRef path = CGPathCreateMutable();
    BOOL first = YES;
    for (NSUInteger i = 0; i < count && i < pts.count; i++) {
        NSArray *p = pts[i];
        if (p.count < 3) continue;
        CGPoint pt = CGPointMake([p[0] floatValue], [p[1] floatValue]);
        if (first) { CGPathMoveToPoint(path, NULL, pt.x, pt.y); first = NO; }
        else       { CGPathAddLineToPoint(path, NULL, pt.x, pt.y); }
    }
    gDVTTrailLayer.path = path;
    CGPathRelease(path);
}

// 回放结束：延迟移除轨迹层
+ (void)dvtEndTrail {
    CAShapeLayer *sl = gDVTTrailLayer;
    gDVTTrailLayer = nil;
    if (!sl) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [sl removeFromSuperlayer]; });
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

// v1.0.1：读滑动轨迹点（NSArray<[x,y,t]>）
static NSArray *LoadSwipePts(NSString *key) {
    NSArray *a = [Defaults() arrayForKey:key];
    return a ?: @[];
}

// v1.0.1：按录制时间戳逐点注入，完美复原真实滑动。
// 关键修复：fakeTouchId 是 UIKit 事件注入，必须在【主线程】调用。
// 原实现把它丢到后台 gSwipeQueue 导致 UIKit/CoreAnimation 在后台线程断言陷阱（EXC_BREAKPOINT 闪退）。
// 改为照搬 PageTurnerDylib 验证过的「主线程 dispatch_after 递归调度」：不阻塞主线程，且全程在主线程。
static void DVTFakeSwipe(NSArray *pts, BOOL isPlus) {
    if (!pts || pts.count < 2) return;
    __block NSInteger pid = -1;
    __block NSUInteger idx = 0;
    __block void (^step)(void);
    step = ^(void) {
        if (idx >= pts.count) {
            LogDVT(@"滑动模式回放 %@ 完成 点数=%lu", isPlus ? @"音量+" : @"音量-", (unsigned long)pts.count);
            if ([AutoSkipSettingsCenter isDebugEnabled]) [AutoSkipSettingsCenter dvtEndTrail];
            return;
        }
        NSArray *p = pts[idx];
        if (p.count < 3) { idx++; step(); return; }   // 跳过坏点
        float x = [p[0] floatValue], y = [p[1] floatValue];
        float t = [p[2] floatValue];   // 相对录制起点的毫秒
        CGPoint pt = CGPointMake(x, y);
        UITouchPhase ph = (idx == 0) ? UITouchPhaseBegan
                        : ((idx == pts.count - 1) ? UITouchPhaseEnded : UITouchPhaseMoved);
        if (idx == 0) {
            pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:pt withTouchPhase:ph];
            // 轨迹可视化（抄袭 PT deb 版 PTRecTick：回放开始即逐点延伸，而非结束才闪现）
            if ([AutoSkipSettingsCenter isDebugEnabled]) {
                [AutoSkipSettingsCenter dvtBeginTrail:isPlus];
                [AutoSkipSettingsCenter dvtUpdateTrail:pts upTo:1 isPlus:isPlus];
            }
        } else {
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pt withTouchPhase:ph];
            if ([AutoSkipSettingsCenter isDebugEnabled]) {
                [AutoSkipSettingsCenter dvtUpdateTrail:pts upTo:(idx + 1) isPlus:isPlus];
            }
        }
        idx++;
        if (idx >= pts.count) {
            LogDVT(@"滑动模式回放 %@ 完成 点数=%lu", isPlus ? @"音量+" : @"音量-", (unsigned long)pts.count);
            if ([AutoSkipSettingsCenter isDebugEnabled]) [AutoSkipSettingsCenter dvtEndTrail];
            return;
        }
        // 与下一点之间的等待（基于录制时间戳，最小 8ms 防风暴——PageTurnerDylib 同款）
        NSArray *nxt = pts[idx];
        float waitMs = (nxt.count >= 3) ? ([nxt[2] floatValue] - t) : 8.0f;
        if (waitMs < 8.0f) waitMs = 8.0f;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitMs * NSEC_PER_SEC / 1000)),
                       dispatch_get_main_queue(), step);
    };
    step();
}

// 按方向点击/滑动：delta>0 音量+，delta<0 音量-
static void TapPoints(float delta) {
    BOOL isPlus = (delta > 0);
    // v1.0.1：滑动模式 → 按录制轨迹完美回放
    if ([[Defaults() objectForKey:@"mode"] isEqualToString:@"swipe"]) {
        NSArray *pts = isPlus ? LoadSwipePts(@"swipePlus") : LoadSwipePts(@"swipeMinus");
        if (pts.count < 2) {
            LogDVT(@"滑动模式：%@ 未录制轨迹（三指长按→滑动模式设置）", isPlus ? @"音量+" : @"音量-");
            ShowToast([NSString stringWithFormat:@"滑动模式未录制%@轨迹", isPlus ? @"音量+" : @"音量-"]);
            return;
        }
        // fakeTouchId 必须主线程：先切主队列，由 DVTFakeSwipe 内部递归 dispatch_after(main) 逐点回放
        dispatch_async(dispatch_get_main_queue(), ^{ DVTFakeSwipe(pts, isPlus); });
        return;
    }
    // 点击模式（原逻辑不变）
    CGPoint p = isPlus ? [AutoSkipSettingsCenter pointForPlus] : [AutoSkipSettingsCenter pointForMinus];
    if (p.x == NSNotFound || p.y == NSNotFound) {
        LogDVT(@"音量%@：无对应坐标（请三指长按→点击模式设置）", isPlus ? @"+" : @"-");
        ShowToast([NSString stringWithFormat:@"音量%@ 未设坐标，三指长按设置", isPlus ? @"+" : @"-"]);
        return;
    }
    UIWindow *w = FindKeyWindow();
    if (!w) { LogDVT(@"音量触发：无 keyWindow"); return; }
    // 同样保证 fakeTouchId 在主线程（音量监听 KVO 可能在非主线程回调）
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
        usleep(30000);
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
        LogDVT(@"音量%@→点击 (%d, %d) pointId=%ld", isPlus ? @"+" : @"-", (int)p.x, (int)p.y, (long)pid);
        // 调试开关打开时才显示点击轨迹；关闭则完全隐形
        if ([AutoSkipSettingsCenter isDebugEnabled]) {
            [AutoSkipSettingsCenter showDebugMarkerAtPoint:p isPlus:isPlus];
        }
    });
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

static const float kResetVolume = 0.1f;   // 复位目标音量（改为 0.1）
static const float kBoundHigh = 0.85f;
static const float kBoundLow  = 0.05f;    // 触底阈值须低于复位目标0.1，避免复位后仍被判触底反复复位
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
    // 插件复位副作用识别：旧值在边界外(触顶/触底)、新值≈复位目标0.3，
    // 说明这是插件把音量拉回中间造成的，不是用户按键，不触发点击。
    // 真实按键单次只变一小档，不可能从边界外一下跳到0.3，故不会误伤真实操作。
    if (VolumeNeedsReset(old) && fabsf(now - kResetVolume) < 0.05f) {
        LogDVT(@"复位副作用(%.2f→%.2f)，不触发点击", old, now);
        return;
    }
    LogDVT(@"音量%@ delta=%+.2f 当前=%0.2f → 触发", delta > 0 ? @"+" : @"-", delta, now);
    TapPointsDebounced(delta);
    DoReset(old, now);
}
- (void)volChanged:(NSNotification *)notif {
    // v1.0.1：已删除空壳实现（KVO 已负责，避免重复触发通道）
}
@end

// 第三重：hook UIApplication _handleKeyUIEvent: 捕获音量键
static IMP gOrigHandleKeyUIEvent = NULL;
static void dvtHandleKeyUIEvent(id self, SEL _cmd, id event) {
    @try {
        UIEvent *ev = (UIEvent *)event;
        long keyCode = [[ev valueForKey:@"keyCode"] longValue];
        if (keyCode == 0xE8 || keyCode == 0xE9) {
            LogDVT(@"★捕获音量键 keyCode=0x%lX（已拦截，不转发系统，HUD 不弹出）", keyCode);
            TapPointsDebounced((keyCode == 0xE9) ? 0.05f : -0.05f);
            return;   // 吞掉按键事件：系统收不到按键 → 音量不变 → 系统音量条(HUD)不再弹出
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
static DirectVolumeObserver *gObs = nil;

__attribute__((constructor))
static void DirectTapInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            LogDVT(@"[DirectVolumeTap v1.0.1 已注入] 进程=%@ bundleID=%@",
                   NSProcessInfo.processInfo.processName,
                   [[NSBundle mainBundle] bundleIdentifier]);
            gObs = [DirectVolumeObserver new];
            [[AVAudioSession sharedInstance] addObserver:gObs
                                              forKeyPath:@"outputVolume"
                                                 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                                                 context:NULL];
            // v1.0.1：删除系统通知观察者注册（volChanged: 空壳，KVO 已负责，避免重复触发通道）
            LogDVT(@"已监听音量 (KVO) 当前=%0.2f", [AVAudioSession sharedInstance].outputVolume);
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
