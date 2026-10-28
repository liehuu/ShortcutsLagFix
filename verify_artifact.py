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
        ctrl = t.extractfile(cn[0]).read().decode("utf-8")
    os.remove(tmpc)
    for line in ctrl.strip().split("\n"):
        print("      " + line)
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
            "./var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist",
        ]
        for m in must:
            if m in infos:
                ok("存在 %s" % os.path.basename(m))
            else:
                bad("缺少 %s" % m)

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

        # 预置配置必须可解析且含真实开关
        if must[2] in infos:
            cfg = plistlib.loads(t.extractfile(must[2]).read())
            expected = ["DebugLog", "WatchdogEnabled", "StallThresholdMS",
                        "MaxStallReports", "StatDumpInterval",
                        "OptDisableImplicitAnimations"]
            for k in expected:
                if k in cfg:
                    ok("配置含 %s = %r" % (k, cfg[k]))
                else:
                    bad("配置缺少 %s" % k)
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
    ]
    probes_ascii = [
        b"com.apple.shortcuts",
        b"reloadData",
        b"viewDidAppear:",
        b"performFetch:",
        b"ShortcutsLagFix.dylib",
    ]
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