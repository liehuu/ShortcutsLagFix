# ShortcutsLagFix

针对 **iOS 17 快捷指令 App「新建快捷指令」卡顿** 的诊断与缓解插件。

## 先说清楚：本插件的定位

我无法在没有你的设备数据的情况下断言卡顿的确切根因。任何"我修好了 XX bug"的说法都是猜的。

所以本插件的设计是：

1. **先精确测量** —— 主线程卡顿时，从外部抓取完整调用栈，直接告诉你卡在哪。
2. **再施加有依据的缓解** —— 只做语义无损的优化，且全部可开关。

日志拿到之后，根因自然浮现。这一步无法跳过。

## 它到底观测什么

| 机制 | 作用 |
|---|---|
| 主线程心跳 + 卡顿看门狗 | 主线程连续阻塞超过 `StallThresholdMS`（默认 250ms）时，从后台线程抓主线程栈 |
| 帧指针回溯 + 符号化 | 调用栈逐帧解析出镜像名与符号，定位到具体函数 |
| 方法耗时统计 | `reloadData` / `viewDidLoad` / `viewDidAppear:` / `performFetch:` 的调用次数、均值、峰值 |
| 界面类名记录 | 记录初始化较慢的界面类名，确认"新建快捷指令"实际进入的是哪个页面 |

## 它做什么优化

只有一项默认开启的优化：**`reloadData` 期间关闭隐式动画**（`OptDisableImplicitAnimations`）。

理由：`UITableView` / `UICollectionView` 的 `reloadData` 默认处在隐式动画事务内，会为每个变化生成动画事务与图层插值。批量数据变更时这部分开销可观。关闭动画**不改变数据流、不改变刷新时机**，因此不影响功能正确性。

其余"优化"我没有加。原因是：在不明确根因的前提下，任何更激进的改动（比如拦截刷新频率、缓存数据源）都有改变 App 行为的风险，这违背"不影响其他功能"的要求。

## 安装

本包是 **roothide 包**（`Architecture: iphoneos-arm64e`），可直接装在 RootHide /
Dopamine-roothide / Bootstrap 环境上，**不需要**再用 roothide Patcher 转换。

```bash
# 方式一：直接安装（在设备上，用 Sileo / Zebra / 命令行均可）
dpkg -i shortcutslagfix_1.0.5_iphoneos-arm64e.deb
killall -9 Shortcuts

# 方式二：本地编译（需要 macOS + Xcode）
./build.sh && python3 pack.py
```

> 装完必须 `killall -9 Shortcuts`，否则已运行的进程不会加载新 dylib。

### 关于 control 文件（第二个踩过的坑）

`control` **最后一个字段的值必须由换行符 `\n` 终结**。少了这一个字节，dpkg 会直接拒绝安装：

```
parsing file '/Library/dpkg/tmp.ci/control' near line 8
package 'com.liehuu.shortcutslagfix':
end of file during value of field 'Depends' (missing final newline)
```

`pack.py` 里的 `validate_control_text()` 会对**真正打进包的原始字节**做校验
（末尾换行 / CR 污染 / 空行 / `Key: value` 语法），CI 也有一道独立守卫。

⚠️ 注意校验时必须读原始字节：任何 `strip()`、`splitlines()`、`$(cat control)`
都会**静默吃掉尾随换行**，等于把要找的缺陷抹掉后再去检查它。

### 关于 Architecture 字段（踩过的坑，写在这里避免重复）

`Architecture` 在 iOS 越狱生态里**不是 CPU 架构，而是包布局标志**：

| 取值 | 含义 | 包内路径 |
|---|---|---|
| `iphoneos-arm` | rootful | 纯 `/Library/...`，无前缀 |
| `iphoneos-arm64` | rootless | 带 `/var/jb` 前缀 |
| `iphoneos-arm64e` | **roothide** | 纯 rootful 布局，前缀由 dpkg 自动加 |

名字里的 `arm64e` 与芯片架构无关。写成 `iphoneos-arm64e` 的包里，照样放
arm64 + arm64e 双切片 dylib。

若误写成 `iphoneos-arm64`，会出现两种失败：

1. Sileo 直接拒装，提示
   `You can contact the developer of this package to update it for roothide`
2. 用 roothide Patcher 强行转换后，路径被 libvroot 重映射出 `./rootfs/`，
   dpkg 去写真实根 `/Library` 而那里不可写：
   `error creating directory './rootfs/Library/MobileSubstrate': Operation not permitted`

