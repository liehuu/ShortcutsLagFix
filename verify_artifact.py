#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
交付前产物验尸脚本（对真实 CI 产物执行，不依赖 macOS 工具）。

检查项：
  1. ar 结构合法、成员齐全
  2. control 字段符合 dpkg 要求
  3. data 清单里该有的文件都在、权限正确
  4. 内嵌 dylib 是 FAT 双切片，且逐切片 cputype/subtype 校验
     - arm64  : cputype=0x0100000c subtype=0
     - arm64e : cputype=0x0100000c subtype=2   ← 这一项曾经让插件静默失效
  5. dylib 内含关键字符串（构造函数日志、类名），确认代码真的编进去了
  6. install_name 与 RootHide 布局一致
  7. 预置 plist 可被 plistlib 解析
"""

import os
import sys
import struct
import tarfile
import plistlib
import importlib.util

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pack", os.path.join(ROOT, "pack.py"))
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0x00FFFFFF      # 低位才是真实 subtype
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000  # 高位是 ABI 标志，不是 subtype 本身

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def classify_arm64_subtype(cpusub):
    """把 cpusub 归一化为可读架构名。

    ★ 关键易错点：arm64e 的 subtype 实测为 0x80000002，
    即 CPU_SUBTYPE_ARM64E(2) | CPU_SUBTYPE_PTRAUTH_ABI(0x80000000)。
    早期判定写成 `subtype == 2` 会把正确的 arm64e 切片误判为未知，
    进而得出"产物缺少 arm64e"的错误结论（本次真实踩到：
    产物本身完全正确，是校验脚本判错）。
    正确做法：先掩掉高位标志，再比对低位。
    """
    base = cpusub & CPU_SUBTYPE_MASK
    if base == CPU_SUBTYPE_ARM64E:
        return "arm64e"
    if base == CPU_SUBTYPE_ARM64_ALL:
        return "arm64"
    return "arm64(subtype=0x%x)" % cpusub


def check_macho_fat(data, label):
    """解析 FAT 头，返回 [(arch_name, cputype, subtype), ...]"""
    if len(data) < 8:
        raise AssertionError("%s: 文件过短" % label)
    magic = struct.unpack(">I", data[0:4])[0]
    if magic != FAT_MAGIC:
        raise AssertionError(
            "%s: 不是 FAT 二进制（magic=0x%08x）。单切片在 arm64e 设备上会静默失效"
            % (label, magic))
    nfat = struct.unpack(">I", data[4:8])[0]
    if nfat < 1 or nfat > 16:
        raise AssertionError("%s: nfat_arch 异常: %d" % (label, nfat))

    out = []
    for i in range(nfat):
        base = 8 + i * 20
        cputype, cpusub, offset, size, align = struct.unpack(
            ">IIIII", data[base:base + 20])
        if cputype == CPU_TYPE_ARM64:
            name = classify_arm64_subtype(cpusub)
        else:
            name = "cputype=0x%x(subtype=0x%x)" % (cputype, cpusub)
        out.append((name, cputype, cpusub, offset, size))
        if offset + size > len(data):
            raise AssertionError("%s: 切片 %s 越界" % (label, name))
    return out


def main(deb_path):
    if not os.path.exists(deb_path):
        print("[FAIL] 文件不存在: %s" % deb_path)
        return 1

    print("=" * 60)
    print("产物体检: %s (%d bytes)" % (deb_path, os.path.getsize(deb_path)))
    print("=" * 60)

    fails = []

    def ok(msg):
        print("  [OK]   " + msg)

    def bad(msg):
        print("  [FAIL] " + msg)
        fails.append(msg)

    # ---- 1. ar 结构 ----
    print("\n[1] ar 结构")
    try:
        members = pack.parse_ar(deb_path)
        names = [n for n, _ in members]
        ok("成员: %s" % names)
        for need in ("debian-binary", "control.tar.gz", "data.tar.gz"):
            if need in names:
                ok("存在 %s" % need)
            else:
                bad("缺少 %s" % need)
        if dict(members).get("debian-binary") != b"2.0\n":
            bad("debian-binary 内容不是 '2.0\\n'")
        else:
            ok("debian-binary = '2.0\\n'")
    except SystemExit:
        bad("ar 解析失败")
        return 1

    d = dict(members)

    # ---- 2. control ----
    print("\n[2] control 字段")
    tmpc = os.path.join(ROOT, "_x_control.tar.gz")
    with open(tmpc, "wb") as f:
        f.write(d["control.tar.gz"])
    with tarfile.open(tmpc, "r:gz") as t:
        cn = [n for n in t.getnames() if n.endswith("control")]
        raw_ctrl = t.extractfile(cn[0]).read()
        ctrl = raw_ctrl.decode("utf-8")
        # postinst 也需要在这里取出来：它负责把 /var/mobile 下的目录
        # 建成 mobile 属主，是「日志目录为空」那次事故的修复落点。
        pi_members = [m for m in t.getmembers()
                      if m.name.lstrip("./") == "postinst"]
        raw_postinst = t.extractfile(pi_members[0]).read() if pi_members else None
        pi_mode = (pi_members[0].mode & 0o777) if pi_members else None
    os.remove(tmpc)
    for line in ctrl.strip().split("\n"):
        print("      " + line)

    # ★ 先做语法校验（dpkg 是否愿意解析），再做字段内容校验。
    # 历史漏洞：此前所有检查都是「内容包含」式，没有任何一项检查
    # control 的语法合规性。于是末尾缺换行的包全部检查通过，
    # 装到设备被 dpkg 拒绝：
    #   end of file during value of field 'Depends' (missing final newline)
    # 注意：不能用 ctrl.strip() 后的文本判断 —— strip 会把缺失的换行吃掉，
    # 必须看原始字节。
    syntax_problems = pack.validate_control_text(raw_ctrl)
    if syntax_problems:
        for p in syntax_problems:
            bad("control 语法: " + p)
    else:
        ok("control 语法合规（%d 字节，末尾换行正确，无 CR）" % len(raw_ctrl))

    for key in ("Package:", "Name:", "Version:", "Architecture:", "Maintainer:", "Depends:"):
        if key in ctrl:
            ok("含 %s" % key)
        else:
            bad("缺少 %s" % key)
    # ★ 必须整行精确比对，不能用 `in ctrl` 做子串匹配。
    # 原因：`"Architecture: iphoneos-arm64" in ctrl` 对
    # `Architecture: iphoneos-arm64e` 同样为 True ——
    # 换句话说，那个写法在架构值【错误】时也会报 OK，
    # 是一个永远通过、毫无作用的假检查（本次事故正是因为
    # 该检查从未真正生效，才让 iphoneos-arm64 的包一路交付出去）。
    # 现在直接和 pack.py 的常量对齐，改了一处会立刻暴露。
    arch_lines = [l.strip() for l in ctrl.splitlines()
                  if l.lower().startswith("architecture:")]
    if not arch_lines:
        bad("control 中没有 Architecture 行")
    else:
        got_arch = arch_lines[0].split(":", 1)[1].strip()
        if got_arch == pack.ARCH:
            ok("Architecture = %s（roothide 包布局）" % got_arch)
        else:
            bad("Architecture 为 %r，应为 %r —— "
                "Sileo 会拒绝安装并提示 update for roothide；"
                "强行用 roothide Patcher 转换会触发 "
                "'.//rootfs/Library/MobileSubstrate: Operation not permitted'"
                % (got_arch, pack.ARCH))

    # roothide 的包结构必须与 rootful 包相同：dpkg 会自行把文件装进
    # 随机化的 bootstrap 路径，包里【不能】自己带任何前缀。
    for forbidden in ("/var/jb", "rootfs/"):
        if forbidden in ctrl:
            bad("control 中出现 %r，roothide 包不应自带路径前缀" % forbidden)
        else:
            ok("control 未出现 %r" % forbidden)

    # ---- 2b. postinst（日志目录属主）----
    print("\n[2b] postinst 与 /var/mobile 属主")
    if raw_postinst is None:
        bad("control.tar 里没有 postinst —— 无人创建/chown 日志目录，"
            "App(mobile) 将写不进日志，表现为「日志目录存在但为空」")
    else:
        if pi_mode == 0o755:
            ok("postinst 权限 755（dpkg 可直接 exec）")
        else:
            bad("postinst 权限为 %s，dpkg 需要 755" % oct(pi_mode))
        if raw_postinst.startswith(b"#!/bin/sh"):
            ok("postinst shebang 正确")
        else:
            bad("postinst 首行不是 #!/bin/sh")
        if not raw_postinst.endswith(b"\n"):
            bad("postinst 末尾缺少换行（与 control 缺换行同一类问题）")
        txt = raw_postinst.decode("utf-8", "replace")
        if "Logs/ShortcutsLagFix" in txt and "chown" in txt:
            ok("postinst 会创建日志目录并 chown 给 mobile")
        else:
            bad("postinst 未对日志目录 chown，App 仍写不进日志")
        # 预置配置现在由 postinst 写入（属主 mobile，App 与用户都能改）。
        expected = ["DebugLog", "WatchdogEnabled", "StallThresholdMS",
                    "MaxStallReports", "StatDumpInterval",
                    "OptDisableImplicitAnimations",
                    "WarmupEnabled", "WarmupDelayMS", "ScanSubclasses"]
        missing = [k for k in expected if k not in txt]
        if missing:
            bad("postinst 内嵌配置缺少键: %s" % ", ".join(missing))
        else:
            ok("postinst 内嵌配置含全部 %d 个键" % len(expected))

    # ---- 3. data 清单 ----
    print("\n[3] data 清单与权限")
    tmpd = os.path.join(ROOT, "_x_data.tar.gz")
    with open(tmpd, "wb") as f:
        f.write(d["data.tar.gz"])
    with tarfile.open(tmpd, "r:gz") as t:
        infos = {m.name: m for m in t.getmembers()}
        embedded = None
        for n in infos:
            print("      %-78s %o" % (n, infos[n].mode))
        must = [
            "./Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.dylib",
            "./Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.plist",
        ]
        for m in must:
            if m in infos:
                ok("存在 %s" % os.path.basename(m))
            else:
                bad("缺少 %s" % m)

        # ★ data.tar 里不允许出现 /var/ 条目。
        # 真实事故：把 /var/mobile/Library/Logs/ShortcutsLagFix 放进 data.tar，
        # dpkg 以 root:wheel 755 创建它；快捷指令 App 跑在 mobile 下，
        # 建不了文件 → 日志目录永远为空 → 看起来像插件根本没加载。
        # 这些目录必须由 postinst 创建并 chown 给 mobile。
        var_entries = [n for n in infos if n == "./var" or n.startswith("./var/")]
        if var_entries:
            for n in var_entries:
                bad("data 含 /var 条目 %r —— dpkg 会以 root 属主创建它，"
                    "App(mobile) 无法写入，日志将永远为空。应改由 postinst 创建" % n)
        else:
            ok("data 不含任何 /var 条目（/var/mobile 由 postinst 以 mobile 属主创建）")

        debian_entries = [n for n in infos if n.lstrip("./").startswith("DEBIAN")]
        if debian_entries:
            bad("data 含 DEBIAN 条目 %r —— 维护脚本属于 control.tar，"
                "混进 data 不会被执行" % debian_entries)
        else:
            ok("data 不含 DEBIAN（维护脚本只在 control.tar 里）")

        # ★ roothide 包布局硬约束：所有条目必须是纯 rootful 路径。
        # 出现 ./rootfs/ 或 ./var/jb/ 就说明包被"转换"过或架构值写错，
        # 装上去必然报 Operation not permitted。
        # 这是用户实际遇到的报错原文：
        #   error creating directory './rootfs/Library/MobileSubstrate':
        #   Operation not permitted
        bad_prefix = [n for n in infos
                      if n.startswith("./rootfs/") or n.startswith("./var/jb/")
                      or n == "./rootfs" or n == "./var/jb"]
        if bad_prefix:
            for n in bad_prefix:
                bad("data 含非法前缀条目 %r（会被 libvroot 重映射到真实根，装不上）" % n)
        else:
            ok("data 全部为纯 rootful 路径（无 /var/jb、无 rootfs/ 前缀）")

        # RootHide 只要求 dylib 里写 @loader_path/.jbroot/...，
        # 【不需要】在包里真的放一个 .jbroot 符号链接 —— 该链接由 dpkg
        # 或加载器在设备上创建。实测参考包（nolockwallpaper 1.7-1，
        # 已在 roothide 设备安装成功）的 data.tar 里就没有 .jbroot。
        # 这里做正向断言，防止以后有人"好心"加进去反而破坏布局。
        jbroot_entries = [n for n in infos if ".jbroot" in n]
        if jbroot_entries:
            bad("data 里出现 .jbroot 条目 %r —— 该符号链接应由设备侧创建，"
                "包内自带会导致布局异常" % jbroot_entries)
        else:
            ok("data 未内置 .jbroot（符合 RootHide 规范，由设备侧创建）")

        if must[0] in infos:
            embedded = t.extractfile(must[0]).read()
            if infos[must[0]].mode == 0o755:
                ok("dylib 权限 755")
            else:
                bad("dylib 权限 %o，应为 755" % infos[must[0]].mode)

        # 注入过滤 plist 必须含目标 bundle
        if must[1] in infos:
            pl = t.extractfile(must[1]).read().decode("utf-8", "replace")
            if "com.apple.shortcuts" in pl:
                ok("注入过滤含 com.apple.shortcuts")
            else:
                bad("注入过滤不含 com.apple.shortcuts，插件永不加载")
    os.remove(tmpd)

    # ---- 4. dylib 架构 ----
    print("\n[4] dylib 架构（最关键）")
    if embedded is None:
        bad("无法取得内嵌 dylib")
        return 1

    try:
        archs = check_macho_fat(embedded, "dylib")
        got = [a[0] for a in archs]
        ok("FAT 切片: %s" % got)

        if "arm64" in got:
            ok("含 arm64 切片")
        else:
            bad("缺 arm64 切片")

        if "arm64e" in got:
            ok("含 arm64e 切片（arm64e 设备可加载）")
        else:
            bad("缺 arm64e 切片 -> 在 arm64e 设备上会被加载器跳过，表现为「装了没反应」")

        for name, ct, cs, off, sz in archs:
            print("      %-8s cputype=0x%08x subtype=%d offset=0x%x size=%d"
                  % (name, ct, cs, off, sz))
    except AssertionError as e:
        bad(str(e))

    # ---- 5. 关键字符串 ----
    print("\n[5] 代码内容抽查")
    # ObjC 字符串字面量在 arm64 上按 UTF-16LE 存放
    probes_utf16 = [
        "ShortcutsLagFix",
        "已加载",
        "主线程已阻塞",
        # ★ 以下字符串确认 v1.0.4 的三处新增真的被编进了二进制。
        # 不查这些的话，CI 万一 checkout 到旧代码，验尸照样全绿 ——
        # 那等于交付了一个"看起来修好了"的旧包。
        "[warmup]",                    # 预热子系统
        "系统一次性初始化",             # 阻塞类型自动分类
        "主队列拥塞",                   # 断链时的判定分支
        "补采热点",                     # 断链多采样聚合
    ]
    probes_ascii = [
        b"com.apple.shortcuts",
        b"reloadData",
        b"viewDidAppear:",
        b"performFetch:",
        b"ShortcutsLagFix.dylib",
    ]
    # ★ 日志路径兜底必须真的被编译进产物。
    # 真实事故：日志目录被 dpkg 以 root 属主创建，App(mobile) 写不进去，
    # 旧版四个候选（jbroot / /var/jb / 真实 /var/mobile / 硬编码 /tmp）全部
    # 不可写，gLogPath 直接置空，一条日志都不写 —— 现场看起来就是
    # 「插件装了但日志目录是空的」。修复的关键是加了 App 容器这一个
    # 【必然可写】的候选，所以必须断言它存在于二进制里，
    # 否则可能 CI 编的还是旧代码而验尸照样全绿。
    # 字面量可能存成 UTF-16LE 也可能存成 ASCII，两种都认。
    log_probe = "Library/Logs/ShortcutsLagFix"
    if (log_probe.encode("utf-16-le") in embedded) or (log_probe.encode("ascii") in embedded):
        ok("含日志兜底路径 'Library/Logs/ShortcutsLagFix'（App 容器必可写）")
    else:
        bad("缺日志兜底路径 'Library/Logs/ShortcutsLagFix' —— "
            "说明编译的是旧代码，日志目录仍可能写不出来")

    # ★ 版本号必须与 control 一致。
    #
    # 真实事故：SLFCommon.h 曾把版本写死为 "1.0.0"，之后 control 依次升到
    # 1.0.1 / 1.0.2 / 1.0.3，而三次交付的 dylib 全都自报 v1.0.0。
    # 拿到用户日志时我第一反应是"你是不是装了旧包"，白排查一轮。
    # 现在版本由 build.sh 从 control 注入，且在这里做产物级复核。
    ctrl_ver = ""
    try:
        with open(os.path.join(ROOT, "control"), "rb") as f:
            for line in f.read().decode("utf-8").split("\n"):
                if line.startswith("Version:"):
                    ctrl_ver = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    if not ctrl_ver:
        bad("读不到 control 的 Version，无法校验产物版本")
    else:
        # C 字符串字面量以 NUL 结尾，用 NUL 边界避免 "1.0.4" 命中 "1.0.40"
        if (ctrl_ver.encode("ascii") + b"\x00") in embedded or \
           (ctrl_ver.encode("utf-16-le") in embedded):
            ok("产物内版本号 = %s（与 control 一致）" % ctrl_ver)
        else:
            bad("产物内找不到版本号 %r —— -DSLF_VERSION 未生效，"
                "日志会自报 0.0.0-unknown，排查时会被误导" % ctrl_ver)

    for s in probes_utf16:
        if s.encode("utf-16-le") in embedded:
            ok("含字符串 '%s'" % s)
        else:
            bad("缺字符串 '%s'" % s)
    for b in probes_ascii:
        if b in embedded:
            ok("含 %s" % b.decode())
        else:
            bad("缺 %s" % b.decode())

    # 危险符号不得出现（确认没有误引入 substrate 依赖）
    for danger in (b"imp_implementationWithBlock",):
        if danger in embedded:
            bad("发现禁止符号 %s" % danger.decode())
        else:
            ok("未使用 %s" % danger.decode())

    # ---- 6. install_name ----
    print("\n[6] install_name（RootHide 路径）")
    expect = b"@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.dylib"
    if expect in embedded:
        ok("install_name 指向 RootHide 布局")
    else:
        # 也可能是绝对路径写法，只要含 .jbroot 就算可接受
        if b".jbroot" in embedded:
            ok("含 .jbroot 路径（install_name 可用）")
        else:
            bad("未发现 .jbroot 路径，RootHide 下可能找不到依赖")

    # ---- 汇总 ----
    print("\n" + "=" * 60)
    if fails:
        print("结论: 不可交付，%d 项失败" % len(fails))
        for f in fails:
            print("  - " + f)
        return 1
    print("结论: 全部通过，可交付")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        ROOT, "debs", "%s_%s_%s.deb" % (pack.NAME, pack.VERSION, pack.ARCH))
    sys.exit(main(path))