//
//  SLFWarmup.m
//  ShortcutsLagFix
//
//  把「子系统首次触达」的成本从用户可感知的路径上挪走。
//
//  ═══════════════════════════════════════════════════════════════════
//  重要：本模块默认关闭（v1.0.5 起）。
//
//  为什么关掉：v1.0.4 默认开启，用户实测日志提供了反证 ——
//
//    13:27:36.221  [warmup] 词典 trie 1779.3ms
//    13:27:39.940  主线程开始阻塞（第 1~23 次上报，合并为一段 4.05s）
//                  栈：AutoFillUI → CFStringTokenizerCreate
//                      → CoreNLP → langid_consume_string
//    13:27:57.929  [warmup] 语言分析/mecab 21623.8ms   ← 21.6 秒！
//
//  主线程卡的那 4 秒，栈顶正是 CoreNLP + liblangid；
//  而我的预热当时正在另一个线程跑 NLTokenizer / NLTagger，也是 CoreNLP + liblangid。
//  两者共用同一套全局分析器状态（首次初始化时持锁），
//  于是「我以为在帮它预热」实际变成了「我在跟它抢，把它拖住」。
//
//  这条教训比功能重要：
//    预热的安全性不能靠"我在后台线程"来论证。
//    只要它触碰的是同一份全局状态，就可能在主线程最需要的时候把它锁住。
//  所以：语言分析预热整段删除；其余各项降级为 opt-in，并加硬超时。
//  ═══════════════════════════════════════════════════════════════════
//
//  设计约束（比功能更重要）：
//   1. 默认不跑。用户必须显式 WarmupEnabled=YES 才启用；
//   2. 每一步都有硬超时，超时立刻放弃剩余步骤 —— 绝不出现"一个步骤跑 21 秒"；
//   3. 每步之前先问主线程是否响应正常，卡顿期间主动退让；
//   4. 每一步都记耗时并落盘，这样"预热有没有真的生效"可以事后核对。
//

#import "SLFCommon.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <pthread.h>
#import <unistd.h>

// 4x4 红色 PNG，73 字节。
// 只用于走通 ImageIO 的 PNG 解码路径（signature 校验 → IHDR → zlib inflate →
// 位图生成），与真实卡顿里 ImageIO/libz 的调用链一致。
// 用内嵌字节而不是读文件：预热本身绝不能引入任何磁盘 IO 依赖。
static const uint8_t kSLFWarmupPNG[] = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, 0x29, 0x00, 0x00, 0x00,
    0x10, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x38, 0x21, 0x27, 0x07,
    0x47, 0x0c, 0xc4, 0x71, 0x00, 0xb1, 0x63, 0x10, 0x41, 0xd3, 0x4a, 0xcc,
    0x0d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
    0x82,
};

#pragma mark - 主线程友好退让

// 预热每做一步之前都先问一次：主线程现在是否正常响应？
// 若正在卡顿（心跳滞后超过 200ms），就等待它恢复再做 ——
// 否则等于在用户已经卡着的时候再压一份负载，把"优化"变成"加剧"。
// 最多等 3 秒，避免极端情况下预热被无限推迟。
static void SLFWarmupBePolite(void) {
    for (int i = 0; i < 30; i++) {
        if (SLFMainThreadResponsive()) return;
        usleep(100 * 1000);
    }
}

#pragma mark - 各项预热

// 1) CoreText 字体栈。
//    对应日志 #25：CTFontCreateWithFontDescriptor 里 CoreFoundation 的 bsearch
//    在字体表里线性/二分查找，首次还要载入字体缓存。
//    实测耗时 7.3ms —— 唯一一个真正又快又安全的预热项。
static uint64_t SLFWarmFonts(void) {
    uint64_t t0 = SLFNowNS();
    @try {
        // 必须走到 descriptor 路径：日志里卡的就是 CTFontCreateWithFontDescriptor。
        UIFontDescriptor *desc = [UIFontDescriptor fontDescriptorWithName:@"Helvetica" size:13.0];
        if (desc != nil) {
            UIFont *f = [UIFont fontWithDescriptor:desc size:13.0];
            (void)f.familyName;
        }
        // 系统字体 + 常用字重，覆盖字体配置缓存的不同分支。
        (void)[UIFont systemFontOfSize:13.0];
        (void)[UIFont boldSystemFontOfSize:13.0];
        // CTFont 直接建一次，确保 CoreText 自身（不只是 UIKit 缓存层）被唤醒。
        CTFontRef ctf = CTFontCreateWithName(CFSTR("Helvetica"), 13.0, NULL);
        if (ctf != NULL) CFRelease(ctf);
    } @catch (__unused NSException *e) {}
    return SLFNowNS() - t0;
}