包内**不应**自带 `.jbroot` 符号链接，也不应出现 `rootfs/` 或 `/var/jb` 前缀 ——
这些都由设备侧 dpkg / 加载器完成。`pack.py` 与 `verify_artifact.py` 已内置断言守卫。

安装后必须重启快捷指令 App：

```bash
killall -9 Shortcuts
```

## 使用与读日志

1. 安装后打开快捷指令 App。
2. 点「新建快捷指令」，复现卡顿。
3. 退出 App，查看日志。

日志路径（多候选自动探测，选第一个**真正可写**的；**日志首行会自报实际生效路径**）：

```
<jbroot>/var/mobile/Library/Logs/ShortcutsLagFix/ShortcutsLagFix.log
/var/mobile/Library/Logs/ShortcutsLagFix/ShortcutsLagFix.log
/var/jb/var/mobile/Library/Logs/ShortcutsLagFix/ShortcutsLagFix.log
<App 容器>/Library/Logs/ShortcutsLagFix/ShortcutsLagFix.log       ← 必然可写，兜底
<App 容器>/tmp/ShortcutsLagFix/ShortcutsLagFix.log
```

`<jbroot>` 在 RootHide 环境下形如
`/var/mobile/Containers/Shared/AppGroup/.jbroot-<HASH>/`，
**每台设备哈希不同**，请以日志首行打印的路径为准。

### 目录存在但日志为空？

这是**已经踩过一次**的坑，原因不是插件没加载，而是**权限**：

dpkg 以 root 解包，如果 `data.tar` 里带了 `/var/mobile/Library/Logs/ShortcutsLagFix`，
这个目录的属主就是 `root:wheel 755`。而快捷指令 App 跑在 **mobile** 用户下，
在 root 拥有的 755 目录里**创建不了文件**，于是 dylib 的写探测全部失败，
`gLogPath` 被置空，一条日志都不落 —— 看起来就是「插件装了但什么也没有」。

现在的做法：

- `data.tar` **完全不携带** `/var/mobile` 下的任何条目（可用 `dpkg-deb -c` 自查）
- 目录由 `postinst` 创建，并 `chown mobile:mobile`
- dylib 侧另加 App 容器这个**必然可写**的候选作为兜底

如果主路径仍为空，用下面命令定位实际日志（能搜到 = dylib 已被加载）：

```bash
find /var/mobile/Containers/Data/Application -name "ShortcutsLagFix.log" 2>/dev/null
```

一条都搜不到，才说明 dylib 根本没被加载器载入，那是另一个问题（注入目录 / 签名 / 过滤 plist）。

### 日志怎么读

```
[stall] 主线程已阻塞 1533ms (阈值 250ms) —— 第 24 次
    类型: 等待（锁 / 条件变量 / 跨进程消息）
    本段: 自 1.53s 前起，这是同一段阻塞的第 5 次上报（勿累加，段总长请看下面的「上一段结束」行）
    主线程 PC=0x1db2f8b7c
    #0  libsystem_kernel.dylib     __psynch_cvwait+0x8
    #1  Foundation                 0x1c8a30
    #2  UIKitCore                  0x8c1a4
    ...
```

- **`[stall]`** —— 卡顿现场。栈顶几帧就是元凶。
- **`类型:`** —— 插件自动归类，直接告诉你这是「等待」「系统一次性初始化」
  「视图图求值」还是「主队列拥塞」。33 次栈共约 300 行，人肉读极容易看错。
- **`本段:` / `上一段结束`** —— ⚠️ **同一段持续阻塞会每 100ms 上报一次，毫秒数绝不能累加。**
  实测某次日志里 5 次上报分别写着 969 / 1304 / 1333 / 1433 / 1533ms，
  加起来 6572ms，而该段真实长度只有 **1.69 秒**，虚报近 4 倍。
  真实总长只看 `[stall] 上一段结束：持续 X.XXs`。
- **`--- 补采热点 ---`** —— 栈断链（帧数太少）时自动隔 10ms 连采 8 次并聚合，
  给出命中最多的地址。断链的栈本来没有任何信息量，这一步把它救回来。
- **`[slow]`** —— 单个方法耗时超阈值。
- **`[vc]`** —— 初始化较慢的界面类名。
- **`[warmup]`** —— 预热各步耗时。这些成本已提前在后台付掉，不会再算到点击上。
- **`[stat]`** —— 每 `StatDumpInterval` 秒输出统计。注意 `viewDidLoad` /
  `viewDidAppear` 的 `avg=0.00ms` **属正常**：只 hook 了基类空实现，
  覆写了它的子类调用不经过插件，这两个数字只能用来看 hook 是否活着。
