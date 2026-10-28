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
        SLFInstallHooks();

        SLFLogAlways(@"---------- 初始化完成 ----------");
        SLFLogAlways(@"提示：新建一个快捷指令，然后查看本日志。");
        SLFLogAlways(@"      [stall] 行 = 卡顿现场栈，直接指出阻塞在哪个函数。");
        SLFLogAlways(@"      [slow] 行 = 单个方法耗时超阈值。");
        SLFLogAlways(@"      [vc] 行 = 界面类名，用于确认进入了哪个页面。");
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