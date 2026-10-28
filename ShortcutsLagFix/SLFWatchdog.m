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
#import <mach/thread_info.h>
#import <mach/arm/thread_status.h>
#import <pthread.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <CoreFoundation/CoreFoundation.h>

// ptrauth_strip 用于剥 fp 链返回地址的 PAC 签名。
// 只在 arm64e 下有意义；旧 SDK 没有这个头文件时退回 48 位掩码（能力变差但不报错）。
#if defined(__has_include)
  #if __has_include(<ptrauth.h>)
    #import <ptrauth.h>
    #define SLF_HAVE_PTRAUTH 1
  #endif
#endif

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

// 段内抽稀：同一段阻塞不重复抓栈。
// 1.0.5 的注释写着"同一段只抓一次"，但代码里没实现 —— 实测 40 次配额
// 在 9.8 秒内被同一段烧光（第 7~40 次上报全是同一段的第 2~34 次），
// 导致后面 21.89s / 5.20s / 3.17s 三段**一条栈都没有**。
// 工具最该记录的长段，反而因为短段的重复抓栈而失明。
static _Atomic uint64_t gSegLastCaptureNS = 0;
static _Atomic int gSegCaptureCount = 0;

// 段内主线程状态采样（区分"在干活"与"在等待"）。
//
// ★★ 1.0.6 实测推翻了这里的判据设计：
//   41 段、66 次上报，**每一次** run_state 都落在 WAITING，
//   「执行中」恒为 0 次。但同一批段的 PC 重复率是 0%~56%（低），
//   说明 PC 在不停变化 —— 主线程明明在推进。
//   两条观测直接矛盾，说明 run_state 这个来源在本机不可信
//   （可能恒报"不在 CPU 上"，也可能采样时刻总落在 mach_msg 里）。
//
//   → 修正：主判据换成 **CPU 时间增量 / 墙钟增量**。
//     这是内核累计计数器，只能单调递增，不会说谎：
//       ratio ≥ 0.5  → 这一拍大半时间在烧 CPU，确实在执行
//       ratio ≤ 0.15 → 几乎没烧 CPU，真的在等锁 / 等 IPC
//     中间的区间单独计为"混合"，不再硬塞进两边。
//   → run_state 降级为**观测项**：只记录它的原始值分布并打印出来，
//     让下一轮日志自己证明它是不是恒为某值。不再拿它做判定。
static _Atomic int gSegBusyTicks = 0;     // CPU 增量占比 ≥ 50%
static _Atomic int gSegWaitTicks = 0;     // CPU 增量占比 ≤ 15%
static _Atomic int gSegMixedTicks = 0;    // 介于两者之间
static _Atomic int gSegPCSamples = 0;     // 参与比较的采样数
static _Atomic int gSegPCSame = 0;        // 与上一次采样 PC 相同的次数
static _Atomic uint64_t gSegLastPC = 0;
static _Atomic uint64_t gLastMainCPUms = 0;   // 上一个 tick 读到的累计 CPU 毫秒
// 段内 CPU 时间累计与墙钟累计（微秒），用于算整段的平均 CPU 占用率。
static _Atomic uint64_t gSegCPUusSum = 0;
static _Atomic uint64_t gSegWallusSum = 0;
// run_state 原始值出现过的集合（位图，bit n = 值 n 出现过）。
// 只用于"自证该 API 是否可用"，绝不参与判定。
static _Atomic uint32_t gSegRunStateMask = 0;
// 整段观测期内 run_state 各值的出现次数，便于打印"WAITING 6 次 / RUNNING 0 次"。
static _Atomic int gSegRunStateHist[8];

// 前置声明：SLFWatchdogHealthCheck 定义在下方，但被上方的定时器 block 引用。
void SLFWatchdogHealthCheck(void);

#pragma mark - 主线程运行状态