- **`[hook]`** —— 每个 hook 的安装结果。若是 `SKIP`，说明该方法不在目标类自身的方法表里。

## 实测诊断结论（截至 v1.0.5）

设备：iPhone12,3 / iOS 17.0.3。以下全部来自真实日志，每一条都能在日志里指到行。

### 第一次实测（v1.0.3，53 秒窗口）

**主线程有 16.65 秒不可用（约 31%）**。33 次 stall 上报，按区间合并后是 **14 段**。

| 段 | 时长 | 栈顶 | 归类 |
|---|---|---|---|
| 13:03:36.547 | **4.80s** | CoreFoundation + CFRunLoopRunSpecific | 主队列拥塞（栈断链） |
| 13:03:32.479 | **3.13s** | `_platform_memmove` → `libz inflate` → ImageIO → `CGDataProviderCopyData` → **WorkflowUIServices** | 图片同步解码 |
| 13:03:56.934 | 1.69s | `__psynch_cvwait` + Foundation + UIKit + **FLEXing.dylib** | 等待锁 |
| 13:03:45.304 | 1.53s | `mach_msg2_trap` | 等待消息 |
| 13:04:02.957 | 1.17s | `semaphore_wait_trap` + **FrontBoardServices** | 跨进程 IPC |

⚠️ **33 条不能相加**：直接求和得 28.77 秒，虚报 73%。同一次阻塞每 100ms 重复上报一次，
必须按区间求并集。v1.0.4 起日志会显式输出「上一段结束：持续 X 秒，期间上报 N 次」。

### 第二次实测（v1.0.4，35 秒窗口）

**主线程不可用约 7.8 秒（3 段：4.05s + 0.53s + 3.20s，另有 1 段 0.3s 未单独结算）。**

单看这个数字像是改善了，但**这一轮暴露的问题比解决的多**，所以不能这么比：

1. 两次的观察窗口和你的操作不同（第一次 53 秒、第二次 35 秒），**不可直接对比**；
2. v1.0.4 的预热自己跑了 **24 秒**；
3. 看门狗有 **12 秒观测盲区**；
4. 40 次上报上限被撞满后，**之后完全静音**。

### ✗ v1.0.4 的预热是负优化（v1.0.5 已关闭）

这是本版本最重要的结论，也是我必须先认的错。日志时间线：

```
13:27:34.287  [warmup] 开始
13:27:34.305  [warmup] CoreText 字体 7.3ms          ← 好，预期内
13:27:36.221  [warmup] 词典 trie 1779.3ms           ← 预期 298ms，超 6 倍
13:27:39.940  主线程开始阻塞（第 1~23 次上报，合并成一段 4.05s）
              栈顶：AutoFillUI → CFStringTokenizerCreate
                    → CoreNLP → liblangid:langid_consume_string
13:27:57.929  [warmup] 语言分析/mecab 21623.8ms     ← 21.6 秒！
13:27:58.327  [warmup] 完成，共 24030.5ms
```

主线程卡住的那 4 秒，栈顶是 **CoreNLP + liblangid**；
而我的预热当时正在另一个线程跑 `NLTokenizer` / `NLTagger`，**也是 CoreNLP + liblangid**。
两者共用同一套全局分析器状态（首次初始化时持锁）——
于是我"以为在帮它预热"，实际是"在跟它抢，把它拖住"。

**教训比功能重要**：预热的安全性不能靠"我在后台线程"来论证。
只要它触碰的是同一份全局状态，就可能在主线程最需要的时候把它锁住。

所以 v1.0.5 的处置：

- **`WarmupEnabled` 默认改为 `false`**（预热全部 opt-in）；
- **删除语言分析预热整段**（`NLTokenizer` / `NLTagger` / 日文 mecab），并移除
  `-framework NaturalLanguage` 依赖；
- 剩余步骤（字体 / 词典 trie / ImageIO）加**硬超时**（`WarmupStepTimeoutMS`，默认 2000ms），
  超时立刻放弃剩余步骤，不再出现"一步跑 21 秒"。

### ✗ 看门狗曾有 12 秒盲区（v1.0.5 已修）

日志里「上一段结束：持续 4.05s」这行的时间戳是 `13:27:56.056`，
但这一段真实结束于 `13:27:43.99` —— **落盘晚了 12.07 秒**，那 12 秒内主线程状况没有任何记录。

