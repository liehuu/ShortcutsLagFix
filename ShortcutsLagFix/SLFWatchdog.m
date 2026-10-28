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
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>
#import <pthread.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <CoreFoundation/CoreFoundation.h>

// 注意：不要 #import <mach/mach_vm.h>。
// iOS SDK 里该头文件是占位桩，内容只有一行 `#error mach_vm.h unsupported.`
// （仅 macOS 提供）。iOS 上用 <mach/mach.h> 里的 vm_read_overwrite 即可，
// 语义相同：把目标进程内存读进本进程缓冲区，越界只返回错误码、不会崩。
// 这正是"抓栈时不崩"的关键保证。

#pragma mark - 地址掩码

// arm64e 下 pc / fp / lr 可能带 PAC 签名位，需要掩码后才能当普通地址用。
// 必须保留 48 位：iOS 用户态地址空间上界在 48 位内，但线程栈常位于
// 0x16_xxxx_xxxx 一带（约 90GB），若只保留 36 位会被截断 → dladdr 失败 → 栈无法符号化。
#define SLF_USER_VA_MASK 0x0000FFFFFFFFFFFFULL
#define SLF_STRIP(p) ((uint64_t)(p) & SLF_USER_VA_MASK)

#pragma mark - 心跳

static _Atomic uint64_t gLastBeatNS = 0;
static _Atomic uint32_t gMainThreadPort = 0;
static _Atomic bool gWatchdogRunning = false;

// 定时器强引用。
// 必须集中持有并被真正读取：dispatch_source 一旦被释放，其事件处理器会静默停止触发
// （表现为"看门狗装上了但从不报警"）。只在函数内赋值属于"只写不读"，
// 既会触发 -Wunused-but-set-variable，也无法表达"持有引用"的意图。
static dispatch_source_t gTickTimer = NULL;
static dispatch_source_t gBeatTimer = NULL;
static dispatch_source_t gStatTimer = NULL;

#pragma mark - 去重与配额
static _Atomic bool gReporting = false;
static _Atomic int  gReportCount = 0;
static _Atomic uint64_t gLastReportedNS = 0;

// 前置声明：SLFWatchdogHealthCheck 定义在下方，但被上方的定时器 block 引用。
void SLFWatchdogHealthCheck(void);

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

// 一次抓栈的结果。改成结构体而不是直接拼字符串，是为了让"分类"和
// "多次采样聚合热点"能在同一份数据上做，而不是对着字符串正则反向解析。
typedef struct {
    uint64_t addrs[SLF_MAX_FRAMES];
    int n;
    uint64_t pc;
} SLFStackTrace;

// noinline：保证这些函数自己在栈上有独立帧，不会被优化掉导致回溯错位。
__attribute__((noinline))
static void SLFCaptureStack(mach_port_t thread, SLFStackTrace *out) {
    memset(out, 0, sizeof(*out));
    if (thread == MACH_PORT_NULL) return;

#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) return;

    // ★ arm64e 关键差异：__pc / __fp / __lr 是带指针认证（PAC）的字段，
    // 不能直接当 uint64_t 读 —— 在 arm64e 上直接访问会拿到带签名位的值，
    // 甚至编译告警。必须走 SDK 提供的访问器，它们内部会正确剥离签名。
    uint64_t pc = SLF_STRIP(SLFGetPC(&state));
    uint64_t fp = SLF_STRIP(SLFGetFP(&state));
    uint64_t lr = SLF_STRIP(SLFGetLR(&state));

    out->pc = pc;
    int n = 0;
    out->addrs[n++] = pc;

    // 沿 frame pointer 链回溯。每个 fp 指向 {previous_fp, return_address}。
    task_t task = mach_task_self();
    uint64_t curFP = fp;
    for (int i = 1; i < SLF_MAX_FRAMES && curFP != 0; i++) {
        uint64_t frame[2] = {0, 0};
        vm_size_t outSize = 0;
        kern_return_t r = vm_read_overwrite(task,
                                            (vm_address_t)curFP,
                                            (vm_size_t)sizeof(frame),
                                            (vm_address_t)(uintptr_t)frame,
                                            &outSize);
        if (r != KERN_SUCCESS || outSize != sizeof(frame)) break;

        uint64_t nextFP = SLF_STRIP(frame[0]);
        uint64_t retAddr = SLF_STRIP(frame[1]);

        if (retAddr != 0 && n < SLF_MAX_FRAMES) out->addrs[n++] = retAddr;
        // 栈必须向高地址增长；不满足说明链已断裂或数据异常，立刻停止。
        if (nextFP <= curFP) break;
        curFP = nextFP;
    }

    // 若回溯一帧都没拿到，至少把 LR 报出来（通常已能定位直接调用方）。
    if (n == 1 && lr != 0) out->addrs[n++] = lr;

    out->n = n;
#endif
}

