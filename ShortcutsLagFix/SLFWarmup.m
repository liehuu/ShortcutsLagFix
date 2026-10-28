//
//  SLFWarmup.m
//  ShortcutsLagFix
//
//  把「子系统首次触达」的成本从用户可感知的路径上挪走。
//
//  依据全部来自用户 v1.0.0 的实测日志（33 次 stall，主线程真实不可用 16.65 秒），
//  其中以下四段是**一次性初始化**，第二次调用几乎零开销：
//
//    #25  298ms  CTFontCreateWithFontDescriptor
//                ← CoreFoundation bsearch → CoreText → UIFoundation → WorkflowUI
//    #28  602ms  CFBurstTrieCreateFromFile
//                ← stat → CoreFoundation，拼写/语言词典的 trie 从磁盘载入
//    #13  285ms  libmecab ×4 + CoreNLP ×2
//                ← UIFoundation ×9 → SwiftUI ×20 → WorkflowUICore
//    #10 3134ms  ImageIO inflate + _platform_memmove（仅其中库加载部分可预热）
//
//  这四处合计约 1.2 秒是**可以完全移出主线程**的（#10 只能省掉库初始化那一小段，
//  真正的解压开销属于 App 自身行为，改不动，见 README 的诚实边界章节）。
//
//  设计约束（比功能更重要）：
//   1. 只在线程外做、只在 BACKGROUND QoS 做 —— 任何时候都不与主线程抢 CPU；
//   2. 每步之前先问主线程是否响应正常，卡顿期间主动退让，绝不叠加负载；
//   3. 全部 @try/@catch，单步失败只影响该步；
//   4. 每一步都记耗时并落盘，这样"预热有没有真的生效"可以事后核对，
//      而不是只相信代码看起来对。
//

#import "SLFCommon.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <NaturalLanguage/NaturalLanguage.h>
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

// 3) 语言分析（分词）。
//    对应日志 #13：libmecab ×4 + CoreNLP ×2，由 UIFoundation 的断行逻辑触发。
//    NLTagger / NLTokenizer 走同一套底层分析器。
static uint64_t SLFWarmLanguage(void) {
    uint64_t t0 = SLFNowNS();
    @try {
        NSString *sample = @"新建 快捷指令 shortcut";
        // block 签名以 SDK 头文件为准（NLTokenizer.h:57）：
        //   (NSRange tokenRange, NLTokenizerAttributes flags, BOOL *stop)
        // 第二参是选项位，不是 NLTokenizer 对象 —— 我凭记忆先写成了
        // (NSRange, NLTokenizer *, BOOL *)，CI 编译器直接报不兼容。
        // 教训：涉及第三方/系统 API 的签名，一律以头文件为准，不凭印象。
        NLTokenizer *tok = [[NLTokenizer alloc] initWithUnit:NLTokenUnitWord];
        tok.string = sample;
        [tok enumerateTokensInRange:NSMakeRange(0, sample.length)
                         usingBlock:^(NSRange r, NLTokenizerAttributes flags, BOOL *stop) {
                             (void)r; (void)flags; (void)stop;
                         }];

        // 日文分词走 mecab，与日志里 libmecab 的调用链对应；
        // 单独喂一段日文，确保 mecab 而非仅英文分析器被初始化。
        NLTokenizer *tokJa = [[NLTokenizer alloc] initWithUnit:NLTokenUnitWord];
        tokJa.string = @"ショートカット";
        [tokJa enumerateTokensInRange:NSMakeRange(0, tokJa.string.length)
                           usingBlock:^(NSRange r, NLTokenizerAttributes flags, BOOL *stop) {
                               (void)r; (void)flags; (void)stop;
                           }];

        if (@available(iOS 13.0, *)) {
            NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[ NLTagSchemeLanguage ]];
            tagger.string = sample;
            [tagger enumerateTagsInRange:NSMakeRange(0, sample.length)
                                  unit:NLTokenUnitWord
                                scheme:NLTagSchemeLanguage
                               options:NLTaggerOmitPunctuation | NLTaggerOmitWhitespace
                            usingBlock:^(NLTag tag, NSRange tokenRange, BOOL *stop) {
                                (void)tag; (void)tokenRange; (void)stop;
                            }];
        }
    } @catch (__unused NSException *e) {}
    return SLFNowNS() - t0;
}

// 4) ImageIO / libz 解码路径。
//    对应日志 #10 的栈：
//      _platform_memmove → libz inflate → ImageIO ×12 → dispatch_apply →
//      CGDataProviderCopyData → WorkflowUIServices
//    必须真的把位图画出来才会走到 inflate，只 CreateImage 是懒解码、不触发。
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

#pragma mark - 调度

static void SLFWarmupRun(void) {
    @autoreleasepool {
        SLFLogAlways(@"[warmup] 开始（后台 QoS=background，不占主线程）");
        uint64_t all0 = SLFNowNS();

        struct { const char *name; uint64_t (*fn)(void); } steps[] = {
            { "CoreText 字体",   SLFWarmFonts },
            { "词典 trie",       SLFWarmTextChecker },
            { "语言分析/mecab",  SLFWarmLanguage },
            { "ImageIO/libz",    SLFWarmImageIO },
        };

        for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
            // 每步之前都看主线程是否空闲过；不空闲就等，绝不叠加。
            SLFWarmupBePolite();

            uint64_t cost = steps[i].fn();
            // 用 %@ 而不是 %s：SLFLog 的格式走 NSString 规则，直接给 NSString 最稳。
            SLFLogAlways(@"[warmup] %@ %.1fms",
                         [NSString stringWithUTF8String:steps[i].name],
                         (double)cost / 1e6);

            // 步间让出 CPU。总预热只做一次，没必要抢时间。
            usleep(80 * 1000);
        }

        uint64_t total = SLFNowNS() - all0;
        SLFLogAlways(@"[warmup] 完成，共 %.1fms。这些成本已从用户点击路径移出；"
                      "若后续 [stall] 仍出现 CTFont/CFBurstTrie/mecab/ImageIO，"
                      "说明该处不是一次性的，或预热未覆盖到那条分支。",
                     (double)total / 1e6);
    }
}

void SLFWarmupStart(void) {
    // 幂等闸门用原子 CAS。
    // 注意：**不要**为了图省事调 pthread_once(&once, NULL) —— 传 NULL 回调是
    // 未定义行为，会直接崩在宿主进程里。一次性动作要么有真函数，要么用 CAS。
    static _Atomic bool started = false;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&started, &expected, true)) return;

    if (!SLFBool(@"WarmupEnabled", YES)) {
        SLFLogAlways(@"[warmup] 已按配置禁用");
        return;
    }

    // 延迟启动：让 App 自己的启动流程先跑完，避免与它争资源。
    // 默认 1.5 秒 —— 用户从点开 App 到点「新建」，一般远大于这个时间。
    NSInteger delayMS = SLFInt(@"WarmupDelayMS", 1500);
    if (delayMS < 0) delayMS = 0;

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayMS * NSEC_PER_MSEC), q, ^{
        @try {
            SLFWarmupRun();
        } @catch (__unused NSException *e) {
            SLFLogAlways(@"[warmup] 异常: %@", e);
        }
    });
}