原因：三个 timer 挂在 `QOS_CLASS_UTILITY` 的**全局并发队列**上，worker 与别处共享。
预热一旦在 background 队列跑起 21.6 秒的长任务，utility 的 timer 到点也要重新抢 worker，
在 QoS 反压下被饿死。看门狗在自己最该工作的时候瞎了。

v1.0.5 改为**私有串行队列 + `QOS_CLASS_USER_INITIATED`**，并在每次段结算时输出
「本行落盘滞后 X 秒」—— 这个数字以后可以直接告诉你有没有盲区。

### ✗ 撞到上报上限后彻底失明（v1.0.5 已修）

`MaxStallReports` 达到 40 后，1.0.4 直接 `return`，**连段统计一起停掉**。
日志末尾 `reports=40`，之后用户再点「新建」产生的卡顿一条记录都没有。

v1.0.5 把配额检查移到段统计之后：**配额只限制抓栈与打印，段统计永远继续**，
并在超限时打印一次提示。默认值也从 40 提到 60。

### ✓ 插件自身曾贡献 631ms（v1.0.4 已修）

v1.0.0 第 1 次 stall 的栈里赫然是本插件：

```
#3  libobjc.A.dylib        objc_getClassList
#4  ShortcutsLagFix.dylib  SLFInstallOnce
#8  ShortcutsLagFix.dylib  __SLFScheduleSetup_block_invoke
```

主线程遍历全部已注册类（约 3 万个）耗时 **631ms**。慢的不是填充指针，而是对每类调
`class_getSuperclass` / `class_copyMethodList` 会触发 `realizeClass`
（实例化、挂方法列表、跑 `+load`）。

v1.0.4 已移到后台队列 + 每 1000 个类让出一次 runtime 锁（长时间持锁会让主线程的
msgSend 慢路径等锁，等于把卡顿换个名字）。

### ✓ 栈偏移量曾全部不可用（v1.0.5 已修）

v1.0.4 日志里 UIKitCore / CoreUI / CoreFoundation 的每一帧长这样：

```
#0  UIKitCore      <redacted>+0x508000000750
#2  libsystem_kernel.dylib  mach_msg+0x188000000018
```

高位是 PAC 签名残留，低位才是真实偏移（`0x750`、`0x18`）。这种数字喂不进 `atos`，
整个栈等于白抓。

根因：`SLFImageNameAndOffset` 注释写着"改用 image 基址"，代码却在
`dli_saddr <= addr` 时把偏移**改回** `addr - dli_saddr`；而 `addr` 从栈上读出时可能带
PAC 高位、`dli_saddr` 是已剥离的干净地址，两者相减就产出天文数字。

v1.0.5 的铁律：**偏移量只有一个来源 —— `addr - dli_fbase`**，符号名只作提示。
现在栈帧格式为：

```
#5  CoreFoundation  0x3a1b2c       near CFRunLoopRunSpecific
#6  UIKitCore       0x8c1a4
```

可以直接 `atos -o UIKitCore -arch arm64e 0x8c1a4`。

### 明确修不了的部分（不假装能修）

- **ImageIO 同步解压 3.13s**：App 渲染图库图标时同步解压整张图，未降采样。
  拦截 `CGDataProviderCopyData` 或篡改返回的 CGImage 尺寸会破坏布局，风险远大于收益。
- **SwiftUI / AttributeGraph**：14 段涉及视图图求值，最多的一段 3.1s。
  这是 App 自身的 body 重算，不改变渲染结果就降不下来。
- **FrontBoardServices 903ms**：主线程同步等 SpringBoard 的跨进程调用。
- **AutoFillUI 触发的语言识别**：v1.0.4 日志里主线程在
  `AutoFillUI → CFStringTokenizerCreate → CoreNLP` 上耗掉 4 秒。
  那是系统在密码自动填充栏里做语言判断，插件没有安全手段让它异步化。
- **FLEXing.dylib**：v1.0.3 日志里出现 5 段、涉及 4.45s。
  v1.0.4 日志里已不再出现，说明你已关掉 —— 请保持关闭状态再测，否则数据会混。

## 配置

编辑 `/var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist`，
**修改后需重启快捷指令 App** 才生效。

