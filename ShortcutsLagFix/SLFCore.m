//
//  SLFCore.m
//  ShortcutsLagFix
//
//  基础设施：jbroot 反推、日志落盘、配置直读、原子统计。
//  设计约束（来自 RootHide 环境的实战教训）：
//   1. 禁止硬编码 /var/jb —— 该路径在 RootHide 下不存在。
//   2. 禁止只靠 NSUserDefaults —— 它读的是真实路径，读不到 deb 预置在 jbroot 里的值。
//   3. 启动期日志必须绕过 DebugLog 门禁强制落盘，否则"读不到配置"会把诊断信息一起吞掉。
//

#import "SLFCommon.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <unistd.h>
#import <pthread.h>
#import <time.h>
#import <sys/time.h>

#pragma mark - jbroot 反推

static char gJBPath[PATH_MAX];
static pthread_once_t gJBOnce = PTHREAD_ONCE_INIT;

// 取本 dylib 自身的真实加载路径。
// RootHide 会把 dylib 放在 <jbroot>/Library/MobileSubstrate/DynamicLibraries/，
// 所以从这个路径向上回溯是唯一不依赖硬编码的来源。
static void SLFResolveJBPath(void) {
    gJBPath[0] = '\0';

    Dl_info info;
    // 用本文件内任意函数的地址查询自身镜像路径。
    if (dladdr((const void *)&SLFResolveJBPath, &info) == 0 || info.dli_fname == NULL) {
        return;
    }

    NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
    if (selfPath.length == 0) return;

    // 逐级上溯，遇到名为 Library 的目录，其父目录即 jbroot。
    // 比固定删 4 次更稳（不依赖目录层级深度）。
    NSString *cur = [selfPath stringByDeletingLastPathComponent];
    for (int i = 0; i < 8 && cur.length > 1; i++) {
        if ([[cur lastPathComponent] isEqualToString:@"Library"]) {
            NSString *root = [cur stringByDeletingLastPathComponent];
            if (root.length > 1) {
                strlcpy(gJBPath, root.fileSystemRepresentation, sizeof(gJBPath));
            }
            return;
        }
        cur = [cur stringByDeletingLastPathComponent];
    }

    // 兜底：固定删 4 次（DynamicLibraries -> MobileSubstrate -> Library -> jbroot）
    NSString *root = selfPath;
    for (int i = 0; i < 4; i++) {
        root = [root stringByDeletingLastPathComponent];
    }
    if (root.length > 1) {
        strlcpy(gJBPath, root.fileSystemRepresentation, sizeof(gJBPath));
    }
}

NSString *SLFJBPath(void) {
    pthread_once(&gJBOnce, SLFResolveJBPath);
    if (gJBPath[0] == '\0') return nil;
    return [NSString stringWithUTF8String:gJBPath];
}

#pragma mark - 日志

static NSString *gLogPath = nil;
static dispatch_queue_t gLogQueue = NULL;
static pthread_once_t gLogOnce = PTHREAD_ONCE_INIT;

