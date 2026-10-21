//
//  SpeedHUDView.mm
//  TrollHaxHUD
//
//  网速显示层：独立于角色动画的一块小标签，贴屏幕顶部。
//  默认关闭，由启动参数 -speed 1 打开（主 App 设置页控制）。
//

#import "SpeedHUDView.h"

@implementation THSpeedHUDView {
    UILabel *_label;
    NSTimer *_timer;
    THSpeedMonitor *_monitor;
    BOOL _started;
    int _idleTicks;
}

+ (instancetype)sharedIfEnabled
{
    static THSpeedHUDView *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[THSpeedHUDView alloc] initWithFrame:CGRectZero];
    });
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    // 尺寸按内容自适应，先给个占位
    if (self = [super initWithFrame:CGRectMake(0, 0, 120, 22)]) {
        _monitor = [[THSpeedMonitor alloc] init];
        _showOnlyWhenActive = NO;

        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
        self.userInteractionEnabled = NO;      // 纯显示，不挡触摸
        self.hidden = YES;

        _label = [[UILabel alloc] initWithFrame:self.bounds];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor whiteColor];
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.7;
        _label.text = @"↓ 0 Kb/s  ↑ 0 Kb/s";
        [self addSubview:_label];
    }
    return self;
}

/// 放到屏幕顶部中间（避开刘海/灵动岛），跟随安全区
- (void)layoutInWindow:(UIWindow *)window
{
    if (window == nil) return;
    CGFloat safeTop = 0;
    if (@available(iOS 11.0, *)) safeTop = window.safeAreaInsets.top;
    CGSize fit = [_label sizeThatFits:CGSizeMake(240, 22)];
    CGFloat w = ceil(fit.width) + 16.0;
    CGFloat h = 22.0;
    CGFloat x = (window.bounds.size.width - w) / 2.0;
    CGFloat y = safeTop + 4.0;
    self.frame = CGRectMake(x, y, w, h);
    _label.frame = CGRectMake(8, 0, w - 16, h);
}

- (void)start
{
    if (_started) return;
    _started = YES;
    [_monitor reset];
    self.hidden = NO;
    // 1s 一次；TrollSpeed 也是这个量级，够用且几乎不耗电
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(refreshTick)
                                            userInfo:nil
                                             repeats:YES];
    // 拖动 HUD 时主 runloop 可能进 tracking mode，这里补一条保证刷新不断
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)stop
{
    _started = NO;
    [_timer invalidate];
    _timer = nil;
    self.hidden = YES;
}

- (void)refreshTick
{
    BOOL valid = [_monitor sampleNow];
    if (!valid && !_monitor.hasBaseline) return;

    double down = _monitor.downloadSpeed;
    double up = _monitor.uploadSpeed;

    _label.text = [NSString stringWithFormat:@"↓ %@  ↑ %@",
                   THFormatSpeed(down), THFormatSpeed(up)];

    // 重新按文本宽度贴合
    CGSize fit = [_label sizeThatFits:CGSizeMake(260, 22)];
    CGFloat w = ceil(fit.width) + 16.0;
    CGRect f = self.frame;
    f.size.width = w;
    // 居中于父视图（保持 x 跟随屏幕中心，避免宽度变化时左右跳动）
    if (self.superview) {
        f.origin.x = (self.superview.bounds.size.width - w) / 2.0;
    }
    self.frame = f;
    _label.frame = CGRectMake(8, 0, w - 16, f.size.height);

    if (_showOnlyWhenActive) {
        // 连续 3 秒近乎无流量才隐藏，避免抖动闪烁
        if (down < 200 && up < 200) {
            if (++_idleTicks >= 3) self.hidden = YES;
        } else {
            _idleTicks = 0;
            self.hidden = NO;
        }
    }
}

@end