// 读主线程的 run_state 与累计 CPU 时间（毫秒）。
//
// ★ 为什么需要它（本轮实测踩出来的）：
//   心跳的前提是"主线程有空就跑我的 block"。但有两种情况都会让心跳停住：
//     A. 主线程卡在一个点上（等锁 / 等 IPC）—— 真 hang；
//     B. 主线程一直在干活，只是主队列上排了大量 block，我的心跳排在队尾 —— 忙，但没死。
//   1.0.5 的日志里出现了连续 21.89 秒的"阻塞段"，但段内 PC 在
//   objc_msgSend 与 __psynch_cvwait 之间来回变 —— 这是 B，不是 A。
//   若不区分，就会把"App 忙了 20 秒"误判成"主线程死锁 20 秒"，修法完全不同。
//
//   run_state 回答"它此刻在干什么"，累计 CPU 回答"它这段时间有没有真在烧 CPU"。
//
// 返回值：TH_STATE_RUNNING(1) / TH_STATE_WAITING(3) / TH_STATE_UNINTERRUPTIBLE(4)，
//        -1 表示读取失败（权限或端口失效），调用方按"未知"处理。
static int SLFMainThreadRunState(uint64_t *outCPUms) {
    if (outCPUms != NULL) *outCPUms = 0;
    mach_port_t th = (mach_port_t)atomic_load(&gMainThreadPort);
    if (th == MACH_PORT_NULL) return -1;

    thread_basic_info_data_t bi;
    mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
    kern_return_t kr = thread_info(th, THREAD_BASIC_INFO, (thread_info_t)&bi, &cnt);
    if (kr != KERN_SUCCESS) return -1;

    if (outCPUms != NULL) {
        *outCPUms = (uint64_t)bi.user_time.seconds * 1000ULL
                  + (uint64_t)bi.user_time.microseconds / 1000ULL
                  + (uint64_t)bi.system_time.seconds * 1000ULL
                  + (uint64_t)bi.system_time.microseconds / 1000ULL;
    }
    return bi.run_state;
}

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

// 只看主线程 PC，不做回溯。
// 用途：每个 tick 都要判断"PC 是否停在同一条指令上"，而完整回溯有开销，
// 不能为了这个判据每 100ms 抓一次整条栈。
static uint64_t SLFPeekMainPC(void) {
    mach_port_t th = (mach_port_t)atomic_load(&gMainThreadPort);
    if (th == MACH_PORT_NULL) return 0;
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&state, &count)
        != KERN_SUCCESS) {
        return 0;
    }
    return SLF_STRIP(SLFGetPC(&state));
#else
    return 0;
#endif
}


// 单个 image 的合理上限。dyld shared cache 里最大的库也就几十 MB，
// 超过 512MB 的"偏移"一定是地址被污染，不可能是真实偏移。
#define SLF_MAX_IMAGE_SPAN (512ULL << 20)

// outOff 取这个值表示"这个偏移不可用"，渲染层据此打印原始地址而不是假偏移。
#define SLF_OFF_UNUSABLE UINT64_MAX

#pragma mark - 已加载 image 表

// ★★ 为什么要有这张表（1.0.6 日志实测，两次尝试都失败的教训）：
//
//   1.0.4/1.0.5 的做法是「掩 48 位 → 若仍不合理就猜位重建」。
//   两版都失败，原因不是掩码位置选错，而是**前提就错了**：
//   一旦地址被污染，就没有任何可靠办法判断"哪些位可信"。
//   实测 663 帧形如 `SwiftUI 0x81800072d258`，其中 0x72d258 是真实偏移，
//   0x818000 是签名残留 —— 但仅凭这个数字，我无法区分两种可能：
//   是"高位混入签名"还是"低位本来就这么大"。
//   猜错的代价是给出一个能通过范围检查、却是假的偏移。
//
//   → 现在换掉整个思路：**不问"哪些位可信"，改问"它落在哪个 image 里"**。
//     dyld 自己报的每个 image 基址是绝对干净的（内核/loader 给的），
//     并且共享缓存里的 image 是紧密连续排布的，"最大 base ≤ a"就能定出归属，
//     用下一个 image 的 base 当上界 —— 落在缝隙里就明确判为不可用。
//     污染地址几乎必然落不进任何 image 的真实范围，于是会被诚实地拒掉，
//     而不是输出一个假偏移。
typedef struct {
    uint64_t base;
    const char *name;   // 指向 dyld 内部的字符串，生命周期同进程，不必复制
} SLFImageEntry;

static SLFImageEntry *gImages = NULL;
static int gImageCount = 0;
// 建表时的 dyld image 数量。dlopen 会让实际数量增长，表就过时；
// 查找失败时用这个差值判断"要不要重建"，避免对着旧表反复判不可用。
static _Atomic uint32_t gBuiltImageCount = 0;
// 重建节流：一帧一帧地查，不能每帧都重建整张表。
static _Atomic uint64_t gLastRebuildNS = 0;