// 取地址所属 image 的短名与"相对 image 基址"的偏移。
//
// ★ 为什么必须用 image 基址而不是符号偏移（实测缺陷）：
//   旧实现算的是 addr - dli_saddr。dladdr 对没有导出符号的帧会返回
//   "最近的导出符号"，该符号地址可能**大于**目标地址，相减得到天文数字，
//   于是日志里出现 <redacted>+0x7e0000000024 这种偏移。
//   那种偏移量无法用于任何符号化工具，等于白抓。
//   改成相对 dli_fbase 之后，输出形如 UIKitCore+0x8c1a4，可以直接
//   用 atos / 崩溃日志对照定位，这才是可用的证据。
static const char *SLFImageNameAndOffset(uint64_t addr, uint64_t *outOff, const char **outSym) {
    static char buf[64];        // 单线程使用（看门狗串行），无需加锁
    Dl_info info;
    *outOff = 0;
    *outSym = NULL;

    if (dladdr((const void *)(uintptr_t)addr, &info) == 0) {
        snprintf(buf, sizeof(buf), "?");
        return buf;
    }

    const char *img = "?";
    if (info.dli_fname) {
        const char *slash = strrchr(info.dli_fname, '/');
        img = slash ? slash + 1 : info.dli_fname;
    }
    snprintf(buf, sizeof(buf), "%s", img);

    uint64_t base = (uint64_t)(uintptr_t)info.dli_fbase;
    if (base != 0 && addr >= base) *outOff = addr - base;

    // 只有当符号地址确实小于等于目标地址时，符号偏移才有意义。
    if (info.dli_sname && info.dli_saddr &&
        (uint64_t)(uintptr_t)info.dli_saddr <= addr) {
        *outSym = info.dli_sname;
        *outOff = addr - (uint64_t)(uintptr_t)info.dli_saddr;
    }
    return buf;
}

__attribute__((noinline))
static NSString *SLFRenderStack(const SLFStackTrace *st) {
    NSMutableString *sb = [NSMutableString string];
    [sb appendFormat:@"    主线程 PC=0x%llx\n", st->pc];

    if (st->n == 0) {
        [sb appendString:@"    (抓栈失败：thread_get_state 未成功)\n"];
        return sb;
    }

    for (int i = 0; i < st->n; i++) {
        uint64_t off = 0;
        const char *sym = NULL;
        const char *img = SLFImageNameAndOffset(st->addrs[i], &off, &sym);
        if (sym != NULL) {
            [sb appendFormat:@"    #%-2d %-26s %s+0x%llx\n", i, img, sym, off];
        } else {
            // 无符号：给出 image 相对偏移，可直接拿去 symbolicate。
            [sb appendFormat:@"    #%-2d %-26s 0x%llx\n", i, img, off];
        }
    }
    return sb;
}

#pragma mark - 阻塞类型自动分类

// 把栈顶若干帧的 image/符号名映射成人能直接用的结论。
//
// 目的：33 次 stall、约 300 行栈，人肉读极容易看错（我自己就把
// "<redacted>+0x74" 当成了有意义的证据）。分类之后一眼能看出
// "这是等锁" vs "这是系统初始化" vs "这是视图重算"。
// 判定只依据栈形状与 image 名，不做任何猜测性推断。
static NSString *SLFClassifyStack(const SLFStackTrace *st) {
    if (st->n == 0) return @"未知（抓栈失败）";

    // 只看前 6 帧：更深的帧通常是 runloop 外壳，对归因没有帮助。
    int limit = st->n < 6 ? st->n : 6;
    BOOL sawRunLoopOnly = YES;

    for (int i = 0; i < limit; i++) {
        uint64_t off = 0;
        const char *sym = NULL;
        const char *img = SLFImageNameAndOffset(st->addrs[i], &off, &sym);
        NSString *s = sym ? [NSString stringWithUTF8String:sym] : @"";
        NSString *im = [NSString stringWithUTF8String:img];

        // 同步等待类：锁、条件变量、IPC、消息队列
        if ([s hasPrefix:@"__psynch_cvwait"] || [s hasPrefix:@"semaphore_wait_trap"] ||
            [s hasPrefix:@"mach_msg2_trap"] || [s hasPrefix:@"mach_msg_overwrite"] ||
            [s hasPrefix:@"__ulock_wait"] || [s hasPrefix:@"__ulock_wake"] ||
            [s hasPrefix:@"__semwait_signal"]) {
            return @"等待（锁 / 条件变量 / 跨进程消息）";
        }
        // 系统一次性初始化：这些正是预热要对准的目标
        if ([im containsString:@"ImageIO"] || [im containsString:@"libz"] ||
            [im containsString:@"CoreText"] || [im containsString:@"libmecab"] ||
            [im containsString:@"CoreNLP"] || [im containsString:@"CoreUI"]) {
            return @"系统一次性初始化（可被预热移出主线程）";
        }
        if ([s hasPrefix:@"CFBurstTrieCreate"]) {
            return @"系统一次性初始化（词典 trie，可被预热移出主线程）";
        }
        // 视图图求值 / Swift 运行时
        if ([im containsString:@"AttributeGraph"] || [im containsString:@"SwiftUI"] ||
            [im containsString:@"libswiftCore"]) {
            return @"视图图求值（App 自身的 SwiftUI 重算）";
        }
        if (![s hasPrefix:@"CFRunLoopRunSpecific"] && ![im isEqualToString:@"?"]) {
            sawRunLoopOnly = NO;
        }
    }

    // 只有 runloop 外壳 + 帧数很少：心跳没跑到，但主线程在跑 runloop。
    // 这只能是主队列上排了大量 block，把心跳压在了后面。
    if (sawRunLoopOnly || st->n < 6) {
        return @"主队列拥塞（栈已断链，心跳被排在大量 block 之后）";
    }
    return @"其他（见下方栈）";
}

