//
//  SLFWatchdog.m
//  ShortcutsLagFix
//
//  主线程卡顿监测器。
//
//  为什么需要它：用户报"新建快捷指令时非常卡"，但"卡"是主观描述。
//  可能是 UIKit 布局、CoreData 查询、SwiftUI diff、或 App 自身同步 IO。
//  在没有仪器的情况下，唯一能定性的是：在卡住的瞬间抓主线程真实调用栈。
//
//  两个互补的观测手段：
//   1. CFRunLoopObserver —— 精确测量主线程每轮忙碌时长（事后统计）。
//   2. 后台看门狗线程 —— 主线程被阻塞时从外部抓栈（实时现场）。
//      仅靠 1 不够：主线程被完全阻塞时 runloop observer 自己不回滚，测不到。
//
//  安全性：
//   - 抓栈用 vm_read_overwrite 读自己进程内存，越界只会返回错误码，不会崩。
//   - 全部包 @try/@catch；任何失败都静默降级为"无栈"。
//   - 看门狗线程本身不碰 UI、不持锁调用宿主代码。
//

#import "SLFCommon.h"
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>
#import <pthread.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - 地址掩码

// arm64e 下 pc / fp / lr 可能带 PAC 签名位，需要掩码后才能当普通地址用。
// 必须保留 48 位：iOS 用户态地址空间上界在 48 位内，但线程栈常位于
// 0x16_xxxx_xxxx 一带（约 90GB），若只保留 36 位会被截断 → dladdr 失败 → 栈无法符号化。
#define SLF_USER_VA_MASK 0x0000FFFFFFFFFFFFULL
#define SLF_STRIP(p) ((uint64_t)(p) & SLF_USER_VA_MASK)

#pragma mark - 心跳

static _Atomic uint64_t gLastBeatNS = 0;
static _Atomic bool gBeatPending = false;
static _Atomic uint32_t gMainThreadPort = 0;
static _Atomic bool gWatchdogRunning = false;

// 卡顿时长统计（用于日志摘要，不参与判定）
static SLFStat gStallStat;

// 去重与配额：放在文件作用域，避免函数内 static 的初始化时机歧义。
static _Atomic bool gReporting = false;
static _Atomic int  gReportCount = 0;
static _Atomic uint64_t gLastReportedNS = 0;

#pragma mark - 栈回溯

#define SLF_MAX_FRAMES 48

// 统一的寄存器读取封装。
// arm64e 的 __pc/__fp/__lr 带 PAC 签名，SDK 要求通过 __darwin_arm_thread_state64_get_*
// 访问器读取（内部自动剥离签名）；纯 arm64 也提供了同名宏，可直接用。
#if defined(__arm64e__)
  #define SLFGetPC(st) __darwin_arm_thread_state64_get_pc(*(st))
  #define SLFGetFP(st) __darwin_arm_thread_state64_get_fp(*(st))
  #define SLFGetLR(st) __darwin_arm_thread_state64_get_lr(*(st))
#else
  #define SLFGetPC(st) ((uint64_t)((st)->__pc))
  #define SLFGetFP(st) ((uint64_t)((st)->__fp))
  #define SLFGetLR(st) ((uint64_t)((st)->__lr))
#endif

