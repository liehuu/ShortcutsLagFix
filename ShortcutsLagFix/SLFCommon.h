//
//  SLFCommon.h
//  ShortcutsLagFix
//
//  公共声明。所有跨文件符号必须在此声明，
//  避免 "implicit declaration / no known method" 类编译失败。
//

#ifndef SLF_COMMON_H
#define SLF_COMMON_H

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdatomic.h>
#import <mach/mach_time.h>

// ★ 版本号由构建时从 control 注入（build.sh 传 -DSLF_VERSION=\"x.y.z\"）。
//
// 绝不再在此写死字面量。实测教训：这里曾固定为 "1.0.0"，之后 control 依次
// 升到 1.0.1 / 1.0.2 / 1.0.3，而**三次交付的日志全都自报 v1.0.0**。
// 拿到用户日志时我第一反应是"你装的是旧包吧"，等于让工具自己制造假线索。
//
// 兜底值故意写得刺眼：一旦构建脚本漏了注入，日志会直接印出
// 0.0.0-unknown，而不是谎报一个看起来正常的版本号。
#ifndef SLF_VERSION
#define SLF_VERSION "0.0.0-unknown"
#endif

#pragma mark - 日志

/// 异步写日志（受 DebugLog 开关控制）。热路径专用。
void SLFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 同步写日志，绕过 DebugLog 门禁。仅启动阶段使用。
/// 原因：若诊断开关本身读不到，必须保证决定性信息仍能落盘。
void SLFLogAlways(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 日志实际落盘路径（多候选试写后自报，绝不猜）。
NSString *SLFLogPath(void);

/// 从自身 dylib 路径反推 jbroot（RootHide 下唯一可靠来源）。
NSString *SLFJBPath(void);

#pragma mark - 配置

/// 从 plist 文件直读（绕过 NSUserDefaults，RootHide 下后者读不到 deb 预置值）。
BOOL SLFBool(NSString *key, BOOL def);
NSInteger SLFInt(NSString *key, NSInteger def);

#pragma mark - 时间与统计

/// 单调纳秒时间戳。
uint64_t SLFNowNS(void);

/// 耗时统计桶。全 C11 原子，可从任意线程并发累加。
typedef struct {
    _Atomic int64_t calls;
    _Atomic int64_t totalNS;
    _Atomic int64_t maxNS;
    _Atomic int64_t slow;      // 单次超过阈值的次数
} SLFStat;

void SLFStatRecord(SLFStat *s, uint64_t ns);
void SLFStatReset(SLFStat *s);

/// 汇总一行可读文本，例如 "calls=12 avg=3.1ms max=88.0ms"
NSString *SLFStatDescribe(SLFStat *s);

#pragma mark - 子系统

void SLFStartWatchdog(void);
void SLFInstallHooks(void);

/// 后台预热一次性系统初始化（字体 / 词典 trie / ImageIO）。
/// ★ 默认关闭（WarmupEnabled=NO）。实测证明语言分析预热会与主线程争
///   CoreNLP/liblangid 锁，把主线程拖住，因此该段已整段移除。
void SLFWarmupStart(void);

/// 主线程当前是否仍在正常响应（最近 200ms 内刷新过心跳）。
/// 预热的礼貌退让判据：主线程正卡着的时候不要再叠加负载。
BOOL SLFMainThreadResponsive(void);

/// 输出各 hook 的耗时统计（由看门狗定时调用）。
void SLFDumpStats(void);

/// 建立"已加载 image 表"（dyld 报的基址），供栈帧归属判定使用。
/// 必须在主线程、早于第一次抓栈调用；重复调用无副作用（幂等）。
/// ★ 为什么需要它：从栈内存读出的返回地址带 PAC 签名，而签名位落在
///   48 位地址之内，任何掩码都剥不干净。改用"最大 base ≤ addr"定归属，
///   再以 addr - base 算偏移 —— 只依赖 dyld 给的干净基址，不猜哪些位可信。
void SLFBuildImageTable(void);

/// 宿主是否为本插件目标 App（防御性检查，避免注入出错 App）。
BOOL SLFIsTargetApp(void);

#endif /* SLF_COMMON_H */