// 断链补采：单次抓栈拿不到几帧时，隔 10ms 连采若干次，
// 把出现的地址聚合成"热点"，输出出现最多的前几个。
// 这是把 9 次断链（累计 7.48 秒）从"无信息"变成"有信息"的唯一办法。
static NSString *SLFSampleHotspots(mach_port_t thread, int rounds) {
    NSMutableDictionary<NSString *, NSNumber *> *hits = [NSMutableDictionary dictionary];

    for (int r = 0; r < rounds; r++) {
        SLFStackTrace st;
        SLFCaptureStack(thread, &st);
        for (int i = 0; i < st.n && i < 2; i++) {   // 只看每个样本的最内两帧
            uint64_t off = 0;
            const char *sym = NULL;
            const char *img = SLFImageNameAndOffset(st.addrs[i], &off, &sym);
            // 立刻格式化成 NSString：SLFImageNameAndOffset 返回的是静态缓冲区，
            // 下一次调用会覆盖它，不能保存指针。
            NSString *k = sym
                ? [NSString stringWithFormat:@"%s %s+0x%llx", img, sym, off]
                : [NSString stringWithFormat:@"%s 0x%llx", img, off];
            hits[k] = @([hits[k] integerValue] + 1);
        }
        usleep(10 * 1000);
    }

    if (hits.count == 0) return @"(补采亦无结果)";

    NSArray *sorted = [hits keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
        return [hits[b] compare:hits[a]];
    }];
    NSMutableString *sb = [NSMutableString string];
    int shown = 0;
    for (NSString *k in sorted) {
        if (shown >= 4) break;
        [sb appendFormat:@"    hot #%d  %@   命中 %@/%d\n",
         shown, k, hits[k], rounds];
        shown++;
    }
    return sb;
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

// 供预热模块使用：主线程是否仍在正常响应。
// 判据是"最近 200ms 内刷新过心跳"，比卡顿阈值(250ms)略严，
// 这样预热会在主线程刚开始变慢时就退让，而不是等到已经判为卡顿。
BOOL SLFMainThreadResponsive(void) {
    uint64_t last = atomic_load(&gLastBeatNS);
    if (last == 0) return YES;          // 心跳尚未开始
    uint64_t now = SLFNowNS();
    if (now < last) return YES;         // 时钟异常，按正常处理
    return (now - last) < 200ULL * NSEC_PER_MSEC;
}

#pragma mark - 段（segment）跟踪

// ★ 为什么必须做段跟踪（这次实测踩到的统计陷阱）：
//   主线程持续卡住时，看门狗每 100ms 报一次，而每次的 deltaMS 都比上次大 100ms。
//   用户日志里 #20~#24 分别是 969 / 1304 / 1333 / 1433 / 1533ms，
//   如果直接相加得 6572ms，而按区间合并后只有 1.69 秒 —— 虚报近 4 倍。
//   我自己第一遍就被这个数字骗过（算出"累计 28.77 秒"，真实是 16.65 秒）。
//   所以要把"同一段持续阻塞"显式合并展示，并明确标注"勿累加"。
static _Atomic uint64_t gSegStartNS = 0;    // 当前段起点
static _Atomic uint64_t gSegEndNS   = 0;    // 当前段最近一次观测时刻
static _Atomic int      gSegReports = 0;    // 本段已被上报的次数

