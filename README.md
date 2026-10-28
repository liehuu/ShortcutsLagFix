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
dpkg -i shortcutslagfix_1.0.2_iphoneos-arm64e.deb
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

日志路径（多候选自动探测，**日志首行会自报实际生效路径**）：

```
<jbroot>/var/mobile/Library/Logs/ShortcutsLagFix/ShortcutsLagFix.log
/var/mobile/Library/Logs/ShortcutsLagFix/ShortcutsLagFix.log
/tmp/ShortcutsLagFix/ShortcutsLagFix.log
```

`<jbroot>` 在 RootHide 环境下形如
`/var/mobile/Containers/Shared/AppGroup/.jbroot-<HASH>/`，
**每台设备哈希不同**，请以日志首行打印的路径为准。

### 日志怎么读

```
[stall] 主线程已阻塞 1842ms (阈值 250ms) —— 第 1 次
    主线程 PC=0x1a2b3c4d5
    #0  Shortcuts   -[WFWorkflowDataSource ...]+0x2c
    #1  UIKitCore   -[UITableView reloadData]+0x118
    ...
```

- **`[stall]`** —— 卡顿现场。这是最关键的证据，栈顶几帧就是元凶。
- **`[slow]`** —— 单个方法耗时超阈值。
- **`[vc]`** —— 初始化较慢的界面类名。
- **`[stat]`** —— 每 `StatDumpInterval` 秒输出一次统计，用于对比开关优化前后的差异。
- **`[hook]`** —— 每个 hook 的安装结果。若是 `SKIP`，说明该方法不在目标类自身的方法表里。

## 配置

编辑 `/var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist`，
**修改后需重启快捷指令 App** 才生效：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `DebugLog` | bool | `true` | 日志总开关 |
| `WatchdogEnabled` | bool | `true` | 卡顿看门狗 |
| `StallThresholdMS` | int | `250` | 判定卡顿的阻塞时长阈值 |
| `MaxStallReports` | int | `40` | 单次运行最多抓栈次数 |
| `StatDumpInterval` | int | `30` | 统计输出间隔（秒），0 = 关闭 |
| `OptDisableImplicitAnimations` | bool | `true` | reload 期间关闭隐式动画 |

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