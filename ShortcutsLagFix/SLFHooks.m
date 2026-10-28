//
//  SLFHooks.m
//  ShortcutsLagFix
//
//  观测与优化钩子。
//
//  ★ 安全设计红线（源自本项目此前的 SpringBoard 安全模式事故）：
//   1. 只 hook 公开 API，且签名有 100% 把握（参数个数/类型确定）。
//      reloadData / layoutSubviews / viewDidLoad / viewDidAppear: / performFetch:
//      这些都是 Apple 文档化方法，跨版本不存在签名漂移。
//   2. 不碰 substrate。用 libobjc 内建 API（method_setImplementation /
//      class_addMethod），任何环境都有，且不会被 RootHide 的库重定向坑到。
//   3. orig 自己从方法表取出并保存，物理上不可能为 NULL；转发前再判一次。
//   4. 所有 hook 实现整体 @try/@catch，异常绝不出线程。
//   5. hook 体内零文件 IO、零同步日志 —— 日志一律走异步队列。
//   6. 不在 hook 内分配大对象、不做 IPC。
//

#import "SLFCommon.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>
#import <os/lock.h>

#pragma mark - 统计量（全部锁自由，可并发累加）

SLFStat gStatTVReload;
SLFStat gStatCVReload;
SLFStat gStatViewDidLoad;
SLFStat gStatViewDidAppear;
SLFStat gStatPerformFetch;

// 说明：故意不 hook layoutSubviews。
// 它是每帧级高频方法，hook 后即使只做转发也要多付一次函数调用；
// 而若在里面计时，所有滚动都会变慢 —— 与"修卡顿"的目标直接冲突。
// 布局慢的证据由 viewDidAppear 耗时 + 卡顿现场栈提供，足够定位。

#pragma mark - 原始实现

typedef void (*SLFImpVoid)(id, SEL);
typedef void (*SLFImpVoidBool)(id, SEL, BOOL);
// performFetch: 的真实签名是 - (BOOL)performFetch:(NSError **)error
// 返回类型必须声明为 BOOL。写成 void 会让返回值寄存器内容错乱。
typedef BOOL (*SLFImpBoolErrPtr)(id, SEL, NSError **);

static SLFImpVoid       gOrigTVReload       = NULL;
static SLFImpVoid       gOrigCVReload       = NULL;
static SLFImpVoid       gOrigViewDidLoad    = NULL;
static SLFImpVoidBool   gOrigViewDidAppear  = NULL;
static SLFImpBoolErrPtr gOrigPerformFetch   = NULL;

#pragma mark - 类名记录（去重，用于识别"新建快捷指令"界面）

static NSMutableSet<NSString *> *gSeenVCClasses = nil;
static os_unfair_lock gSeenLock = OS_UNFAIR_LOCK_INIT;

static void SLFNoteVCClass(NSString *name, uint64_t costNS) {
    if (name.length == 0) return;

    BOOL isNew = NO;
    os_unfair_lock_lock(&gSeenLock);
    if (gSeenVCClasses == nil) {
        gSeenVCClasses = [NSMutableSet set];
    }
    if (![gSeenVCClasses containsObject:name]) {
        [gSeenVCClasses addObject:name];
        isNew = YES;
    }
    os_unfair_lock_unlock(&gSeenLock);

    // 锁外写日志（教训：持锁时不调用可能有副作用的代码，避免死锁）。
    // 只记录"首次出现且耗时偏高"的界面，避免无关页面刷屏把日志淹掉。
    // 300ms 是用户能明确感到卡顿的量级；低于此值的界面初始化属正常。
    if (isNew && costNS > 300ULL * 1000ULL * 1000ULL) {
        SLFLog(@"[vc] 首次出现且初始化慢: %@ (%.0fms)",
               name, (double)costNS / 1e6);
    }
}

#pragma mark - 优化开关

// 关闭 reload 期间的隐式动画。
// 依据：UITableView/UICollectionView 的 reload 默认在隐式动画事务内执行，
// 会为每个变化生成动画事务与图层属性插值；批量数据变更时这部分开销可观。
// 语义无损：只关动画，不改数据流、不改刷新时机。
static BOOL gOptDisableImplicitAnimations = YES;

static inline BOOL SLFIsMainThreadNow(void) {
    return pthread_main_np() != 0;
}

#pragma mark - UITableView

__attribute__((noinline))
static void SLFTVReload(id self, SEL _cmd) {
    uint64_t t0 = SLFNowNS();
    @try {
        if (gOrigTVReload == NULL) return;   // 双保险：绝不转发空指针

        if (gOptDisableImplicitAnimations) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            gOrigTVReload(self, _cmd);
            [CATransaction commit];
        } else {
            gOrigTVReload(self, _cmd);
        }
    } @catch (__unused NSException *e) {
        // 吞掉异常。reload 失败最多是界面不刷新，绝不能让宿主崩。
    }
    SLFStatRecord(&gStatTVReload, SLFNowNS() - t0);
}

