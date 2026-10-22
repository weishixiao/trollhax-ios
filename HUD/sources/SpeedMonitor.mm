//
//  SpeedMonitor.mm
//  TrollHaxHUD
//
//  网速采样（参考 TrollSpeed 的 getUpDownBytes，MIT）
//
//  原理：getifaddrs() 遍历 en* / pdp_ip* 接口，累加 if_data 的
//  ifi_ibytes / ifi_obytes，两次采样差除以间隔即得瞬时速率。
//
//  与 TrollSpeed 的差异：
//  - 累计计数器是 32 位且会回绕，直接相减会在回绕时得到巨大的负值/正值，
//    这里用「无符号回绕安全」的差值计算，并对异常大值做丢弃。
//  - 只统计 IFF_UP 且 IFF_RUNNING 的接口。
//

#import <Foundation/Foundation.h>
// 与 SpeedHUDView.h 里的 THFormatSpeed / THSpeedMonitor 声明保持一致
#import "SpeedHUDView.h"
#import <ifaddrs.h>
#import <net/if.h>
// struct if_data（ifi_ibytes / ifi_obytes）在 iOS SDK 中声明于此
#import <net/if_var.h>
// AF_LINK 与 sockaddr_dl
#import <net/if_dl.h>
#import <sys/socket.h>

typedef struct {
    uint64_t inputBytes;
    uint64_t outputBytes;
} THUpDownBytes;

static THUpDownBytes THReadInterfaceCounters(void)
{
    THUpDownBytes r;
    r.inputBytes = 0;
    r.outputBytes = 0;

    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == -1 || list == NULL) return r;

    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_name == NULL || ifa->ifa_addr == NULL || ifa->ifa_data == NULL) continue;
        // 只处理链路层(含流量统计)接口
        if (ifa->ifa_addr->sa_family != AF_LINK) continue;
        // 未启用/未运行的接口跳过
        if (!(ifa->ifa_flags & IFF_UP) || !(ifa->ifa_flags & IFF_RUNNING)) continue;
        // 以太网(en0=WiFi) 或 蜂窝(pdp_ipN)
        if (strncmp(ifa->ifa_name, "en", 2) != 0 &&
            strncmp(ifa->ifa_name, "pdp_ip", 6) != 0) continue;

        struct if_data *d = (struct if_data *)ifa->ifa_data;
        if (d == NULL) continue;
        r.inputBytes  += (uint64_t)d->ifi_ibytes;
        r.outputBytes += (uint64_t)d->ifi_obytes;
    }
    freeifaddrs(list);
    return r;
}

@implementation THSpeedMonitor {
    THUpDownBytes _prev;
    NSTimeInterval _prevTime;
    double _down;
    double _up;
    BOOL _hasBaseline;
}

- (double)downloadSpeed { return _down; }
- (double)uploadSpeed { return _up; }
- (BOOL)hasBaseline { return _hasBaseline; }

- (void)reset
{
    _prev = (THUpDownBytes){0, 0};
    _prevTime = 0;
    _down = 0;
    _up = 0;
    _hasBaseline = NO;
}

- (BOOL)sampleNow
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    THUpDownBytes cur = THReadInterfaceCounters();

    if (!_hasBaseline || _prevTime <= 0) {
        _prev = cur;
        _prevTime = now;
        _hasBaseline = YES;
        return NO;   // 首次仅建立基线
    }

    NSTimeInterval dt = now - _prevTime;
    // 间隔太短会让整数差值的量化误差放大成巨大速率
    if (dt < 0.05) return NO;

    // 无符号回绕安全：cur 小于 prev 说明计数器回绕（32 位 uint 约 4GB 一次，
    // 大流量下几分钟就可能发生），此时按 32 位回绕补正
    uint64_t inDelta = cur.inputBytes >= _prev.inputBytes
        ? cur.inputBytes - _prev.inputBytes
        : (UINT32_MAX - _prev.inputBytes) + cur.inputBytes + 1;
    uint64_t outDelta = cur.outputBytes >= _prev.outputBytes
        ? cur.outputBytes - _prev.outputBytes
        : (UINT32_MAX - _prev.outputBytes) + cur.outputBytes + 1;

    _prev = cur;
    _prevTime = now;

    // 合理性上限：1 Gbps ≈ 131 MB/s。超过说明采样异常（接口热插拔计数重置等），丢弃本次
    const double kMaxBytesPerSec = 200.0 * 1024 * 1024;
    double down = (double)inDelta / dt;
    double up   = (double)outDelta / dt;
    if (down > kMaxBytesPerSec || up > kMaxBytesPerSec) return NO;

    _down = down;
    _up = up;
    return YES;
}

@end

#pragma mark - 格式化

/// 与 TrollSpeed 一致的显示口径：以**比特**为单位（Kb/s / Mb/s / Gb/s）。
NSString *THFormatSpeed(double bytesPerSecond)
{
    double bits = bytesPerSecond * 8.0;
    const double K = 1000.0, M = 1000.0 * 1000.0, G = 1000.0 * 1000.0 * 1000.0;
    if (bits < K)      return [NSString stringWithFormat:@"%.0f B/s", bytesPerSecond];
    if (bits < M)      return [NSString stringWithFormat:@"%.0f Kb/s", bits / K];
    if (bits < G)      return [NSString stringWithFormat:@"%.2f Mb/s", bits / M];
    return [NSString stringWithFormat:@"%.2f Gb/s", bits / G];
}