// 2) 拼写 / 语言词典 trie。
//    对应日志 #28：CFBurstTrieCreateFromFile 602ms，栈里紧跟 stat。
//    UITextChecker 是公开 API，初始化时会加载同一套词典。
//
//    ⚠ 实测 1779ms（预期 298ms），且与主线程的
//      UIKeyboardCheckSpellingPossibleForInputMode 属同一子系统。
//      保留但默认不启用；如需开启请留足超时。
static uint64_t SLFWarmTextChecker(void) {
    uint64_t t0 = SLFNowNS();
    @try {
        UITextChecker *tc = [[UITextChecker alloc] init];
        // 只问一次"这个单词拼对了吗"，足以促使词典 trie 完成载入。
        // 范围随便给一个非空串；结果本身没有意义。
        (void)[tc rangeOfMisspelledWordInString:@"shortcut"
                                          range:NSMakeRange(0, 8)
                                     startingAt:0
                                           wrap:NO
                                       language:@"en"];
    } @catch (__unused NSException *e) {}
    return SLFNowNS() - t0;
}

// 3) ImageIO / libz 解码路径。
//    对应日志 #10 的栈：
//      _platform_memmove → libz inflate → ImageIO ×12 → dispatch_apply →
//      CGDataProviderCopyData → WorkflowUIServices
//    必须真的把位图画出来才会走到 inflate，只 CreateImage 是懒解码、不触发。
//    实测 28.3ms，安全。
static uint64_t SLFWarmImageIO(void) {
    uint64_t t0 = SLFNowNS();
    @try {
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, kSLFWarmupPNG,
                                      (CFIndex)sizeof(kSLFWarmupPNG));
        if (data != NULL) {
            CGImageSourceRef src = CGImageSourceCreateWithData(data, NULL);
            if (src != NULL) {
                CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                if (img != NULL) {
                    size_t w = CGImageGetWidth(img);
                    size_t h = CGImageGetHeight(img);
                    if (w > 0 && h > 0) {
                        // 画进 bitmap：这一步才真正解压像素数据。
                        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                        CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                        if (ctx != NULL) {
                            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
                            CGContextRelease(ctx);
                        }
                        if (cs != NULL) CGColorSpaceRelease(cs);
                    }
                    CGImageRelease(img);
                }
                CFRelease(src);
            }
            CFRelease(data);
        }
    } @catch (__unused NSException *e) {}
    return SLFNowNS() - t0;
}

#pragma mark - 带硬超时的执行器

// 返回 UINT64_MAX 表示超时放弃。
//
// ★ 为什么必须把步骤扔到另一个队列再等：
//   如果直接在当前线程调用，一旦该步骤内部卡住（v1.0.4 的语言分析就卡了 21.6 秒），
//   外层没有任何手段中止它，整条预热链只能陪着一起卡。
//   包一层 semaphore 之后，超时至少能让后续步骤不被拖累。
//
//   注意：超时**不能杀死**已经在跑的步骤（没有安全的线程终止手段）。
//   所以超时后的正确做法是「记录并放弃剩余步骤」，而不是「重试」或「继续下一步」——
//   否则会同时叠起多个长任务，反而更糟。
static uint64_t SLFRunStepWithTimeout(uint64_t (*fn)(void), NSInteger timeoutMS) {
    if (timeoutMS <= 0) timeoutMS = 2000;

    __block uint64_t cost = 0;
    __block BOOL finished = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    // 用 UTILITY 而不是 BACKGROUND：background 在 iOS 上会被显著节流，
    // v1.0.4 的 21.6 秒里很可能有一部分就是这种节流放大出来的。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            cost = fn();
        } @catch (__unused NSException *e) {
            cost = 0;
        }
        finished = YES;
        dispatch_semaphore_signal(sem);
    });

    long r = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMS * NSEC_PER_MSEC));
    if (r != 0 || !finished) return UINT64_MAX;
    return cost;
}