#pragma mark - UICollectionView

__attribute__((noinline))
static void SLFCVReload(id self, SEL _cmd) {
    uint64_t t0 = SLFNowNS();
    @try {
        if (gOrigCVReload == NULL) return;

        if (gOptDisableImplicitAnimations) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            gOrigCVReload(self, _cmd);
            [CATransaction commit];
        } else {
            gOrigCVReload(self, _cmd);
        }
    } @catch (__unused NSException *e) {}
    SLFStatRecord(&gStatCVReload, SLFNowNS() - t0);
}

#pragma mark - UIViewController

__attribute__((noinline))
static void SLFViewDidLoad(id self, SEL _cmd) {
    uint64_t t0 = SLFNowNS();
    @try {
        if (gOrigViewDidLoad) gOrigViewDidLoad(self, _cmd);
    } @catch (__unused NSException *e) {}
    uint64_t cost = SLFNowNS() - t0;
    SLFStatRecord(&gStatViewDidLoad, cost);

    // 只记录慢的，避免刷屏。类名是定位"哪个界面初始化慢"的关键证据。
    if (cost > 100ULL * 1000ULL * 1000ULL) {
        @try {
            SLFLog(@"[slow] viewDidLoad %@ 耗时 %.1fms",
                   NSStringFromClass([self class]), (double)cost / 1e6);
        } @catch (__unused NSException *e) {}
    }
}

__attribute__((noinline))
static void SLFViewDidAppear(id self, SEL _cmd, BOOL animated) {
    uint64_t t0 = SLFNowNS();
    @try {
        if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    } @catch (__unused NSException *e) {}
    uint64_t cost = SLFNowNS() - t0;
    SLFStatRecord(&gStatViewDidAppear, cost);

    @try {
        // 记录界面出现：用户点一次"新建快捷指令"，日志就会新增对应的类名。
        // 这是定位目标界面的可靠办法 —— 不靠猜类名。
        SLFNoteVCClass(NSStringFromClass([self class]), cost);

        if (cost > 200ULL * 1000ULL * 1000ULL) {
            SLFLog(@"[slow] viewDidAppear %@ 耗时 %.1fms",
                   NSStringFromClass([self class]), (double)cost / 1e6);
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - NSFetchedResultsController

__attribute__((noinline))
static BOOL SLFPerformFetch(id self, SEL _cmd, NSError **error) {
    uint64_t t0 = SLFNowNS();
    BOOL ret = NO;
    @try {
        if (gOrigPerformFetch) ret = gOrigPerformFetch(self, _cmd, error);
    } @catch (__unused NSException *e) {
        ret = NO;
    }
    uint64_t cost = SLFNowNS() - t0;
    SLFStatRecord(&gStatPerformFetch, cost);

    // 数据库拉取是"列表卡顿"的高频元凶，超过 50ms 就值得记一笔。
    if (cost > 50ULL * 1000ULL * 1000ULL) {
        @try {
            SLFLog(@"[slow] performFetch %@ 耗时 %.1fms",
                   NSStringFromClass([self class]), (double)cost / 1e6);
        } @catch (__unused NSException *e) {}
    }
    return ret;
}

#pragma mark - 安装

// 安全地替换某个类自身实现的方法。
// 关键点：方法若由父类实现，绝不能对父类 setImplementation（会污染父类及所有子类）。
// 这里先确认方法在本类的方法表里，找不到就放弃（不新增方法，避免改变继承语义）。
static BOOL SLFReplaceOwnMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (cls == Nil || sel == NULL || newImp == NULL) return NO;

    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL found = NO;
    if (list != NULL) {
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(list[i]) == sel) {
                found = YES;
                break;
            }
        }
        free(list);
    }
    if (!found) return NO;

    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return NO;

    IMP before = method_getImplementation(m);
    if (before == NULL) return NO;

    // 幂等保护：已经是我们的实现就不要再换（会形成自递归）。
    if (before == newImp) {
        if (outOrig && *outOrig == NULL) *outOrig = before;
        return YES;
    }

    method_setImplementation(m, newImp);
    if (outOrig) *outOrig = before;
    return YES;
}

