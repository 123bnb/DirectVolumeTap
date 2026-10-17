// DirectVolumeTap v1.0.15 — 移除全部日志/诊断输出（LogDVT / DiagLog / ShowLogHint / DVTLogPath 及屏幕日志位置提醒），仅保留音量键翻页核心功能
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
// 日志：写 App 沙盒 Documents + NSLog，便于排查（固定路径 /var/mobile/... 与沙盒根目录无权限，已弃用）

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
static float DVTGetRate(void);         // 前向声明，定义见下方（openVolumeSettings 中设置滑块初值会先用到）
static void ApplyVolumeHudHidden(BOOL hidden);  // 前向声明，定义见下方（菜单开关与启动时调用）

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

// 隐藏音量条开关：默认开 = 隐藏系统音量条（保持当前默认行为）
static BOOL VolumeHudHidden(void) {
    id v = [Defaults() objectForKey:@"volumeHudHidden"];
    return v ? [v boolValue] : YES;
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
+ (void)dvtBeginTrail:(BOOL)isPlus firstPoint:(CGPoint)first;
+ (void)dvtExtendTrailTo:(CGPoint)pt isPlus:(BOOL)isPlus;
+ (void)dvtEndTrail;
+ (void)showBusyHint;
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
        }
    } else {
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
}

// ---------- 三指长按 → 菜单 ----------
- (void)installGestureInWindow:(UIWindow *)window {
    if (!window) return;
    UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(onThreeFingerTap:)];
    gr.numberOfTouchesRequired = 3;
    gr.minimumPressDuration = 0.5;
    [window addGestureRecognizer:gr];
}

- (void)onThreeFingerTap:(UIGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UIWindow *w = gr.view.window ?: [UIApplication sharedApplication].keyWindow;
    [self showMenuInWindow:w];
}

- (void)showMenuInWindow:(UIWindow *)window {
    if (!window) {  return; }
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
    CGFloat ph = 320;
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

    // 隐藏音量条开关行（打开=隐藏音量条，关闭=显示音量条，默认开=隐藏），位于【轨迹可视化】上方
    UIView *hudRow = [[UIView alloc] initWithFrame:CGRectMake(16, 210, pw - 32, 46)];
    hudRow.layer.cornerRadius = 10;
    hudRow.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
    [panel addSubview:hudRow];
    UILabel *hudLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, pw - 120, 46)];
    hudLabel.text = @"隐藏音量条";
    hudLabel.textColor = [UIColor darkGrayColor];
    hudLabel.font = [UIFont systemFontOfSize:16];
    [hudRow addSubview:hudLabel];
    UISwitch *hudSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 32 - 62, 7, 51, 31)];
    hudSwitch.on = VolumeHudHidden();
    [hudSwitch addTarget:self action:@selector(onVolumeHudSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [hudRow addSubview:hudSwitch];

    // 调试开关行（轨迹可视化）—— 顺序第 5 位
    UIView *dbgRow = [[UIView alloc] initWithFrame:CGRectMake(16, 262, pw - 32, 46)];
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

    // 回放速率行（滑动模式回放快慢 + 轨迹可视化同步），位于【轨迹可视化】与【模式入口】之间
    UIView *rateRow = [[UIView alloc] initWithFrame:CGRectMake(16, 158, pw - 32, 46)];
    rateRow.layer.cornerRadius = 10;
    rateRow.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
    [panel addSubview:rateRow];
    UILabel *rateTitle = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 84, 46)];
    rateTitle.text = @"回放速率";
    rateTitle.textColor = [UIColor darkGrayColor];
    rateTitle.font = [UIFont systemFontOfSize:16];
    [rateRow addSubview:rateTitle];
    UISlider *rateSlider = [[UISlider alloc] initWithFrame:CGRectMake(96, 8, (pw - 32) - 74 - 96 - 4, 30)];
    rateSlider.minimumValue = 0.5f;
    rateSlider.maximumValue = 2.0f;
    rateSlider.value = DVTGetRate();
    [rateSlider addTarget:self action:@selector(onRateChanged:) forControlEvents:UIControlEventValueChanged];
    [rateRow addSubview:rateSlider];
    UILabel *rateVal = [[UILabel alloc] initWithFrame:CGRectMake((pw - 32) - 74, 0, 62, 46)];
    rateVal.textAlignment = NSTextAlignmentRight;
    rateVal.textColor = [UIColor darkGrayColor];
    rateVal.font = [UIFont systemFontOfSize:14];
    rateVal.text = [NSString stringWithFormat:@"x%.1f", DVTGetRate()];
    rateVal.tag = 9911;   // 供 onRateChanged 实时更新
    [rateRow addSubview:rateVal];

    // 当前模式入口：点击模式 / 滑动模式 二选一，点进入对应设置 —— 顺序第 2 位
    UIButton *modeEntry = [UIButton buttonWithType:UIButtonTypeSystem];
    modeEntry.frame = CGRectMake(16, 106, pw - 32, 46);
    [modeEntry setTitle:(isSwipe ? @"滑动模式 ▸ 点击设置" : @"点击模式 ▸ 点击设置") forState:UIControlStateNormal];
    [modeEntry setTitleColor:[UIColor darkGrayColor] forState:UIControlStateNormal];
    modeEntry.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
    modeEntry.layer.cornerRadius = 10;
    [modeEntry addTarget:self action:(isSwipe ? @selector(openSwipeModeSettings) : @selector(openVolumeSettings)) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:modeEntry];

    [window addSubview:mv];
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
    if (!window) {  return; }

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
}

