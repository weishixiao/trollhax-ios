//
//  SpeedHUDView.h
//  TrollHaxHUD
//
//  网速 HUD 公共接口（参考 TrollSpeed，MIT）
//

#import <UIKit/UIKit.h>

/// 网速采样器：getifaddrs + if_data 字节计数器差分
@interface THSpeedMonitor : NSObject
/// 当前下行速率（字节/秒）
@property (nonatomic, readonly) double downloadSpeed;
/// 当前上行速率（字节/秒）
@property (nonatomic, readonly) double uploadSpeed;
/// 是否已建立基线（首次采样只记录基准，不产生速率）
@property (nonatomic, readonly) BOOL hasBaseline;
/// 采样一次。返回 YES 表示本次产生了有效速率；
/// 间隔过短、计数器回绕或数值异常时返回 NO 并保持上一次的值。
- (BOOL)sampleNow;
- (void)reset;
@end

/// 网速显示层：贴屏幕顶部安全区的一块小标签，不拦截触摸
@interface THSpeedHUDView : UIView
+ (instancetype)sharedIfEnabled;
- (void)start;
- (void)stop;
- (void)refreshTick;
/// 在指定窗口内按安全区定位（顶部居中）
- (void)layoutInWindow:(UIWindow *)window;
@property (nonatomic, assign) BOOL showOnlyWhenActive;
@end

/// 把字节/秒格式化成 Kb/s / Mb/s / Gb/s（比特口径，与 TrollSpeed 一致）
NSString *THFormatSpeed(double bytesPerSecond);