static void SLFInstallAll(void) {
    BOOL ok = NO;

    // UITableView：reloadData 由 UITableView 自身实现
    ok = SLFReplaceOwnMethod([UITableView class], @selector(reloadData),
                             (IMP)SLFTVReload, (IMP *)&gOrigTVReload);
    SLFLogAlways(@"[hook] UITableView.reloadData %@", ok ? @"OK" : @"SKIP");

    // UICollectionView
    ok = SLFReplaceOwnMethod([UICollectionView class], @selector(reloadData),
                             (IMP)SLFCVReload, (IMP *)&gOrigCVReload);
    SLFLogAlways(@"[hook] UICollectionView.reloadData %@", ok ? @"OK" : @"SKIP");

    // UIViewController
    ok = SLFReplaceOwnMethod([UIViewController class], @selector(viewDidLoad),
                             (IMP)SLFViewDidLoad, (IMP *)&gOrigViewDidLoad);
    SLFLogAlways(@"[hook] UIViewController.viewDidLoad %@", ok ? @"OK" : @"SKIP");

    ok = SLFReplaceOwnMethod([UIViewController class],
                             @selector(viewDidAppear:),
                             (IMP)SLFViewDidAppear, (IMP *)&gOrigViewDidAppear);
    SLFLogAlways(@"[hook] UIViewController.viewDidAppear: %@", ok ? @"OK" : @"SKIP");

    // NSFetchedResultsController（CoreData，缺失也不影响其它 hook）
    Class frc = NSClassFromString(@"NSFetchedResultsController");
    if (frc != Nil) {
        ok = SLFReplaceOwnMethod(frc, @selector(performFetch:),
                                 (IMP)SLFPerformFetch, (IMP *)&gOrigPerformFetch);
        SLFLogAlways(@"[hook] NSFetchedResultsController.performFetch: %@", ok ? @"OK" : @"SKIP");
    } else {
        SLFLogAlways(@"[hook] NSFetchedResultsController 不存在，跳过");
    }

    // 子类覆写了这些方法的情况：子类实现会绕过我们的 hook。
    // 记录实际有哪些子类覆写了 reloadData，便于判断 hook 是否覆盖到目标界面。
    @try {
        unsigned int n = 0;
        int total = objc_getClassList(NULL, 0);
        if (total > 0) {
            Class *all = (Class *)calloc((size_t)total, sizeof(Class));
            if (all != NULL) {
                n = (unsigned int)objc_getClassList(all, total);
                NSMutableArray *overrides = [NSMutableArray array];
                for (unsigned int i = 0; i < n; i++) {
                    Class c = all[i];
                    Class sup = class_getSuperclass(c);
                    if (sup == Nil) continue;
                    // 只看直接继承 UITableView / UICollectionView 的子类
                    if ((sup == [UITableView class] || sup == [UICollectionView class])) {
                        unsigned int mc = 0;
                        Method *ml = class_copyMethodList(c, &mc);
                        BOOL has = NO;
                        if (ml) {
                            for (unsigned int k = 0; k < mc; k++) {
                                if (method_getName(ml[k]) == @selector(reloadData)) { has = YES; break; }
                            }
                            free(ml);
                        }
                        if (has && overrides.count < 20) {
                            [overrides addObject:NSStringFromClass(c)];
                        }
                    }
                }
                free(all);
                if (overrides.count > 0) {
                    SLFLogAlways(@"[hook] 注意：以下子类覆写了 reloadData，其调用不经过本插件: %@",
                                 [overrides componentsJoinedByString:@", "]);
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

// pthread_once 只接受 C 函数指针，不能传 block（block 无法隐式转换为函数指针）。
// 这里用 static 函数 + pthread_once，保证"检查 + 安装"原子完成。
// 曾因非原子的 检查-置位 导致双重安装：原实现被换成我们的实现再换回来 → 无限递归 → 栈溢出。
static void SLFInstallOnce(void) {
    @try {
        gOptDisableImplicitAnimations = SLFBool(@"OptDisableImplicitAnimations", YES);
        SLFInstallAll();
    } @catch (__unused NSException *e) {
        SLFLogAlways(@"[hook] 安装过程异常: %@", e);
    }
}

void SLFInstallHooks(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, SLFInstallOnce);
}

#pragma mark - 统计输出

void SLFDumpStats(void) {
    @try {
        SLFLog(@"[stat] UITableView.reloadData      %@", SLFStatDescribe(&gStatTVReload));
        SLFLog(@"[stat] UICollectionView.reloadData %@", SLFStatDescribe(&gStatCVReload));
        SLFLog(@"[stat] viewDidLoad                 %@", SLFStatDescribe(&gStatViewDidLoad));
        SLFLog(@"[stat] viewDidAppear               %@", SLFStatDescribe(&gStatViewDidAppear));
        SLFLog(@"[stat] performFetch                %@", SLFStatDescribe(&gStatPerformFetch));
    } @catch (__unused NSException *e) {}
}