// ======== v1.0.1 滑动模式（抄袭 PageTurnerDylib 的【滑动(手动)】，完美复原真实滑动） ========
- (void)openSwipeModeSettings {
    [self closeMenu];
    UIWindow *window = FindKeyWindow();
    if (!window) {  return; }
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
}

- (void)onSwipeDone {
    [self saveSwipes];
    [self closeVolumeSettings];
    [self showMenuInWindow:[UIApplication sharedApplication].keyWindow];
}

// v1.0.5：回放速率变更（影响回放快慢 + 轨迹可视化同步）
- (void)onRateChanged:(UISlider *)s {
    float r = s.value;
    [Defaults() setObject:@(r) forKey:@"swipeRate"];
    [Defaults() synchronize];
    UILabel *lbl = (UILabel *)[s.superview viewWithTag:9911];
    if (lbl) lbl.text = [NSString stringWithFormat:@"x%.1f", r];
}

- (void)saveSwipes {
    NSUserDefaults *d = Defaults();
    [d setObject:(self.swipePlusPts ?: @[]) forKey:@"swipePlus"];
    [d setObject:(self.swipeMinusPts ?: @[]) forKey:@"swipeMinus"];
    [d synchronize];
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
    }
}

// ---------- 调试开关 ----------
- (void)onDebugSwitchChanged:(UISwitch *)sw {
    NSUserDefaults *d = Defaults();
    [d setBool:sw.on forKey:@"debugEnabled"];
    [d synchronize];
}

- (void)onVolumeHudSwitchChanged:(UISwitch *)sw {
    NSUserDefaults *d = Defaults();
    [d setObject:@(sw.on) forKey:@"volumeHudHidden"];
    [d synchronize];
    ApplyVolumeHudHidden(sw.on);
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

// v1.0.4：滑动回放轨迹可视化——增量绘制（O(1) 每帧 append，消除旧版全量重建 O(n²) 对主线程的拖累）
static CAShapeLayer *gDVTTrailLayer = nil;   // 回放轨迹层（复用，避免叠加）
static CGMutablePathRef gDVTTrailPath = NULL;

// 回放开始：创建轨迹层 + 可变路径，move 到第一点
+ (void)dvtBeginTrail:(BOOL)isPlus firstPoint:(CGPoint)first {
    UIWindow *w = FindKeyWindow();
    if (!w) return;
    if (gDVTTrailLayer) { [gDVTTrailLayer removeFromSuperlayer]; gDVTTrailLayer = nil; }
    if (gDVTTrailPath)  { CGPathRelease(gDVTTrailPath); gDVTTrailPath = NULL; }
    CAShapeLayer *sl = [CAShapeLayer layer];
    sl.strokeColor = (isPlus ? [UIColor systemGreenColor] : [UIColor systemRedColor]).CGColor;
    sl.fillColor   = [UIColor clearColor].CGColor;
    sl.lineWidth   = 6;
    sl.lineCap     = kCALineCapRound;
    sl.lineJoin    = kCALineJoinRound;
    sl.opacity     = 0.9;
    [w.layer addSublayer:sl];
    gDVTTrailLayer = sl;
    gDVTTrailPath  = CGPathCreateMutable();
    CGPathMoveToPoint(gDVTTrailPath, NULL, first.x, first.y);
    sl.path = gDVTTrailPath;
}

// 回放每帧：把当前插值点 append 到路径（增量，O(1)，不再全量重建）
+ (void)dvtExtendTrailTo:(CGPoint)pt isPlus:(BOOL)isPlus {
    if (!gDVTTrailLayer || !gDVTTrailPath) return;
    CGPathAddLineToPoint(gDVTTrailPath, NULL, pt.x, pt.y);
    gDVTTrailLayer.path = gDVTTrailPath;
}

// 回放结束：延迟移除轨迹层并释放路径
+ (void)dvtEndTrail {
    CAShapeLayer *sl = gDVTTrailLayer;
    gDVTTrailLayer = nil;
    if (gDVTTrailPath) { CGPathRelease(gDVTTrailPath); gDVTTrailPath = NULL; }
    if (!sl) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [sl removeFromSuperlayer]; });
}