// 内部实现：由 SLFLogPath 的 pthread_once 调用。
// 约束：本函数内不得再调 SLFLogAlways / SLFLog（它们会回头调 SLFLogPath →
// 在同一个 once 内重入 → 自死锁）。需要输出时一律用 fprintf。
static void SLFSetupLogUnsafe(void) {
    gLogQueue = dispatch_queue_create("com.liehuu.slf.log", DISPATCH_QUEUE_SERIAL);

    NSMutableArray<NSString *> *dirs = [NSMutableArray array];

    // 候选 1：jbroot 内（RootHide 下 deb 预置目录被重定向到这里）
    // 注意：SLFJBPath() 用的是【另一个】pthread_once(gJBOnce)。
    // 两个 once 之间没有反向依赖（SLFResolveJBPath 不调日志），所以不会死锁。
    NSString *jb = SLFJBPath();
    if (jb.length) {
        [dirs addObject:[jb stringByAppendingPathComponent:@"var/mobile/Library/Logs/ShortcutsLagFix"]];
    }
    // 候选 2/3：真实路径与 rootless 路径
    [dirs addObject:@"/var/mobile/Library/Logs/ShortcutsLagFix"];
    [dirs addObject:@"/var/jb/var/mobile/Library/Logs/ShortcutsLagFix"];
    // 候选 4：App 自己容器内的 Library/Logs —— 【一定可写】。
    // 为什么必须有这一条：上面几条都依赖包安装时建好目录并把属主改成 mobile。
    // 如果目录是 dpkg 以 root 建的（属主 root:wheel 755），App 进程（mobile）
    // 创建文件会被拒，于是所有候选都失败、gLogPath 保持 nil，
    // 最终表现是「目录存在但一条日志都没有」——看起来像插件没被加载，
    // 实际是日志设施把失败咽掉了，完全无法分辨。
    // App 容器归 mobile 所有，写入必然成功，作为兜底可以把两者区分开。
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [dirs addObject:[home stringByAppendingPathComponent:@"Library/Logs/ShortcutsLagFix"]];
    }
    // 候选 5：容器 tmp。注意不要用硬编码 "/tmp"：
    // iOS 上真实 /tmp 属主是 root、权限 755，App 同样写不进去，是死候选。
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) {
        [dirs addObject:[tmp stringByAppendingPathComponent:@"ShortcutsLagFix"]];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *chosen = nil;
    NSMutableString *diag = [NSMutableString string];

    for (NSString *dir in dirs) {
        NSError *err = nil;
        // 目录已存在时 createDirectory 返回 YES，所以「成功」不代表可写，
        // 必须再写一个探测文件才能判定 App 是否真的有权限落盘。
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
        NSString *probe = [dir stringByAppendingPathComponent:@".wtest"];
        BOOL ok = [@"x" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [diag appendFormat:@"    %@ -> %@\n", dir, ok ? @"可写" : @"不可写"];
        if (ok) {
            [fm removeItemAtPath:probe error:NULL];
            if (chosen == nil) chosen = dir;
        }
    }

    // 依次尝试所有候选，能写就选第一个；顺序决定优先级：
    // 主路径（用户方便查看） > App 容器（必然可写）。
    if (chosen == nil) {
        // 一条都写不进去。此路径下不能再调日志函数，只能 stderr。
        fprintf(stderr, "[ShortcutsLagFix] 所有日志候选均不可写，禁用日志:\n%s",
                diag.UTF8String);
        return;
    }

    // 把探测结果与最终选择直接写进 stderr，便于通过终端/系统日志定位。
    fprintf(stderr, "[ShortcutsLagFix] 日志路径 = %s\n%s", chosen.UTF8String, diag.UTF8String);

    gLogPath = [chosen stringByAppendingPathComponent:@"ShortcutsLagFix.log"];

    // 轮转：超过 512KB 就留一份 .1
    NSDictionary *attrs = [fm attributesOfItemAtPath:gLogPath error:NULL];
    if (attrs && [attrs fileSize] > 512 * 1024) {
        NSString *old = [gLogPath stringByAppendingString:@".1"];
        [fm removeItemAtPath:old error:NULL];
        [fm moveItemAtPath:gLogPath toPath:old error:NULL];
    }
}

NSString *SLFLogPath(void) {
    pthread_once(&gLogOnce, SLFSetupLogUnsafe);
    return gLogPath;
}

static NSString *SLFFormatLine(NSString *fmt, va_list ap) {
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];

    // 时间戳用纯 C 的 strftime，不用 NSDateFormatter。
    // 原因：NSDateFormatter 非线程安全，而本函数可从任意线程并发进入
    // （主线程 hook、看门狗线程、日志队列）。共用同一个 formatter 会崩溃。
    // strftime + localtime_r 是全可重入的，零锁零风险。
    char tsbuf[32] = {0};
    time_t t = time(NULL);
    struct tm tmv;
    if (localtime_r(&t, &tmv) != NULL) {
        strftime(tsbuf, sizeof(tsbuf), "%H:%M:%S", &tmv);
    }

    // 附毫秒（strftime 不支持毫秒），用 gettimeofday 取微秒。
    struct timeval tv;
    long ms = 0;
    if (gettimeofday(&tv, NULL) == 0) {
        ms = tv.tv_usec / 1000;
    }

    return [NSString stringWithFormat:@"[%s.%03ld] %@\n", tsbuf, ms, msg];
}

static void SLFWriteNow(NSString *line) {
    // 整个函数包 @try：日志是辅助设施，任何失败都不允许影响宿主。
    // 特别注意：初始化阶段（gLogPath 尚未确定）也可能有日志进来，
    // 此时 SLFLogPath() 内部 pthread_once 正在执行 —— 本函数只用返回值，不重入。
    @try {
        NSString *path = SLFLogPath();
        if (path == nil) return;

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data == nil) return;

        // 追加写。用 fileHandle 而不是 read+write 整个文件，避免大日志反复分配。
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh == nil) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh == nil) return;

        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } @catch (__unused NSException *e) {
        // 日志失败绝不影响宿主
    }
}

// 受 DebugLog 门禁控制的异步日志：热路径用这个，绝不阻塞调用线程。
void SLFLog(NSString *fmt, ...) {
    static BOOL enabled = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        enabled = SLFBool(@"DebugLog", YES);
    });
    if (!enabled) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *line = SLFFormatLine(fmt, ap);
    va_end(ap);

    NSString *path = SLFLogPath();
    if (path == nil) return;
    dispatch_async(gLogQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SLFWriteNow(line);
    });
}