static int SLFCompareImageBase(const void *a, const void *b) {
    uint64_t x = ((const SLFImageEntry *)a)->base;
    uint64_t y = ((const SLFImageEntry *)b)->base;
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

// 建表。初始化阶段调用一次；dlopen 之后由 SLFEnsureImageTableFresh 触发重建。
// 成本：几百次 dyld 数组读取 + 一次 qsort，对启动无可见影响。
// 旧表不 free：它可能正被渲染中的栈字符串引用（name 指针来自 dyld，本身安全），
// 而这个插件一次运行最多重建几次，泄漏几十 KB 远好过 use-after-free。
void SLFBuildImageTable(void) {
    uint32_t n = _dyld_image_count();
    if (n == 0) return;

    SLFImageEntry *arr = (SLFImageEntry *)calloc(n, sizeof(SLFImageEntry));
    if (arr == NULL) return;

    int k = 0;
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        const char *nm = _dyld_get_image_name(i);
        if (h == NULL || nm == NULL) continue;
        arr[k].base = (uint64_t)(uintptr_t)h;
        const char *slash = strrchr(nm, '/');
        arr[k].name = slash ? slash + 1 : nm;
        k++;
    }
    if (k == 0) { free(arr); return; }

    qsort(arr, (size_t)k, sizeof(SLFImageEntry), SLFCompareImageBase);
    gImages = arr;                            // 先填内容再发布指针（顺序不能反）
    gImageCount = k;
    atomic_store(&gBuiltImageCount, n);
}

// 查找失败时调用：若 dyld 报的 image 数比建表时多，说明期间 dlopen 过，
// 重建一次再试。节流 1 秒，避免在几百帧上反复重建。
static void SLFEnsureImageTableFresh(void) {
    uint32_t nowCount = _dyld_image_count();
    if (nowCount == atomic_load(&gBuiltImageCount)) return;

    uint64_t now = SLFNowNS();
    uint64_t last = atomic_load(&gLastRebuildNS);
    if (last != 0 && now - last < NSEC_PER_SEC) return;
    atomic_store(&gLastRebuildNS, now);

    SLFBuildImageTable();
}

// 在一张地址里找出它的归属 image，并给出 image 相对偏移。
// 返回 NULL 表示"这个地址不属于任何已加载 image" —— 调用方必须据此报不可用。
static const SLFImageEntry *SLFFindImage(uint64_t a, uint64_t *outOff) {
    if (gImages == NULL || gImageCount == 0 || a == 0) return NULL;

    // 二分：找最大的 base ≤ a
    int lo = 0, hi = gImageCount - 1, best = -1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (gImages[mid].base <= a) { best = mid; lo = mid + 1; }
        else { hi = mid - 1; }
    }
    if (best < 0) return NULL;

    uint64_t off = a - gImages[best].base;
    // 上界用下一个 image 的起点：共享缓存里 image 紧密排布，缝隙极小，
    // 落在缝隙里说明这个地址不属于任何 image。
    if (best + 1 < gImageCount && a >= gImages[best + 1].base) return NULL;
    if (off > SLF_MAX_IMAGE_SPAN) return NULL;

    *outOff = off;
    return &gImages[best];
}

// 剥掉"从栈内存直接读出来的返回地址"上的 PAC 签名。
//
// ★ 这是 1.0.6 仍然 663 帧不可符号化的真正原因：
//   PC/FP/LR 是从 thread_get_state 拿的，SDK 的 __darwin_arm_thread_state64_get_*
//   访问器**内部已经剥过签名**；而 fp 链里的返回地址是我用 vm_read_overwrite
//   直接从栈内存读的原始值 —— 它从来没经过任何剥离，
//   签名位就留在 bit 32~47 之内，掩 48 位当然剥不掉。
//   → 必须用与签名时相同的 key 显式 strip：返回地址用 return_address key。
//   ptrauth_strip 只清签名位、不做验证，对任意值调用都是安全的。
static uint64_t SLFStripReturnAddr(uint64_t p) {
#ifdef SLF_HAVE_PTRAUTH
    return (uint64_t)(uintptr_t)ptrauth_strip((void *)(uintptr_t)p,
                                              ptrauth_key_return_address);
#else
    return p & SLF_USER_VA_MASK;
#endif
}