// v1.0.4：防狂按提示——回放进行中再次触发音量键时，在屏幕顶部（灵动岛下方）浮现小字
static UILabel *gBusyHint = nil;
+ (void)showBusyHint {
    UIWindow *w = FindKeyWindow();
    if (!w) return;
    if (gBusyHint) { [gBusyHint removeFromSuperview]; gBusyHint = nil; }
    CGFloat topInset = 0;
    if (@available(iOS 11.0, *)) topInset = w.safeAreaInsets.top;
    CGFloat y = topInset + 44;
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(w.bounds.size.width/2 - 120, y, 240, 30)];
    h.text = @"请等待滑动完成";
    h.textColor = [UIColor whiteColor];
    h.textAlignment = NSTextAlignmentCenter;
    h.font = [UIFont systemFontOfSize:13];
    h.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
    h.layer.cornerRadius = 15;
    h.layer.masksToBounds = YES;
    [w addSubview:h];
    [w bringSubviewToFront:h];
    gBusyHint = h;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gBusyHint == h) { [h removeFromSuperview]; gBusyHint = nil; }
    });
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

// v1.0.4：滑动回放改用 CADisplayLink 驱动——对齐屏幕刷新率（VSync），
// 每帧按【真实经过时间】插值出当前触摸坐标并注入一次 Moved，彻底消除 dispatch_after 抖动导致的卡顿。
// 回放时长 = 录制时长（1:1 还原真实手指的流畅感）。
static BOOL gSwipeRunning = NO;   // 防狂按：回放进行中

@interface DVTSwipeTickProxy : NSObject
@property (nonatomic, copy) void (^tick)(void);
- (void)onTick:(CADisplayLink *)link;
@end
@implementation DVTSwipeTickProxy
- (void)onTick:(CADisplayLink *)link { if (_tick) _tick(); }
@end

// v1.0.5：回放上下文（全局单例），保证 invalidate / 收尾 成对，从根上杜绝狂按卡死
static CADisplayLink    *gSwipeLink = nil;
static DVTSwipeTickProxy *gSwipeProxy = nil;
static NSInteger         gSwipePid = -1;
static BOOL              gSwipeEnded = NO;    // 是否已注入 Ended（防重复注入）
static BOOL              gSwipeFinished = NO; // 是否已收尾（防重复收尾）
static dispatch_block_t  gSwipeWatchdog = nil;

// 回放速率（影响快慢，轨迹可视化同步），默认 1.0，范围 0.5~2.0
static float DVTGetRate(void) {
    float r = [[Defaults() objectForKey:@"swipeRate"] floatValue];
    if (r < 0.5f || r > 2.0f) r = 1.0f;
    return r;
}

// 回放收尾：只执行一次，成对清理 link / proxy / watchdog / 防狂按标志，绝不卡死
static void dvtFinishSwipe(void) {
    if (gSwipeFinished) return;
    gSwipeFinished = YES;
    if (gSwipeLink) { [gSwipeLink invalidate]; gSwipeLink = nil; }
    gSwipeProxy = nil;
    if (gSwipeWatchdog) { dispatch_block_cancel(gSwipeWatchdog); gSwipeWatchdog = nil; }
    gSwipeRunning = NO;
}