static void SLFSegmentSummaryAndReset(void) {
    uint64_t s = atomic_load(&gSegStartNS);
    if (s == 0) return;
    uint64_t e = atomic_load(&gSegEndNS);
    int n = atomic_load(&gSegReports);
    if (e >= s && n > 0) {
        double durS = (double)(e - s) / 1e9;
        // 只有持续够久或上报次数够多才值得单独总结，避免短抖动刷屏。
        if (durS >= 0.5 || n >= 3) {
            SLFLogAlways(@"[stall] 上一段结束：持续 %.2fs，期间上报 %d 次"
                          "（同一段只算一次，请勿把上报次数或毫秒数累加）", durS, n);
        }
    }
    atomic_store(&gSegStartNS, 0);
    atomic_store(&gSegEndNS, 0);
    atomic_store(&gSegReports, 0);
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

    if ((NSInteger)deltaMS < threshold) {
        // 主线程已恢复：结算上一段。
        SLFSegmentSummaryAndReset();
        return;
    }

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

    // ---- 段归属判定 ----
    uint64_t stallStart = now - deltaMS * 1000000ULL;
    uint64_t segStart = atomic_load(&gSegStartNS);
    BOOL continuation = NO;
    // 容差 300ms：tick 间隔 100ms，同一段内的上报彼此不会差太远；
    // 若起点比当前段起点晚 300ms 以上，说明中间主线程恢复过，是新的一段。
    if (segStart != 0 && stallStart <= segStart + 300ULL * 1000000ULL) {
        continuation = YES;
    } else {
        // 新的一段开始：先把上一段结算掉（若存在）。
        SLFSegmentSummaryAndReset();
        atomic_store(&gSegStartNS, stallStart);
        segStart = stallStart;
    }
    atomic_store(&gSegEndNS, now);
    atomic_store(&gSegReports, atomic_load(&gSegReports) + 1);
    int segN = atomic_load(&gSegReports);
    double segDurS = (double)(now - segStart) / 1e9;

    // 在后台线程抓主线程栈：此刻主线程正卡着，栈就是现场。
    SLFStackTrace st;
    @try {
        SLFCaptureStack((mach_port_t)atomic_load(&gMainThreadPort), &st);
    } @catch (__unused NSException *e) {
        memset(&st, 0, sizeof(st));
    }

    NSString *kind = SLFClassifyStack(&st);

    // 断链补采：帧数太少时单次栈没有信息量，隔 10ms 连采几次聚合热点。
    NSString *hot = nil;
    if (st.n < 6) {
        @try {
            hot = SLFSampleHotspots((mach_port_t)atomic_load(&gMainThreadPort), 8);
        } @catch (__unused NSException *e) {}
    }

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"[stall] 主线程已阻塞 %llums (阈值 %ldms) —— 第 %d 次\n",
                      deltaMS, (long)threshold, done + 1];
    [out appendFormat:@"    类型: %@\n", kind];
    if (continuation) {
        [out appendFormat:@"    本段: 自 %0.2fs 前起，这是同一段阻塞的第 %d 次上报"
                          "（勿累加，段总长请看下面的「上一段结束」行）\n", segDurS, segN];
    } else {
        [out appendFormat:@"    本段: 新的一段开始\n"];
    }
    [out appendString:SLFRenderStack(&st)];
    if (hot != nil) {
        [out appendString:@"    --- 补采热点（栈已断链，以下为 8 次采样的聚合）---\n"];
        [out appendString:hot];
    }

    SLFLogAlways(@"%@", out);
    atomic_store(&gLastReportedNS, now);

    // 必释闸门。放在抓栈之后、且无任何提前 return 的路径上。
    atomic_store(&gReporting, false);
}

// 看门狗自身的存活检查。
// 用途一：把三个定时器引用真正"读"一次，避免 -Wunused-but-set-variable；
// 用途二：这是有实际价值的自检 —— 定时器被释放后看门狗会静默失效，
//         定期打印存活状态能在日志里直接看出"看门狗还活着吗"。
void SLFWatchdogHealthCheck(void) {
    SLFLog(@"[watchdog] alive tick=%d beat=%d stat=%d reports=%d",
           gTickTimer != NULL,
           gBeatTimer != NULL,
           gStatTimer != NULL,
           (int)atomic_load(&gReportCount));
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

    // 存入文件作用域强引用槽位。
    gTickTimer = timer;

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
        gBeatTimer = beatTimer;
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
            gStatTimer = statTimer;
            uint64_t iv = (uint64_t)dumpInterval * NSEC_PER_SEC;
            dispatch_source_set_timer(statTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, iv), iv,
                                      1ull * NSEC_PER_SEC);
            dispatch_source_set_event_handler(statTimer, ^{
                @try {
                    SLFWatchdogHealthCheck();
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