// 取地址所属 image 的短名与"相对 image 基址"的偏移。
//
// 只有一条规则：**归属由 image 表决定，偏移只能来自 a - base**。
// 任何"猜位重建"都被彻底移除 —— 那种做法已经在两版日志里各失败一次。
static const char *SLFImageNameAndOffset(uint64_t addr, uint64_t *outOff, const char **outSym) {
    static char buf[64];        // 单线程使用（看门狗串行），无需加锁
    *outOff = 0;
    *outSym = NULL;

    if (addr == 0) {
        snprintf(buf, sizeof(buf), "?");
        return buf;
    }

    // 三级尝试，从"最正确的解释"逐步退到"最宽松的解释"：
    //   1) ptrauth_strip(return_address) —— arm64e 上栈返回地址的正确剥离方式
    //   2) 纯 48 位掩码 —— 对已经从寄存器读出的 PC/LR 够用
    //   3) 刷新 image 表后重做 1)、2) —— 覆盖运行期 dlopen 的情况
    // 三级都失败就诚实报"不可用"，绝不给假偏移。
    uint64_t a = SLFStripReturnAddr(addr);
    uint64_t off = 0;
    const SLFImageEntry *ent = SLFFindImage(a, &off);

    if (ent == NULL) {
        uint64_t a2 = addr & SLF_USER_VA_MASK;
        if (a2 != a) {
            ent = SLFFindImage(a2, &off);
            if (ent != NULL) a = a2;
        }
    }

    if (ent == NULL) {
        SLFEnsureImageTableFresh();
        uint64_t a3 = SLFStripReturnAddr(addr);
        ent = SLFFindImage(a3, &off);
        if (ent != NULL) {
            a = a3;
        } else {
            uint64_t a4 = addr & SLF_USER_VA_MASK;
            if (a4 != a3) {
                ent = SLFFindImage(a4, &off);
                if (ent != NULL) a = a4;
            }
        }
    }

    if (ent == NULL) {
        // 落不进任何 image：明确判不可用，由渲染层打印原始值。
        // 绝不输出一个"看起来像偏移"的假值 —— 假证据比没有证据更糟。
        const char *nm = "?";
        Dl_info info;
        // 仍尝试拿个 image 名当线索（dladdr 对污染值也可能命中，只作提示）。
        if (dladdr((const void *)(uintptr_t)a, &info) != 0 && info.dli_fname != NULL) {
            const char *slash = strrchr(info.dli_fname, '/');
            nm = slash ? slash + 1 : info.dli_fname;
        }
        snprintf(buf, sizeof(buf), "%s", nm);
        *outOff = SLF_OFF_UNUSABLE;
        return buf;
    }

    snprintf(buf, sizeof(buf), "%s", ent->name);
    *outOff = off;

    // 符号名仅作提示：要求符号地址也落在这个 image 内、且不晚于目标地址。
    // 系统库大量符号被标成 "<redacted>"，那种名字没有任何信息量，
    // 直接丢弃 —— 打印 `near <redacted>` 只会让人误以为找到了函数。
    Dl_info info;
    if (dladdr((const void *)(uintptr_t)a, &info) != 0 && info.dli_sname != NULL) {
        if (strcmp(info.dli_sname, "<redacted>") != 0) {
            uint64_t saddr = SLFStripReturnAddr((uint64_t)(uintptr_t)info.dli_saddr);
            uint64_t soff = 0;
            const SLFImageEntry *sent = SLFFindImage(saddr, &soff);
            if (sent == ent && saddr <= a) *outSym = info.dli_sname;
        }
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
        // 格式统一为「image + image 相对偏移」，可直接喂给：
        //   atos -o UIKitCore -arch arm64e 0x8c1a4
        // 符号名只跟在后面作参考（它是"最近的导出符号"，未必是真实函数）。
        if (off == SLF_OFF_UNUSABLE || strcmp(img, "?") == 0) {
            // 归属不明：把原始值打出来（这才是排查依据）。
            // 宁可明说"不可用"，也不输出一个看着像偏移的假值。
            // 1.0.6 日志里出现过 `#2  ?  0x0` 这种行 —— 既不知道是谁，也不是 0 偏移，
            // 打印成 0x0 会被人当成"偏移 0"，所以明确写成「无法解析」。
            [sb appendFormat:@"    #%-2d %-26s 无法解析 raw=0x%llx\n",
             i, "<不属于任何 image>", st->addrs[i]];
        } else if (sym != NULL) {
            // 格式统一为「image + image 相对偏移」，可直接喂给：
            //   atos -o UIKitCore -arch arm64e 0x8c1a4
            [sb appendFormat:@"    #%-2d %-26s 0x%-12llx near %s\n", i, img, off, sym];
        } else {
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

    // ---- 兜底：按整条栈的镜像构成判断 ----
    // 1.0.5 里 40 次上报有 11 次落到"其他（见下方栈）"，等于没分类。
    // 实测这些栈的共同形状是：栈顶 objc_msgSend，往下 40 多帧全是 UIKitCore，
    // 底部是 CFRunLoopRunSpecific → GSEventRunModal → UIApplicationMain。
    // 这既不是"等锁"也不是"系统初始化"，而是主线程在跑布局/绘制循环 ——
    // 有明确名字，就应该叫出名字。
    int uiFrames = 0, coreFrames = 0;
    for (int i = 0; i < st->n; i++) {
        uint64_t off = 0;
        const char *sym = NULL;
        const char *img = SLFImageNameAndOffset(st->addrs[i], &off, &sym);
        NSString *im = [NSString stringWithUTF8String:img];
        coreFrames++;
        if ([im isEqualToString:@"UIKitCore"] || [im isEqualToString:@"QuartzCore"] ||
            [im isEqualToString:@"CoreAnimation"] || [im isEqualToString:@"SwiftUI"] ||
            [im isEqualToString:@"AttributeGraph"] || [im isEqualToString:@"CoreUI"] ||
            [im isEqualToString:@"TextInputUI"] || [im isEqualToString:@"UIFoundation"]) {
            uiFrames++;
        }
    }
    if (coreFrames > 0 && (double)uiFrames / (double)coreFrames >= 0.5) {
        return @"UI 布局/绘制循环（主线程在推进，不是卡死）";
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
            NSString *k;
            if (off == SLF_OFF_UNUSABLE) {
                // 归属不明时按原始地址聚合 —— 同一处反复出现的地址本身就是热点，
                // 不能因为算不出偏移就把它丢掉（那等于把断链的栈又白采一遍）。
                k = [NSString stringWithFormat:@"raw 0x%llx", st.addrs[i]];
            } else if (sym != NULL) {
                k = [NSString stringWithFormat:@"%s %s+0x%llx", img, sym, off];
            } else {
                k = [NSString stringWithFormat:@"%s 0x%llx", img, off];
            }
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

// 看门狗专用队列。
//
// ★ 为什么不能用 dispatch_get_global_queue（实测缺陷，代价是 12 秒盲区）：
//   v1.0.4 把三个 timer 都挂在 QOS_CLASS_UTILITY 的全局并发队列上。
//   全局队列的 worker 是共享的：预热一旦在 BACKGROUND 队列里跑起长任务
//   （实测 21.6 秒），utility 的 timer 事件即使到点也要重新抢 worker，
//   在 QoS 反压下被饿死。日志里「上一段结束」这行比段真实结束晚了 12.07 秒，
//   那 12 秒内主线程状况**没有任何记录**——看门狗在自己最该工作的时候瞎了。
//
//   现在给它私有串行队列 + USER_INITIATED：独立队列不与他人抢 worker，
//   更高 QoS 保证不被后台任务反压。串行也顺带消除了 tick 重入问题。
static dispatch_queue_t SLFWatchdogQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        q = dispatch_queue_create("com.liehuu.shortcutslagfix.watchdog", attr);
    });
    return q;
}

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
        // ★ 必须同时输出"本行落盘距段真实结束过了多久"。
        //   实测发现这个值能到 12 秒：看门狗 timer 挂在全局 QoS 队列上，
        //   被同队列里的长任务饿死，那十几秒里主线程到底卡没卡完全没记录。
        //   不显示这个延迟，读日志的人会把"本行时间戳"误当成"段结束时刻"，
        //   进而把整条时间线对错位。
        double lagS = (double)(SLFNowNS() - e) / 1e9;
        if (lagS < 0) lagS = 0;
        // 只有持续够久或上报次数够多才值得单独总结，避免短抖动刷屏。
        if (durS >= 0.5 || n >= 3) {
            SLFLogAlways(@"[stall] 上一段结束：持续 %.2fs，期间上报 %d 次"
                          "（同一段只算一次，请勿把上报次数或毫秒数累加）"
                          "｜段真实结束于本段最后一次上报时刻，本行落盘滞后 %.2fs%@",
                          durS, n,
                          lagS,
                          (lagS > 1.0 ? @" ← 看门狗被饿死，该时段存在观测盲区" : @""));

            // ---- 本段主线程到底在干什么 ----
            // 这是 1.0.6 新增的关键判据：没有它，"忙 20 秒"会被当成"死锁 20 秒"。
            int busy = atomic_load(&gSegBusyTicks);
            int wait = atomic_load(&gSegWaitTicks);
            int mixed = atomic_load(&gSegMixedTicks);
            int pcS = atomic_load(&gSegPCSamples);
            int pcSame = atomic_load(&gSegPCSame);
            int capped = atomic_load(&gSegCaptureCount);
            int samples = busy + wait + mixed;

            if (samples > 0) {
                NSString *verdict;
                if (busy * 100 >= samples * 60) {
                    verdict = @"主线程在执行（在烧 CPU）：不是死锁，是活太多";
                } else if (wait * 100 >= samples * 60) {
                    verdict = @"主线程真卡在等待上（等锁 / 等 IPC），属于 hang";
                } else if (mixed * 100 >= samples * 50) {
                    verdict = @"混合：边等边跑，典型是循环里反复等同一把锁";
                } else {
                    verdict = @"混合：既有执行段也有等待段";
                }
                SLFLogAlways(@"[stall]   本段主线程状态：执行中 %d / 等待中 %d / 混合 %d"
                              "（共采样 %d 次）→ %@",
                              busy, wait, mixed, samples, verdict);

                // CPU 占用率是这一版的**主判据**：内核累计计数器，只会单调递增，
                // 不会像 run_state 那样给出与 PC 变化自相矛盾的结果。
                uint64_t cpuSum = atomic_load(&gSegCPUusSum);
                uint64_t wallSum = atomic_load(&gSegWallusSum);
                if (wallSum > 0) {
                    SLFLogAlways(@"[stall]   本段平均 CPU 占用率 %.0f%%"
                                  "（这一段的墙钟时间里，主线程有多少比例真的在烧 CPU）",
                                  (double)cpuSum * 100.0 / (double)wallSum);
                }

                // run_state 原始分布 —— 这是自证项，不是判据。
                // 1.0.6 实测它 66 次全报 WAITING 而 PC 一直在变，
                // 这一行就是为了让下一轮日志能直接确认它是否可信。
                SLFLogAlways(@"[stall]   本段 run_state 原始值：RUNNING %d / WAITING %d / "
                              "UNINTERRUPTIBLE %d / 其他 %d（仅作观测，不参与判定）",
                              atomic_load(&gSegRunStateHist[TH_STATE_RUNNING]),
                              atomic_load(&gSegRunStateHist[TH_STATE_WAITING]),
                              atomic_load(&gSegRunStateHist[TH_STATE_UNINTERRUPTIBLE]),
                              samples - atomic_load(&gSegRunStateHist[TH_STATE_RUNNING])
                                      - atomic_load(&gSegRunStateHist[TH_STATE_WAITING])
                                      - atomic_load(&gSegRunStateHist[TH_STATE_UNINTERRUPTIBLE]));
            }
            if (pcS >= 3) {
                double sameRatio = (double)pcSame / (double)pcS;
                // ★ 实测缺陷（1.0.6 日志）：这里原本用 %s 传中文字面量，
                //   而 -[NSString initWithFormat:] 的 %s 按 **MacRoman** 解释字节，
                //   不是 UTF-8。于是「在持续变化」变成「Âú®ÊåÅÁª≠ÂèòÂåñ」。
                //   乱码出现的正是最需要读的那两行诊断结论 —— 工具在最关键处自毁可读性。
                //   铁律：交给 NSString 格式化的中文字面量必须是 @"..."。
                SLFLogAlways(@"[stall]   本段 PC 重复率 %.0f%%（%d/%d）%@",
                              sameRatio * 100.0, pcSame, pcS,
                              sameRatio >= 0.8
                                ? @" ← 几乎停在同一条指令上，倾向单点卡死"
                                : @" ← PC 在持续变化，倾向在推进");
            }
            SLFLogAlways(@"[stall]   本段抓栈 %d 次（已按 StallResampleMS 抽稀，"
                          "同一段的重复上报不再重复抓栈）", capped);
        }
    }
    atomic_store(&gSegStartNS, 0);
    atomic_store(&gSegEndNS, 0);
    atomic_store(&gSegReports, 0);
    atomic_store(&gSegLastCaptureNS, 0);
    atomic_store(&gSegCaptureCount, 0);
    atomic_store(&gSegBusyTicks, 0);
    atomic_store(&gSegWaitTicks, 0);
    atomic_store(&gSegMixedTicks, 0);
    atomic_store(&gSegPCSamples, 0);
    atomic_store(&gSegPCSame, 0);
    atomic_store(&gSegLastPC, 0);
    atomic_store(&gSegCPUusSum, 0);
    atomic_store(&gSegWallusSum, 0);
    atomic_store(&gSegRunStateMask, 0);
    for (int i = 0; i < 8; i++) atomic_store(&gSegRunStateHist[i], 0);
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
        // ★ 同时把 CPU 基准清零：恢复期不采样，若保留旧基准，
        //   下一段第一拍会拿"很久以前"的累计值做差，得出一个巨大的 CPU 增量，
        //   把整段误判成"繁忙"。清零后第一拍因 cpuPrev==0 自动跳过判定。
        atomic_store(&gLastMainCPUms, 0);
        SLFSegmentSummaryAndReset();
        return;
    }

    // ---- 进入卡顿上报路径 ----

    // ---- 段归属判定 ----
    // ★ 顺序很重要：必须放在"打印配额"之前。
    //   1.0.4 把配额检查放在这里之前，达到 MaxStallReports 后直接 return，
    //   连段统计一起停掉。实测日志末段 reports=40，之后用户再点「新建」
    //   产生的卡顿**一条记录都没有** —— 工具恰恰在最需要它的时候失明了。
    //   现在：配额只限制「抓栈 + 打印」，段统计永远继续。
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

    // ---- 主线程状态采样：它此刻在跑还是在等 ----
    // 每个 tick 都采，与是否抓栈无关 —— 这是"繁忙 vs 卡死"判定的唯一数据来源。
    uint64_t cpuNow = 0;
    int runState = SLFMainThreadRunState(&cpuNow);

    // run_state 只记录、不判定。它到底是 RUNNING 还是恒为 WAITING，
    // 由下一轮日志的分布统计回答，不靠我猜。
    if (runState >= 0 && runState < 8) {
        atomic_store(&gSegRunStateMask,
                     atomic_load(&gSegRunStateMask) | (1u << (unsigned)runState));
        atomic_store(&gSegRunStateHist[runState],
                     atomic_load(&gSegRunStateHist[runState]) + 1);
    }

    uint64_t cpuPrev = atomic_load(&gLastMainCPUms);
    atomic_store(&gLastMainCPUms, cpuNow);
    // cpuPrev==0 说明是首次采样，无法算增量，跳过本次判定。
    if (cpuPrev != 0 && cpuNow >= cpuPrev && deltaMS > 0) {
        uint64_t cpuDelta = cpuNow - cpuPrev;
        // 主判据：CPU 时间增量占墙钟增量的比例。
        // 单线程的 CPU 时间不可能超过墙钟，但计数器取整可能略超，故钳到 1。
        double ratio = (double)cpuDelta / (double)deltaMS;
        if (ratio > 1.0) ratio = 1.0;

        atomic_store(&gSegCPUusSum, atomic_load(&gSegCPUusSum) + cpuDelta * 1000ULL);
        atomic_store(&gSegWallusSum, atomic_load(&gSegWallusSum) + (uint64_t)deltaMS * 1000ULL);

        if (ratio >= 0.5) {
            // 这一拍大半时间在烧 CPU → 主线程确实在推进。
            atomic_store(&gSegBusyTicks, atomic_load(&gSegBusyTicks) + 1);
        } else if (ratio <= 0.15) {
            // 几乎没烧 CPU → 真的卡在锁 / IPC 上。
            atomic_store(&gSegWaitTicks, atomic_load(&gSegWaitTicks) + 1);
        } else {
            // 中间态：既在等也在跑（典型现象是循环里反复等一个锁）。
            atomic_store(&gSegMixedTicks, atomic_load(&gSegMixedTicks) + 1);
        }
    }

    // ---- PC 稳定性：停在一个点上 vs 在多处跳动 ----
    {
        uint64_t p = SLFPeekMainPC();
        if (p != 0) {
            uint64_t prevPC = atomic_load(&gSegLastPC);
            if (prevPC != 0) {
                atomic_store(&gSegPCSamples, atomic_load(&gSegPCSamples) + 1);
                if (p == prevPC) {
                    atomic_store(&gSegPCSame, atomic_load(&gSegPCSame) + 1);
                }
            }
            atomic_store(&gSegLastPC, p);
        }
    }

    // ---- 打印配额（只约束抓栈与打印，不约束上面的段统计）----
    // 顺序：配额 → 抽稀 → 计数。先查配额，避免"配额已满但仍把段内抓栈计数加一"
    // 导致段汇总里的"本段抓栈 N 次"虚高（那是另一种自欺）。
    NSInteger maxReports = SLFInt(@"MaxStallReports", 60);
    int done = atomic_load(&gReportCount);
    if (done >= maxReports) {
        static _Atomic bool quotaWarned = false;
        bool we = false;
        if (atomic_compare_exchange_strong(&quotaWarned, &we, true)) {
            SLFLogAlways(@"[stall] 已达上报上限 %ld 次：之后只累计段统计、不再抓栈。"
                          "要更多现场请调大 MaxStallReports。", (long)maxReports);
        }
        return;
    }

    // ---- 段内抽稀：同一段不重复抓栈 ----
    // 1.0.5 缺这一步，实测 40 次配额在 9.8 秒内被同一段烧光，
    // 后面 21.89s / 5.20s / 3.17s 三段全部无栈。
    // 现在同一段内相邻两次抓栈至少间隔 StallResampleMS（默认 800ms），
    // 且单段最多抓 StallMaxCapturesPerSegment 次（默认 12），
    // 保证配额一定留给后面的新段。
    NSInteger resampleMS = SLFInt(@"StallResampleMS", 800);
    int segCap = atomic_load(&gSegCaptureCount);
    int maxPerSeg = (int)SLFInt(@"StallMaxCapturesPerSegment", 12);
    if (segCap >= maxPerSeg) return;
    uint64_t lastCap = atomic_load(&gSegLastCaptureNS);
    if (lastCap != 0 && resampleMS > 0 &&
        now - lastCap < (uint64_t)resampleMS * 1000000ULL) {
        return;
    }
    atomic_store(&gSegLastCaptureNS, now);
    atomic_store(&gSegCaptureCount, segCap + 1);

    // 抓栈本身有开销，且连续卡顿期间栈几乎相同 → 同一段卡顿只抓一次。
    // 用 CAS 抢占，避免两个 tick 重叠时重复抓栈。
    // ★ 闸门必须在每一条出口上释放，否则一次失败会永久静音。
    //   所以 CAS 放在所有"可能提前 return"的判断之后 —— 位置本身就是正确性保证。
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gReporting, &expected, true)) {
        return;
    }
    atomic_store(&gReportCount, atomic_load(&gReportCount) + 1);

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
// ★ 措辞注意（1.0.5 教训）：这里曾打印 `tick=1 beat=1 stat=1`，看起来像"计数恒为 1"，
//   我读日志时差点据此判定"tick 只跑了一次"。实际打印的是"定时器是否存在"。
//   带误导性的日志比没有日志更坏 —— 所以改成明确的 存在/缺失。
// ★ 编码注意（1.0.6 实测）：这里的「存在/缺失」原本是 C 字符串走 %s，
//   -[NSString initWithFormat:] 的 %s 按 MacRoman 解释，中文变乱码。
//   中文一律用 @"..." 配 %@。
void SLFWatchdogHealthCheck(void) {
    SLFLog(@"[watchdog] 存活自检：tick 定时器 %@，beat 定时器 %@，stat 定时器 %@；"
            "累计抓栈 %d 次",
           gTickTimer != NULL ? @"存在" : @"缺失",
           gBeatTimer != NULL ? @"存在" : @"缺失",
           gStatTimer != NULL ? @"存在" : @"缺失",
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
    // 趁主线程还空闲时把 image 表建好：之后抓栈在后台线程，
    // 那里不该做 calloc/qsort 这种可能阻塞的活。
    SLFBuildImageTable();

    atomic_store(&gWatchdogRunning, true);

    // 100ms 一次：既能及时捕获 250ms 级卡顿，开销也可忽略（仅原子读）。
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        SLFWatchdogQueue());
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
        SLFWatchdogQueue());
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
            SLFWatchdogQueue());
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