#pragma mark - 调度

static void SLFWarmupRun(void) {
    @autoreleasepool {
        BOOL withLanguage = SLFBool(@"WarmupLanguage", NO);
        NSInteger stepTimeout = SLFInt(@"WarmupStepTimeoutMS", 2000);

        SLFLogAlways(@"[warmup] 开始，单步硬超时 %ldms（注意：本模块默认关闭，"
                      "开启与否请以实测 A/B 为准）", (long)stepTimeout);
        uint64_t all0 = SLFNowNS();

        struct { const char *name; uint64_t (*fn)(void); } steps[] = {
            { "CoreText 字体",   SLFWarmFonts },
            { "词典 trie",       SLFWarmTextChecker },
            { "ImageIO/libz",    SLFWarmImageIO },
        };
        (void)withLanguage;   // 语言分析预热已整段移除，此键仅保留以兼容旧配置

        BOOL aborted = NO;
        for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
            // 每步之前都看主线程是否空闲过；不空闲就等，绝不叠加。
            SLFWarmupBePolite();

            uint64_t cost = SLFRunStepWithTimeout(steps[i].fn, stepTimeout);
            NSString *name = [NSString stringWithUTF8String:steps[i].name];

            if (cost == UINT64_MAX) {
                SLFLogAlways(@"[warmup] %@ 超过 %ldms 未返回，放弃剩余步骤。"
                              "该步仍在后台跑完，但不再叠加后续负载。",
                              name, (long)stepTimeout);
                aborted = YES;
                break;
            }
            SLFLogAlways(@"[warmup] %@ %.1fms", name, (double)cost / 1e6);

            // 步间让出 CPU。总预热只做一次，没必要抢时间。
            usleep(80 * 1000);
        }

        uint64_t total = SLFNowNS() - all0;
        if (aborted) {
            SLFLogAlways(@"[warmup] 提前结束，共 %.1fms", (double)total / 1e6);
        } else {
            SLFLogAlways(@"[warmup] 完成，共 %.1fms。这些成本已从用户点击路径移出；"
                          "若后续 [stall] 仍出现 CTFont/CFBurstTrie/ImageIO，"
                          "说明该处不是一次性的，或预热未覆盖到那条分支。",
                          (double)total / 1e6);
        }
    }
}

void SLFWarmupStart(void) {
    // 幂等闸门用原子 CAS。
    // 注意：**不要**为了图省事调 pthread_once(&once, NULL) —— 传 NULL 回调是
    // 未定义行为，会直接崩在宿主进程里。一次性动作要么有真函数，要么用 CAS。
    static _Atomic bool started = false;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&started, &expected, true)) return;

    // ★ v1.0.5：默认关闭。
    //   1.0.4 默认 YES，结果用户日志显示它是「词典 trie 1779ms + 语言分析 21624ms」，
    //   后者与主线程争 CoreNLP/liblangid 锁，把主线程拖了 4 秒。
    //   在拿到开启/关闭的 A/B 数据之前，默认值必须是「不做任何事」。
    if (!SLFBool(@"WarmupEnabled", NO)) {
        SLFLogAlways(@"[warmup] 已禁用（默认）。需要时可把 WarmupEnabled 设为 YES 做 A/B");
        return;
    }

    // 延迟启动：让 App 自己的启动流程先跑完，避免与它争资源。
    // 默认 1.5 秒 —— 用户从点开 App 到点「新建」，一般远大于这个时间。
    NSInteger delayMS = SLFInt(@"WarmupDelayMS", 1500);
    if (delayMS < 0) delayMS = 0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayMS * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            SLFWarmupRun();
        } @catch (__unused NSException *e) {
            SLFLogAlways(@"[warmup] 异常: %@", e);
        }
    });
}