该文件由安装脚本 `postinst` 创建，属主是 `mobile`（不是 root），
所以 App 和你都能读写。配置缺失时插件会退回内置默认值，不会因此不工作。

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `DebugLog` | bool | `true` | 日志总开关 |
| `WatchdogEnabled` | bool | `true` | 卡顿看门狗 |
| `StallThresholdMS` | int | `250` | 判定卡顿的阻塞时长阈值 |
| `MaxStallReports` | int | `60` | 最多抓栈次数（超限后仍继续统计段，只是不再打印栈） |
| `StatDumpInterval` | int | `30` | 统计输出间隔（秒），0 = 关闭 |
| `OptDisableImplicitAnimations` | bool | `true` | reload 期间关闭隐式动画 |
| `WarmupEnabled` | bool | **`false`** | 后台预热（v1.0.5 改为默认关闭，见上文反证） |
| `WarmupDelayMS` | int | `1500` | 预热启动延迟，给 App 启动让路 |
| `WarmupLanguage` | bool | `false` | 仅兼容旧配置保留，语言分析预热已整段删除 |
| `WarmupStepTimeoutMS` | int | `2000` | 单个预热步骤的硬超时，超时放弃剩余步骤 |
| `ScanSubclasses` | bool | `true` | 后台扫描覆写 reloadData 的子类 |

> 升级安装时**不会**覆盖已有的配置文件（避免丢掉你的调参），所以旧配置里
> `WarmupEnabled` 可能仍是 `true`。**请手工改成 `false`**：
>
> ```bash
> cd /var/mobile/Library/Preferences
> plutil -replace WarmupEnabled -bool NO com.liehuu.shortcutslagfix.plist
> killall -9 Shortcuts
> ```
>
> 想自己做 A/B 就反过来设成 `true` 测一次，对比两次日志里的段总数与总时长。

## 安全设计

本插件只 hook **公开 API**，且所有签名都是 Apple 文档化、跨版本稳定的：

- `-[UITableView reloadData]`
- `-[UICollectionView reloadData]`
- `-[UIViewController viewDidLoad]`
- `-[UIViewController viewDidAppear:]`
- `-[NSFetchedResultsController performFetch:]`

刻意不做的事：

- **不 hook 任何私有方法**。私有方法签名未实机验证就直接转发，参数错位会把随机寄存器当对象指针用，直接崩宿主。
- **不 `dlopen` substrate**。RootHide 环境下同一库有多个可见路径，可能加载第二份 → 两套 swizzle 引擎改同一张方法表 → 表损坏。全部使用 libobjc 内建 API。
- **不 hook `layoutSubviews`**。它是每帧级高频方法，加计时会让所有滚动变慢 —— 与修卡顿的目标直接冲突。
- **hook 体内零文件 IO、零同步日志**。日志一律异步队列。
- **不篡改宿主数据**。不改 plist、不改 CoreData、不拦截数据流。

## 万一出问题怎么恢复

**卸载**：

```bash
dpkg -r com.liehuu.shortcutslagfix
killall -9 Shortcuts
```

或直接删除：

```
<jbroot>/Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.dylib
<jbroot>/Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.plist
```

**崩溃日志位置**：

```
/var/mobile/Library/Logs/CrashReporter/Shortcuts-*.ips
```

**如何区分"没生效"和"崩了"**：

- 日志文件**有内容**且含 `ShortcutsLagFix v1.0.0 已加载` → 插件在跑。
- 日志**完全不存在** → 插件没被加载，检查 dylib 架构与注入 plist。
- App **崩溃** → 查 CrashReporter 下的 `.ips`。

## 构建

需要 macOS（`xcrun` / `lipo` / `codesign`）。

```bash
./build.sh      # 编译 arm64 + arm64e 双切片并 adhoc 签名
python3 pack.py # 打包 deb（内置架构/签名/清单硬校验）
```

为什么必须双切片：设备是 arm64e（A12 及以上）。单 arm64 切片会被加载器直接跳过，
表现为"装了完全没反应"，极易误判成代码 bug。

## 项目结构

```
ShortcutsLagFix/
├── ShortcutsLagFix/
│   ├── SLFCommon.h       公共声明
│   ├── SLFCore.m         jbroot 反推 / 日志 / 配置 / 原子统计
│   ├── SLFWatchdog.m     主线程卡顿监测与栈回溯
│   ├── SLFHooks.m        hook 安装与耗时统计
│   └── SLFMain.m         dylib 入口（构造函数）
├── layout/               deb 内的文件布局
├── .github/workflows/build.yml
├── build.sh              双架构编译
├── pack.py               deb 打包 + 校验
├── lint.py               静态检查（15 项）
├── check_decls.py        声明一致性校验
└── test_pack.py          打包逻辑离线测试
```

## License

MIT