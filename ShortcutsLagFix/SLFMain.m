//
//  SLFMain.m
//  ShortcutsLagFix
//
//  dylib 入口。
//
//  启动阶段原则（本项目血泪教训）：
//   1. 构造函数整体 @try/@catch —— 任何异常都不允许影响宿主启动。
//   2. 启动日志无条件落盘并自报：版本 / 宿主 / 架构 / 日志路径 / jbroot /
//      每个 hook 的成败。否则"没日志"会被误判成"没加载"。
//   3. 所有工作延迟到主线程 runloop 启动之后再装，
//      避免在 dyld 加载期抢占宿主初始化（那里崩溃最难查）。
//

#import "SLFCommon.h"
#import <UIKit/UIKit.h>
#import <pthread.h>
#import <sys/utsname.h>

// 只在目标 App 内工作。注入配置已限定 Bundle，
// 这里再判一次是防御性措施 —— 万一 plist 过滤失效，也不会污染其他进程。
static void SLFMainThreadSetup(void);

static void SLFScheduleSetup(void) {
    // 延迟到主线程空闲时执行：此时 UIKit 已初始化完毕，装 hook 最安全。
    dispatch_async(dispatch_get_main_queue(), ^{
        SLFMainThreadSetup();
    });
}

static void SLFMainThreadSetup(void) {
    @try {
        SLFLogAlways(@"---------- 初始化开始 ----------");

        // 看门狗依赖主线程，必须在主线程启动。
        SLFStartWatchdog();

        // hook 安装。内部有 pthread_once 幂等保护。
        // 注意：子类扫描已经搬进后台队列，所以这一步只花几毫秒
        // （用户日志里旧版这一步之后还多花了 631ms 扫描全部类，属自身负优化）。
        SLFInstallHooks();

        // 预热一次性系统初始化。内部自己排队到后台并延迟，
        // 因此这一行本身不产生任何主线程开销。
        SLFWarmupStart();

        SLFLogAlways(@"---------- 初始化完成 ----------");
        SLFLogAlways(@"提示：新建一个快捷指令，然后查看本日志。");
        SLFLogAlways(@"      [stall] 行 = 卡顿现场。已自动标注「类型」与「本段」；");
        SLFLogAlways(@"                  同一段持续阻塞会多次上报，切勿把毫秒数累加，");
        SLFLogAlways(@"                  段真实总长见紧随其后的「上一段结束」行。");
        SLFLogAlways(@"                  「上一段结束」行还会报「本行落盘滞后 X 秒」——");
        SLFLogAlways(@"                  滞后大说明看门狗自己被打断过，那段时间是观测盲区。");
        SLFLogAlways(@"                  栈帧格式为「镜像名 0x偏移」，偏移相对该镜像基址，");
        SLFLogAlways(@"                  可直接 atos 符号化；near 后面只是最近导出符号，仅作参考。");
        SLFLogAlways(@"                  若某帧真的算不出偏移，会明确写「偏移不可用 raw=0x…」");
        SLFLogAlways(@"                  并附原始地址 —— 绝不给一个看着像偏移的假值。");
        SLFLogAlways(@"      [stall] 本段主线程状态 / PC 重复率 = v1.0.6 的关键判据：");
        SLFLogAlways(@"                  「主队列繁忙」= 主线程在干活，只是心跳排不上队；");
        SLFLogAlways(@"                  「真卡在等待上」= 等锁/等 IPC，属于 hang。");
        SLFLogAlways(@"                  两者修法完全不同，不要混为一谈。");
        SLFLogAlways(@"      [warmup] 行 = 预热埋点。v1.0.5 起预热默认关闭（WarmupEnabled=NO），");
        SLFLogAlways(@"                  因为实测它反而与主线程争 CoreNLP 锁。");
        SLFLogAlways(@"      [slow] 行 = 单个方法耗时超阈值（仅覆盖未覆写该方法的子类）。");
    } @catch (__unused NSException *e) {
        SLFLogAlways(@"主线程初始化异常: %@", e);
    }
}

__attribute__((constructor))
static void SLFInit(void) {
    @try {
        // 先无条件落盘环境信息（绕过 DebugLog 门禁）。
        // 这几行是判断"插件到底有没有被加载"的唯一可靠证据。
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        SLFLogAlways(@"========================================");
        SLFLogAlways(@"ShortcutsLagFix v%s 已加载", SLF_VERSION);
        SLFLogAlways(@"宿主 bundle id : %@", bid ?: @"(nil)");

        // 架构自证：如果这里看到 arm64 而设备是 arm64e，
        // 说明拿到了单切片产物，hook 可能整体失效。
#if defined(__arm64e__)
        SLFLogAlways(@"编译架构       : arm64e");
#elif defined(__arm64__)
        SLFLogAlways(@"编译架构       : arm64");
#else
        SLFLogAlways(@"编译架构       : 非 arm64");
#endif

        struct utsname u;
        if (uname(&u) == 0) {
            SLFLogAlways(@"设备/系统      : %s / %s", u.machine, u.version);
        }

        SLFLogAlways(@"日志落盘路径   : %@", SLFLogPath() ?: @"(所有候选路径均不可写!)");
        SLFLogAlways(@"jbroot         : %@", SLFJBPath() ?: @"(未能反推)");
        SLFLogAlways(@"========================================");

        if (!SLFIsTargetApp()) {
            SLFLogAlways(@"非目标 App，不执行任何 hook。");
            return;
        }

        // 主线程还没起来时不要直接装 hook。
        if (pthread_main_np()) {
            SLFScheduleSetup();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                SLFScheduleSetup();
            });
        }
    } @catch (__unused NSException *e) {
        // 构造函数里绝不允许异常逃逸。
        SLFLogAlways(@"构造函数异常: %@", e);
    }
}