// 按时间线性插值取坐标（二分定位区间）
static CGPoint DVTSwipeInterp(NSArray *xs, NSArray *ys, NSArray *ts, double targetT) {
    NSUInteger m = [ts count];
    if (m == 0) return CGPointZero;
    double t0 = [ts[0] doubleValue], tEnd = [ts[m-1] doubleValue];
    if (targetT <= t0)   return CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]);
    if (targetT >= tEnd) return CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
    NSUInteger lo = 0, hi = m - 1;
    while (hi - lo > 1) {
        NSUInteger mid = (lo + hi) / 2;
        if ([ts[mid] doubleValue] <= targetT) lo = mid; else hi = mid;
    }
    double ta = [ts[lo] doubleValue], tb = [ts[hi] doubleValue];
    double fa = [xs[lo] doubleValue], fb = [xs[hi] doubleValue];
    double ga = [ys[lo] doubleValue], gb = [ys[hi] doubleValue];
    double f = (tb - ta) > 1e-6 ? (targetT - ta) / (tb - ta) : 0.0;
    return CGPointMake(fa + (fb - fa) * f, ga + (gb - ga) * f);
}

static void DVTFakeSwipe(NSArray *pts, BOOL isPlus) {
    if (!pts || [pts count] < 2) { gSwipeRunning = NO; return; }
    // 预解析 [x,y,t]，避免每帧反复解包
    NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array], *ts = [NSMutableArray array];
    for (NSUInteger i = 0; i < [pts count]; i++) {
        NSArray *p = pts[i];
        if ([p count] < 3) continue;
        [xs addObject:@([p[0] floatValue])];
        [ys addObject:@([p[1] floatValue])];
        [ts addObject:@([p[2] doubleValue])];
    }
    NSUInteger m = [ts count];
    if (m < 2) { gSwipeRunning = NO; return; }
    double t0 = [ts[0] doubleValue];
    double totalMs = [ts[m-1] doubleValue] - t0;
    if (totalMs <= 0) totalMs = 1.0;
    float rate = DVTGetRate();
    double effTotal = totalMs / rate;   // 速率>1 更快，<1 更慢

    // 初始化回放上下文
    gSwipePid = -1;
    gSwipeEnded = NO;
    gSwipeFinished = NO;
    gSwipeRunning = YES;
    gSwipeProxy = [[DVTSwipeTickProxy alloc] init];
    __block CFAbsoluteTime startT = CFAbsoluteTimeGetCurrent();
    gSwipeLink = [CADisplayLink displayLinkWithTarget:gSwipeProxy selector:@selector(onTick:)];
    [gSwipeLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    if ([AutoSkipSettingsCenter isDebugEnabled]) {
        [AutoSkipSettingsCenter dvtBeginTrail:isPlus firstPoint:CGPointMake([xs[0] doubleValue], [ys[0] doubleValue])];
    }

    gSwipeProxy.tick = ^{
        double elapsedMs = (CFAbsoluteTimeGetCurrent() - startT) * 1000.0;
        double targetT = t0 + elapsedMs * rate;   // 按速率推进插值时间
        CGPoint cur = DVTSwipeInterp(xs, ys, ts, targetT);
        if (gSwipePid < 0) gSwipePid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:cur withTouchPhase:UITouchPhaseBegan];
        else               [PTFakeMetaTouch fakeTouchId:gSwipePid AtPoint:cur withTouchPhase:UITouchPhaseMoved];
        if ([AutoSkipSettingsCenter isDebugEnabled]) [AutoSkipSettingsCenter dvtExtendTrailTo:cur isPlus:isPlus];
        if (elapsedMs >= effTotal) {
            CGPoint end = CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
            if (!gSwipeEnded) {
                [PTFakeMetaTouch fakeTouchId:gSwipePid AtPoint:end withTouchPhase:UITouchPhaseEnded];
                gSwipeEnded = YES;
            }
            if ([AutoSkipSettingsCenter isDebugEnabled]) {
                [AutoSkipSettingsCenter dvtExtendTrailTo:end isPlus:isPlus];
                [AutoSkipSettingsCenter dvtEndTrail];
            }
            dvtFinishSwipe();
        }
    };

    // v1.0.5：兜底看门狗——无论 DisplayLink 是否触发末帧，到 effTotal+120ms 必强制收尾，
    // 杜绝「狂按导致末帧未触发 → gSwipeRunning 永久卡死」的问题。
    double wdogMs = effTotal + 120.0;
    dispatch_block_t wdog = dispatch_block_create(0, ^{
        if (gSwipeFinished) return;
        CGPoint end = CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
        if (gSwipePid >= 0 && !gSwipeEnded) {
            [PTFakeMetaTouch fakeTouchId:gSwipePid AtPoint:end withTouchPhase:UITouchPhaseEnded];
            gSwipeEnded = YES;
        }
        if ([AutoSkipSettingsCenter isDebugEnabled]) [AutoSkipSettingsCenter dvtEndTrail];
        dvtFinishSwipe();
    });
    gSwipeWatchdog = wdog;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wdogMs * NSEC_PER_SEC / 1000.0)),
                   dispatch_get_main_queue(), wdog);
}