// noinline：保证这些函数自己在栈上有独立帧，不会被优化掉导致回溯错位。
__attribute__((noinline))
static void SLFCaptureThreadStack(mach_port_t thread, NSString **outText) {
    if (thread == MACH_PORT_NULL) {
        *outText = @"(无法获取主线程 mach port)";
        return;
    }

#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) {
        *outText = [NSString stringWithFormat:@"(thread_get_state 失败 kr=%d)", kr];
        return;
    }

    // ★ arm64e 关键差异：__pc / __fp / __lr 是带指针认证（PAC）的字段，
    // 不能直接当 uint64_t 读 —— 在 arm64e 上直接访问会拿到带签名位的值，
    // 甚至编译告警。必须走 SDK 提供的访问器，它们内部会正确剥离签名。
    uint64_t pc = SLFGetPC(&state);
    uint64_t fp = SLFGetFP(&state);
    uint64_t lr = SLFGetLR(&state);
    pc = SLF_STRIP(pc);
    fp = SLF_STRIP(fp);
    lr = SLF_STRIP(lr);

    NSMutableString *sb = [NSMutableString string];
    [sb appendFormat:@"    主线程 PC=0x%llx\n", pc];

    task_t task = mach_task_self();
    uint64_t addrs[SLF_MAX_FRAMES];
    int n = 0;

    // 第 0 帧是当前 PC
    addrs[n++] = pc;

    // 沿 frame pointer 链回溯。
    // 每个 fp 指向 {previous_fp, return_address}。
    uint64_t curFP = fp;
    for (int i = 1; i < SLF_MAX_FRAMES && curFP != 0; i++) {
        uint64_t frame[2] = {0, 0};
        mach_vm_size_t outSize = 0;
        kern_return_t r = mach_vm_read_overwrite(task,
                                                 (mach_vm_address_t)curFP,
                                                 sizeof(frame),
                                                 (mach_vm_address_t)(uintptr_t)frame,
                                                 &outSize);
        if (r != KERN_SUCCESS || outSize != sizeof(frame)) break;

        uint64_t nextFP = SLF_STRIP(frame[0]);
        uint64_t retAddr = SLF_STRIP(frame[1]);

        if (retAddr != 0) {
            if (n < SLF_MAX_FRAMES) addrs[n++] = retAddr;
        }
        // 栈必须向高地址增长；不满足说明链已断裂或数据异常，立刻停止。
        if (nextFP <= curFP) break;
        curFP = nextFP;
    }

    // 若回溯一帧都没拿到，至少把 LR 报出来（通常已能定位直接调用方）。
    if (n == 1 && lr != 0 && n < SLF_MAX_FRAMES) {
        addrs[n++] = lr;
    }

    for (int i = 0; i < n; i++) {
        Dl_info info;
        const char *img = "?";
        const char *sym = NULL;
        uint64_t off = 0;

        if (dladdr((const void *)addrs[i], &info) != 0) {
            if (info.dli_fname) {
                img = strrchr(info.dli_fname, '/');
                img = img ? img + 1 : info.dli_fname;
            }
            sym = info.dli_sname;
            if (info.dli_saddr) {
                off = addrs[i] - (uint64_t)(uintptr_t)info.dli_saddr;
            }
        }

        if (sym) {
            [sb appendFormat:@"    #%-2d %-28s %s+0x%llx\n", i, img, sym, off];
        } else {
            [sb appendFormat:@"    #%-2d %-28s 0x%llx\n", i, img, addrs[i]];
        }
    }

    *outText = sb;
#else
    *outText = @"(非 arm64 架构，栈回溯未实现)";
#endif
}

#pragma mark - 主线程心跳

static void SLFTouchPort(void) {
    // 记录主线程的 mach port，供后台线程抓栈使用。
    mach_port_t p = pthread_mach_thread_np(pthread_self());
    atomic_store(&gMainThreadPort, (uint32_t)p);
}

static void SLFPumpBeat(void) {
    atomic_store(&gLastBeatNS, SLFNowNS());
}

#pragma mark - 看门狗主循环

static void SLFWatchdogTick(void) {
    if (!atomic_load(&gWatchdogRunning)) return;

    uint64_t last = atomic_load(&gLastBeatNS);
    if (last == 0) return;

    uint64_t now = SLFNowNS();
    if (now < last) return;  // 时钟异常保护

    uint64_t deltaMS = (now - last) / 1000000ULL;
    NSInteger threshold = SLFInt(@"StallThresholdMS", 250);

    if ((NSInteger)deltaMS < threshold) return;

    // ---- 进入卡顿上报路径 ----

    // 抓栈本身有开销，且连续卡顿期间栈几乎相同 → 同一段卡顿只抓一次。
    // 用 CAS 抢占，避免两个 tick 重叠时重复抓栈。
    // 注意：闸门在 tick 末尾必释放（无论抓栈成败），否则一次失败会永久静音。
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gReporting, &expected, true)) {
        return;
    }

    // 报告次数上限，防止极端情况下日志爆炸。
    NSInteger maxReports = SLFInt(@"MaxStallReports", 40);
    int done = atomic_load(&gReportCount);
    if (done >= maxReports) {
        atomic_store(&gReporting, false);
        return;
    }
    atomic_store(&gReportCount, done + 1);

    // 在后台线程抓主线程栈：此刻主线程正卡着，栈就是现场。
    NSString *stack = nil;
    @try {
        SLFCaptureThreadStack((mach_port_t)atomic_load(&gMainThreadPort), &stack);
    } @catch (__unused NSException *e) {
        stack = @"(抓栈异常)";
    }

    SLFLogAlways(@"[stall] 主线程已阻塞 %llums (阈值 %ldms) —— 第 %d 次\n%@",
                 deltaMS, (long)threshold, done + 1, stack ?: @"(无栈)");

    atomic_store(&gLastReportedNS, now);

    // 必释闸门。放在抓栈之后、且无任何提前 return 的路径上。
    atomic_store(&gReporting, false);
}