// 绕过门禁的同步日志：只在启动阶段与"决定性失败"分支使用。
// 注意：本函数会被 SLFSetupLogUnsafe 之后的调用链使用，但绝不能在
// SLFSetupLogUnsafe 内部调用（会 once 重入死锁）。那条路径改用 fprintf。
void SLFLogAlways(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = SLFFormatLine(fmt, ap);
    va_end(ap);
    SLFWriteNow(line);
}

#pragma mark - 配置直读

// 注意：配置在首次访问时读一次并缓存。
// 修改 plist 后需重启快捷指令 App 才生效（已写入交付说明）。
static NSDictionary *gConfig = nil;
static pthread_once_t gCfgOnce = PTHREAD_ONCE_INIT;

static void SLFLoadConfig(void) {
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSString *jb = SLFJBPath();
    if (jb.length) {
        [cands addObject:[jb stringByAppendingPathComponent:
            @"var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist"]];
    }
    [cands addObject:@"/var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist"];
    [cands addObject:@"/var/jb/var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist"];

    for (NSString *p in cands) {
        // 直接按路径读文件。NSUserDefaults 在 RootHide 下读的是真实路径，
        // 与 deb 预置位置不是同一个文件，会恒读不到。
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d && [d isKindOfClass:[NSDictionary class]]) {
            gConfig = d;
            // ★ 这里只能用 fprintf 直接写 stderr，不能调 SLFLogAlways。
            // 因为本函数运行在 pthread_once(gCfgOnce) 内部，
            // 而 SLFLogAlways → SLFLogPath → pthread_once(gLogOnce) 是另一个 once，
            // 若两个 once 之间存在嵌套调用（日志路径候选里会调 SLFJBPath），
            // 就可能形成 once 自死锁。config 加载阶段用最低层的 stdio 最安全。
            fprintf(stderr, "[ShortcutsLagFix] config loaded: %s (%lu keys)\n",
                    p.UTF8String, (unsigned long)d.count);
            return;
        }
    }
    gConfig = @{};
    fprintf(stderr, "[ShortcutsLagFix] no config file found, using defaults\n");
}

BOOL SLFBool(NSString *key, BOOL def) {
    pthread_once(&gCfgOnce, SLFLoadConfig);
    id v = gConfig[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return def;
}

NSInteger SLFInt(NSString *key, NSInteger def) {
    pthread_once(&gCfgOnce, SLFLoadConfig);
    id v = gConfig[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    return def;
}

#pragma mark - 时间与统计

uint64_t SLFNowNS(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&tb);
    });
    uint64_t t = mach_absolute_time();
    // 换算成纳秒（Apple Silicon/ARM 上 numer/denom 通常为 125/3）
    return t * tb.numer / tb.denom;
}

void SLFStatRecord(SLFStat *s, uint64_t ns) {
    if (s == NULL) return;
    atomic_fetch_add_explicit(&s->calls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->totalNS, (int64_t)ns, memory_order_relaxed);

    // max 用 CAS 循环更新，不能简单赋值（并发下会丢峰值）
    int64_t prev = atomic_load_explicit(&s->maxNS, memory_order_relaxed);
    while ((int64_t)ns > prev) {
        if (atomic_compare_exchange_weak_explicit(&s->maxNS, &prev, (int64_t)ns,
                                                 memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }

    // 单次 > 50ms 记一次慢调用（人类可感知的卡顿下限）
    if (ns > 50ULL * 1000ULL * 1000ULL) {
        atomic_fetch_add_explicit(&s->slow, 1, memory_order_relaxed);
    }
}

void SLFStatReset(SLFStat *s) {
    if (s == NULL) return;
    atomic_store(&s->calls, 0);
    atomic_store(&s->totalNS, 0);
    atomic_store(&s->maxNS, 0);
    atomic_store(&s->slow, 0);
}

NSString *SLFStatDescribe(SLFStat *s) {
    if (s == NULL) return @"(null)";
    int64_t calls = atomic_load(&s->calls);
    if (calls == 0) return @"calls=0";
    int64_t total = atomic_load(&s->totalNS);
    int64_t maxv = atomic_load(&s->maxNS);
    int64_t slow = atomic_load(&s->slow);
    double avgMs = (double)total / (double)calls / 1e6;
    double maxMs = (double)maxv / 1e6;
    return [NSString stringWithFormat:@"calls=%lld avg=%.2fms max=%.2fms slow50ms=%lld",
            calls, avgMs, maxMs, slow];
}

#pragma mark - 目标 App 判定

BOOL SLFIsTargetApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid == nil) return NO;
    return [bid isEqualToString:@"com.apple.shortcuts"]
        || [bid isEqualToString:@"is.workflow.my.app"];
}