// 按方向点击/滑动：delta>0 音量+，delta<0 音量-
static void TapPoints(float delta) {
    BOOL isPlus = (delta > 0);
    // v1.0.1：滑动模式 → 按录制轨迹完美回放
    if ([[Defaults() objectForKey:@"mode"] isEqualToString:@"swipe"]) {
        if (gSwipeRunning) {   // 防狂按：回放进行中，拦截新触发并提示
            [AutoSkipSettingsCenter showBusyHint];
            return;
        }
        NSArray *pts = isPlus ? LoadSwipePts(@"swipePlus") : LoadSwipePts(@"swipeMinus");
        if (pts.count < 2) {
            ShowToast([NSString stringWithFormat:@"滑动模式未录制%@轨迹", isPlus ? @"音量+" : @"音量-"]);
            return;
        }
        gSwipeRunning = YES;   // 标记回放中（狂按将被拦截）
        // fakeTouchId 必须主线程：切主队列，由 DVTFakeSwipe 内部 CADisplayLink(main) 逐帧回放
        dispatch_async(dispatch_get_main_queue(), ^{ DVTFakeSwipe(pts, isPlus); });
        return;
    }
    // 点击模式（原逻辑不变）
    CGPoint p = isPlus ? [AutoSkipSettingsCenter pointForPlus] : [AutoSkipSettingsCenter pointForMinus];
    if (p.x == NSNotFound || p.y == NSNotFound) {
        ShowToast([NSString stringWithFormat:@"音量%@ 未设坐标，三指长按设置", isPlus ? @"+" : @"-"]);
        return;
    }
    UIWindow *w = FindKeyWindow();
    if (!w) {  return; }
    // 同样保证 fakeTouchId 在主线程（音量监听 KVO 可能在非主线程回调）
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
        usleep(30000);
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
        // 调试开关打开时才显示点击轨迹；关闭则完全隐形
        if ([AutoSkipSettingsCenter isDebugEnabled]) {
            [AutoSkipSettingsCenter showDebugMarkerAtPoint:p isPlus:isPlus];
        }
    });
}

// 去抖窗口：仅合并「单次按键产生的重复 KVO」（通常 < 100ms），
// 不再吞掉用户有意的快速连按（原 250ms 过激，翻页连按常被吞）
static const double kTapDebounceSec = 0.10;
// 单次音量键步长约 0.05；按 delta 估算被合并的按键次数，连按合并也能逐页翻（防被吞）
static const float kVolumeStep = 0.05f;
static CFAbsoluteTime gLastTap = 0;
static void TapPointsDebounced(float delta) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastTap < kTapDebounceSec) {  return; }
    gLastTap = now;
    // 滑动模式：一次触发一次回放即可
    if ([[Defaults() objectForKey:@"mode"] isEqualToString:@"swipe"]) {
        TapPoints(delta);
        return;
    }
    // 点击模式：按 delta 估算按键次数，连按被合并成一次大跳变时也能每个按键翻一页
    int n = (int)(fabsf(delta) / kVolumeStep + 0.5f);
    if (n < 1) n = 1;
    if (n > 8) n = 8;   // 防止极端跳变刷屏
    for (int i = 0; i < n; i++) TapPoints(delta);
}

// 钉音量：MPVolumeView 抑制 HUD + AVSystemController 设回固定值（方案 B）
static MPVolumeView *gVolView = nil;
// 应用「隐藏音量条」开关：隐藏→确保 MPVolumeView 挂载（抑制系统 HUD）；显示→移除 MPVolumeView（让系统 HUD 正常弹出）
static void ApplyVolumeHudHidden(BOOL hidden) {
    if (hidden) {
        if (!gVolView) {
            gVolView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 0, 0)];
        }
        UIWindow *w = FindKeyWindow();
        if (w && !gVolView.superview) [w addSubview:gVolView];
    } else {
        if (gVolView) { [gVolView removeFromSuperview]; gVolView = nil; }
    }
}
static void SetSystemVolume(float v) {
    @try {
        if (!gVolView && VolumeHudHidden()) {
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
    }
    @try {
        // iOS 16.5 上单参数 setVolumeTo: 不存在（会抛 unrecognized selector），
        // 正确私有 API 是 setVolumeTo:forCategory:，且 float 参数必须用 NSInvocation 正确传递。
        Class c = NSClassFromString(@"AVSystemController");
        if (c) {
            id controller = [c performSelector:NSSelectorFromString(@"sharedAVSystemController")];
            SEL sel = NSSelectorFromString(@"setVolumeTo:forCategory:");
            if (controller && [controller respondsToSelector:sel]) {
                NSMethodSignature *sig = [controller methodSignatureForSelector:sel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:sel];
                    [inv setTarget:controller];
                    float fv = v;
                    [inv setArgument:&fv atIndex:2];
                    NSString *cat = @"Audio/Video";
                    [inv setArgument:&cat atIndex:3];
                    [inv invoke];
                } else {
                }
            } else {
            }
        }
    } @catch (NSException *e) {
    }
}