#pragma mark - 启动

static void SLFStartWatchdogOnce(void) {
    if (!SLFBool(@"WatchdogEnabled", YES)) {
        SLFLogAlways(@"[watchdog] disabled by config");
        return;
    }

    // 心跳只能由主线程刷新 —— 这正是"主线程是否在响应"的判据。
    if (!pthread_main_np()) {
        SLFLogAlways(@"[watchdog] 非主线程调用，跳过启动");
        return;
    }

    SLFTouchPort();
    SLFPumpBeat();

    atomic_store(&gWatchdogRunning, true);

    // 100ms 一次：既能及时捕获 250ms 级卡顿，开销也可忽略（仅原子读）。
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (timer == NULL) {
        SLFLogAlways(@"[watchdog] timer 创建失败");
        return;
    }

    // 定时器必须被强引用住，否则被释放后静默失效（曾踩过这个坑）。
    static dispatch_source_t sTimer = NULL;
    sTimer = timer;

    uint64_t interval = 100ull * NSEC_PER_MSEC;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval,
                              20ull * NSEC_PER_MSEC);

    dispatch_source_set_event_handler(timer, ^{
        @try {
            SLFWatchdogTick();
        } @catch (__unused NSException *e) {
            // 看门狗自身异常绝不允许逃逸到线程外
        }
    });

    dispatch_resume(timer);

    // 主线程心跳：每 100ms 把一个 block 投进主队列，执行时刷新时间戳。
    // 若主线程被阻塞，block 无法执行 → 时间戳停住 → 被判为卡顿。
    //
    // 关键：这里不用 CAS 去重。原因：一旦用"上次未执行就不再投递"的去重逻辑，
    // 主线程长时间阻塞后该标志会卡在 true，恢复后心跳永久停摆，看门狗从此失明。
    // 改用"每次 tick 无条件投递"，代价仅是主队列上每秒 10 个空 block（可忽略），
    // 换来的是：主线程一恢复，心跳立刻重新走起来。
    dispatch_source_t beatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (beatTimer != NULL) {
        static dispatch_source_t sBeatTimer = NULL;
        sBeatTimer = beatTimer;
        dispatch_source_set_timer(beatTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, interval),
                                  interval, 10ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(beatTimer, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                SLFPumpBeat();
            });
        });
        dispatch_resume(beatTimer);
    }

    SLFLogAlways(@"[watchdog] started, threshold=%ldms tick=100ms",
                 (long)SLFInt(@"StallThresholdMS", 250));

    // 定期输出 hook 统计，便于对比"开优化前后"的差异。
    NSInteger dumpInterval = SLFInt(@"StatDumpInterval", 30);
    if (dumpInterval > 0) {
        extern void SLFDumpStats(void);
        dispatch_source_t statTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (statTimer != NULL) {
            static dispatch_source_t sStatTimer = NULL;
            sStatTimer = statTimer;
            uint64_t iv = (uint64_t)dumpInterval * NSEC_PER_SEC;
            dispatch_source_set_timer(statTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, iv), iv,
                                      1ull * NSEC_PER_SEC);
            dispatch_source_set_event_handler(statTimer, ^{
                @try {
                    SLFDumpStats();
                } @catch (__unused NSException *e) {}
            });
            dispatch_resume(statTimer);
        }
    }
}

void SLFStartWatchdog(void) {
    // 幂等：重复调用会重复创建定时器，且覆盖 static 引用 →
    // 旧 timer 被释放后变成"已取消但未释放"的悬空源，行为不可预期。
    // 用 pthread_once 保证只启动一次。
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, SLFStartWatchdogOnce);
}