// 方案 B：把音量「钉死」在固定值。每次检测到音量偏离 gPinnedVolume（即用户按了音量键），
// 立即同步把音量设回 gPinnedVolume，既不漂移也不触底，HUD 不再闪烁/循环。
// 回写判定不再依赖易竞态的全局 flag：回写时音量必等于 gPinnedVolume，故按 now 是否≈钉定值来区分。
static float gPinnedVolume = 0.5f;   // 钉在中间，远离 0/1 两端，保证 + / - 都能产生可检测的变化

// 同步把音量钉回固定值（不延迟）
static void PinVolume(void) {
    SetSystemVolume(gPinnedVolume);
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
    if (!newN) return;
    float now = newN.floatValue;
    float old = oldN ? oldN.floatValue : -1.0f;
    float diff = fabsf(now - gPinnedVolume);
    float rawDelta = oldN ? (now - old) : 0.0f;
    // 回写/稳态：我们把音量钉回 gPinnedVolume，回写时 now 恰好等于钉定值 → 忽略（无 flag 竞态，不会吞真实按键）
    if (diff < 0.02f) {
        return;
    }
    // 真实按键：now 偏离钉定值。delta 以钉定为基准，规避 old 被回写污染的竞态
    float delta = now - gPinnedVolume;
    TapPointsDebounced(delta);            // 用这次变化触发点击（+ / - 由 delta 符号决定）
    PinVolume();                          // 立即同步钉回固定值（消除边界循环，下一轮 now==gPinnedVolume 自动忽略）
}
- (void)volChanged:(NSNotification *)notif {
    // v1.0.1：已删除空壳实现（KVO 已负责，避免重复触发通道）
}
@end

// 注：已移除方案 A（hook UIApplication _handleKeyUIEvent: 吞音量键）。
// 非越狱注入环境下，系统音量由 SpringBoard/音频守护进程在 App 进程外改写，
// UIKit 事件层处于下游，吞键无法阻止系统音量变化；且该 hook 的 keyCode 取不到值实际为空转。
// 现统一走方案 B：KVO 检测变化 + 同步钉回固定音量 + MPVolumeView 抑制 HUD。

// 关键：保持音频会话活跃（KVO outputVolume 才触发）
static AVAudioEngine *gEngine = nil;
static void KeepAudioSessionActive(void) {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient error:&err];
    if (err) 
    [session setActive:YES error:&err];
    if (err) 
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
        if (err) 
        [player play];
    } @catch (NSException *e) {
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
            gObs = [DirectVolumeObserver new];
            [[AVAudioSession sharedInstance] addObserver:gObs
                                              forKeyPath:@"outputVolume"
                                                 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                                                 context:NULL];
            // v1.0.1：删除系统通知观察者注册（volChanged: 空壳，KVO 已负责，避免重复触发通道）
            KeepAudioSessionActive();
            ApplyVolumeHudHidden(VolumeHudHidden());   // 先尝试挂载（窗口可能尚未就绪，下面 1s 后会再挂载一次）
            float bootVol = [AVAudioSession sharedInstance].outputVolume;
            if (fabsf(bootVol - gPinnedVolume) > 0.02f) {
                PinVolume();
            }
            [[AutoSkipSettingsCenter shared] loadPoints];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIWindow *w = [UIApplication sharedApplication].keyWindow;
                if (w) {
                    ApplyVolumeHudHidden(VolumeHudHidden());   // 窗口就绪后再挂载 MPVolumeView（修复冷启动 HUD 不隐藏）
                    [[AutoSkipSettingsCenter shared] installGestureInWindow:w];
                }
            });
        });
    });
}
