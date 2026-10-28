#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ShortcutsLagFix deb 打包脚本。

不用 dpkg-deb 的原因：GitHub Actions 的 macos runner 默认没有 dpkg，
而 deb 本身只是 ar 归档，格式简单且完全可手工构造。

内置硬闸门（把历史事故变成断言）：
  - dylib 必须 arm64 + arm64e 双切片
  - dylib 必须已 adhoc 签名
  - 注入过滤 plist 必须存在且包含目标 bundle id
  - 预置配置文件必须存在
  - 打包后回读校验 ar 结构与内嵌文件
"""

import os
import sys
import shutil
import tarfile
import hashlib
import struct
import subprocess

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(ROOT, "build")
LAYOUT = os.path.join(ROOT, "layout")
OUTDEB = os.path.join(ROOT, "debs")

NAME = "shortcutslagfix"
PKG = "com.liehuu.shortcutslagfix"
VERSION = "1.0.3"

# ---------------------------------------------------------------------------
# Architecture 不是 CPU 架构，而是【包布局标志】。这是 RootHide 踩过的最大的坑：
#
#   iphoneos-arm     = rootful   （/ 就是真实根，无前缀）
#   iphoneos-arm64   = rootless  （前缀 /var/jb）
#   iphoneos-arm64e  = roothide  （随机 bootstrap 前缀）
#
# 名字里的 arm64e 与 CPU 架构毫无关系 —— 写成 iphoneos-arm64e 的包，
# 里面照样可以（也应该）放 arm64 + arm64e 双切片 dylib。
#
# 实测证据（本机另一个已在 roothide 设备上安装成功的包
# com.liehuu.nolockwallpaper_1.7-1）：
#   · 同一次构建产出两个 deb，control 唯一差异就是这一行
#   · 两者的 data.tar 文件清单【逐条完全相同】，均为纯 rootful 路径
#     `./Library/MobileSubstrate/DynamicLibraries/...`，不含 /var/jb、
#     不含 .jbroot 前缀目录、不含 rootfs/
#   · dylib 的 LC_ID_DYLIB 为 `@loader_path/.jbroot/Library/...`
#
# 历史事故：曾写成 iphoneos-arm64，Sileo 拒绝安装并提示
#   "You can contact the developer of this package to update it for roothide"
# 用户用 roothide Patcher 强行转换后，路径被 libvroot 重映射出 `./rootfs/`，
# dpkg 去写真实根 `/Library` 而那里不可写，报
#   error creating directory './rootfs/Library/MobileSubstrate': Operation not permitted
# 结论：不要靠 Patcher 转换，直接出 iphoneos-arm64e 包。
# ---------------------------------------------------------------------------
ARCH = "iphoneos-arm64e"

DYLIB = os.path.join(BUILD, "ShortcutsLagFix.dylib")


def die(msg):
    print("[pack][FATAL] " + msg, file=sys.stderr)
    sys.exit(1)


def check_dylib():
    if not os.path.exists(DYLIB):
        die("dylib 不存在，先跑 build.sh: %s" % DYLIB)

    # 直接解析 FAT 头判定双切片。
    # 不用 lipo 的原因：CI 上有 lipo，但本地 Windows 没有；
    # 而 `lipo -info | grep arm64e` 这种文本匹配无法区分
    # "arm64e 切片存在" 与 "只输出里恰好出现 arm64e 字样"。
    # 字节级判定更可靠，且两边行为一致。
    with open(DYLIB, "rb") as f:
        head = f.read(8)
    if head[0:4] != b"\xca\xfe\xba\xbe":
        die("dylib 不是 FAT 二进制（magic=%r）。"
            "单切片产物在 arm64e 设备上会被加载器跳过" % head[0:4])

    nfat = struct.unpack(">I", head[4:8])[0]
    archs = []
    with open(DYLIB, "rb") as f:
        for i in range(nfat):
            f.seek(8 + i * 20)
            cputype, cpusub = struct.unpack(">II", f.read(8))
            # arm64e 的 subtype 实测为 0x80000002（含 PTRAUTH_ABI 标志位），
            # 必须掩掉高位再比对，否则会把正确的 arm64e 判成未知（已踩）。
            base = cpusub & 0x00FFFFFF
            if cputype == 0x0100000C:
                archs.append({0: "arm64", 2: "arm64e"}.get(base, "arm64(0x%x)" % cpusub))
            else:
                archs.append("cputype0x%x" % cputype)

    print("[pack] 架构: %s" % archs)
    if "arm64" not in archs:
        die("产物不含 arm64")
    if "arm64e" not in archs:
        die("产物不含 arm64e —— 在用户 arm64e 设备上会静默失效，拒绝交付")

    # adhoc 签名检查（RootHide 加载器会跳过无签名 dylib）
    try:
        dv = subprocess.run(["codesign", "-dv", DYLIB],
                            capture_output=True, text=True)
        combined = (dv.stdout or "") + (dv.stderr or "")
        if "Signature=adhoc" in combined or "Signature=Ad Hoc" in combined:
            print("[pack] adhoc 签名 OK")
        else:
            die("dylib 未 adhoc 签名，RootHide 加载器会跳过它")
    except FileNotFoundError:
        print("[pack] 无 codesign（非 macOS），跳过签名校验 —— 由 CI 保证")


def check_layout():
    dl = os.path.join(LAYOUT, "Library/MobileSubstrate/DynamicLibraries")
    pl = os.path.join(dl, "ShortcutsLagFix.plist")
    postinst = os.path.join(LAYOUT, "DEBIAN/postinst")

    if not os.path.exists(pl):
        die("缺少注入过滤 plist: " + pl)
    with open(pl, "r", encoding="utf-8") as f:
        content = f.read()
    if "com.apple.shortcuts" not in content and "is.workflow.my.app" not in content:
        die("过滤 plist 不含目标 bundle id，插件永不会被加载")

    if not os.path.exists(os.path.join(dl, "ShortcutsLagFix.dylib")):
        die("layout 里没有 dylib，先跑 build.sh")

    # ★ data.tar 里绝不允许出现 /var/mobile 下的条目。
    #
    # dpkg 以 root 解包，tar 的目录条目会变成 root:wheel 755。而快捷指令
    # App 以 mobile 身份运行，在 root 拥有的目录里建不了文件，于是
    # 「日志目录存在但一条日志都没有」—— 现场看起来像插件没被加载。
    # 这些目录一律由 postinst 创建并 chown 给 mobile。
    # 参考实现（同一打包管线、同设备装成功）的 data.tar 里同样没有任何 var/ 条目。
    var_dir = os.path.join(LAYOUT, "var")
    if os.path.exists(var_dir):
        die("layout 下存在 var/ 目录。data.tar 不得携带 /var/mobile 条目："
            "dpkg 会以 root 属主创建它们，App(mobile) 无法写入，"
            "导致日志目录为空。请把目录创建移到 layout/DEBIAN/postinst 里。")

    if not os.path.exists(postinst):
        die("缺少 postinst: " + postinst)
    with open(postinst, "rb") as f:
        pi = f.read()
    if not pi.startswith(b"#!/bin/sh"):
        die("postinst 缺少 '#!/bin/sh' 首行，dpkg 无法执行它")
    if not pi.endswith(b"\n"):
        die("postinst 末尾缺少换行（与 control 同一类问题）")
    # 关键判据：postinst 必须真的把目录 chown 给 mobile，否则等于没做。
    if b"chown" not in pi or b"Logs/ShortcutsLagFix" not in pi:
        die("postinst 未对日志目录执行 chown，App(mobile) 仍无法写日志")

    print("[pack] layout 校验 OK")


def make_control():
    """读取仓库根目录的 control 文件，作为唯一真源。

    历史上这里曾是硬编码的字符串副本，与根目录 control 形成两份真源。
    改架构值时改了副本、忘了根文件（或反之），就会重演
    iphoneos-arm64 / iphoneos-arm64e 那次安装失败。
    现在只允许一处定义，并且在这里做一致性断言。
    """
    ctrl_path = os.path.join(ROOT, "control")
    if not os.path.exists(ctrl_path):
        die("缺少 control 文件: " + ctrl_path)
    with open(ctrl_path, "r", encoding="utf-8") as f:
        control = f.read()

    # 断言：control 里的 Package / Version / Architecture 必须与脚本常量一致。
    # 这样"改了 control 忘了改 pack.py"或反之，都会立刻炸出来。
    for key, want in (("Package", PKG), ("Version", VERSION), ("Architecture", ARCH)):
        got = None
        for line in control.splitlines():
            if line.lower().startswith(key.lower() + ":"):
                got = line.split(":", 1)[1].strip()
                break
        if got != want:
            die("control 的 %s 为 %r，与 pack.py 常量 %r 不一致。"
                "两处必须同步，否则会产出错误的包。" % (key, got, want))

    print("[pack] control 校验 OK (Architecture=%s, Version=%s)" % (ARCH, VERSION))

    # ★ 语法校验：dpkg 解析 control 时按「字段行」逐行读，
    # 最后一个字段的值必须由换行符终结。缺了这个换行，dpkg 报：
    #   parsing file '/Library/dpkg/tmp.ci/control' near line N
    #   package 'xxx': end of file during value of field 'Depends'
    #   (missing final newline)
    # 这是真实事故：control 最后一行没有 '\n'，包打得出来、
    # 所有自研检查全绿（因为读的时候 .strip() 把尾巴吃掉了），
    # 装到设备上才被 dpkg 拒绝。
    control_bytes = control.encode("utf-8")
    if not control_bytes.endswith(b"\n"):
        die("control 文件末尾缺少换行符。dpkg 会报 "
            "'end of file during value of field ... (missing final newline)' "
            "并拒绝安装。请在 control 最后一行末尾补一个 '\\n'。")

    # 成对换行（末尾空行）本身不致命，但部分 dpkg 版本对空字段段敏感，
    # 统一收敛成一个换行，保证产物稳定可复现。
    control_bytes = control_bytes.rstrip(b"\n") + b"\n"

    return control_bytes


def validate_control_text(raw):
    """对【已经打进包里的】control 字节做 dpkg 兼容性校验。

    与 make_control 分开的原因：make_control 校验的是源文件，
    这里校验的是产物里的实际字节 —— 两者可能因为打包逻辑的 bug 而不一致。
    验尸必须直接看产物，不能只看源。
    """
    problems = []
    if not raw:
        return ["control 为空"]
    if not raw.endswith(b"\n"):
        problems.append(
            "control 末尾缺少换行 -> dpkg 报 'missing final newline'，装不上")
    if b"\r" in raw:
        problems.append("control 含 CR(\\r)，dpkg 字段解析会错乱")

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        return problems + ["control 不是合法 UTF-8: %s" % e]

    lines = text.splitlines()
    if not lines or not lines[0].strip():
        problems.append("control 首行不能为空（应为 Package: 开头）")

    # 逐行检查字段语法：每行要么是 "Key: value"，要么是续行（以空格/Tab 开头）
    for i, ln in enumerate(lines, 1):
        if not ln.strip():
            problems.append("第 %d 行为空行，字段段中不允许出现空行" % i)
            continue
        if ln[0] in (" ", "\t"):
            continue  # 合法的续行
        if ":" not in ln:
            problems.append("第 %d 行不是 'Key: value' 格式: %r" % (i, ln))
            continue
        key, val = ln.split(":", 1)
        if not key.strip():
            problems.append("第 %d 行字段名为空" % i)
        # dpkg 要求字段名不含空格
        if " " in key.strip():
            problems.append("第 %d 行字段名含空格: %r" % (i, key))
        if not val.startswith(" ") and val.strip():
            problems.append("第 %d 行 %r 冒号后缺空格" % (i, key.strip()))

    return problems


def tar_dir(src_dir, out_path, arc_root=".", exclude_top=()):
    """构建 tar.gz，规范化权限与属主。

    exclude_top: 需要跳过的顶层条目名。用来把 layout/DEBIAN 排除在
    data.tar 之外 —— DEBIAN 下的脚本属于 control.tar，混进 data.tar 会被
    装到设备的 /DEBIAN/ 目录里，既是垃圾也可能被 dpkg 误读。
    """
    # dpkg 会直接 exec control.tar 里的维护脚本，权限必须是 755。
    # 按文件名判定而不是靠 checkout 的权限位：Windows/CI 上权限位不可信。
    script_names = {"postinst", "preinst", "postrm", "prerm", "config", "templates"}

    with tarfile.open(out_path, "w:gz", format=tarfile.GNU_FORMAT) as tar:
        for root, dirs, files in os.walk(src_dir):
            dirs.sort()
            # 根层级过滤：只对 src_dir 直接子项生效，不误伤深层同名目录
            if os.path.abspath(root) == os.path.abspath(src_dir):
                dirs[:] = [d for d in dirs if d not in exclude_top]
                files = [f for f in files if f not in exclude_top]
            for d in dirs:
                full = os.path.join(root, d)
                rel = os.path.relpath(full, src_dir)
                ti = tar.gettarinfo(full, arcname=os.path.join(arc_root, rel))
                ti.uid = 0
                ti.gid = 0
                ti.uname = "root"
                ti.gname = "wheel"
                ti.mode = 0o755
                tar.addfile(ti)
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, src_dir)
                ti = tar.gettarinfo(full, arcname=os.path.join(arc_root, rel))
                ti.uid = 0
                ti.gid = 0
                ti.uname = "root"
                ti.gname = "wheel"
                # 按扩展名/文件名判定，不依赖 os.access（CI 上 check-out 的权限位不可靠）。
                # dylib 必须可读可加载 -> 755；维护脚本必须可 exec -> 755；其余 644。
                if f.endswith(".dylib") or f in script_names:
                    ti.mode = 0o755
                else:
                    ti.mode = 0o644
                with open(full, "rb") as fh:
                    tar.addfile(ti, fh)


def write_ar_member(af, name, data):
    """ar 归档成员。

    格式严格按 System V ar：
      - 60 字节头，name/size/magic 均为 ASCII，末两字节 "`\\n"
      - size 字段必须是【原始】长度，不含补齐字节
      - 数据体后若为奇数长度，补 1 字节 '\\n' 做偶数对齐

    易错点：如果把补齐后的长度写进 size 字段，dpkg 会把补齐的 '\\n'
    当成数据的一部分读入 → 解出的 tar.gz 尾部多一字节 → 解包失败。
    """
    raw_size = len(data)
    header = "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n".format(
        name, "0", "0", "0", "100644", str(raw_size)
    ).encode("ascii")
    assert len(header) == 60, "ar 头长度错误: %d" % len(header)
    af.write(header)
    af.write(data)
    if raw_size % 2 == 1:
        af.write(b"\n")


def build_deb():
    os.makedirs(OUTDEB, exist_ok=True)
    deb_path = os.path.join(OUTDEB, "%s_%s_%s.deb" % (NAME, VERSION, ARCH))

    work = os.path.join(BUILD, "deb_work")
    if os.path.exists(work):
        shutil.rmtree(work)
    ctrl_dir = os.path.join(work, "control")
    os.makedirs(ctrl_dir)

    # control.tar.gz —— 由 control 与 DEBIAN/ 下的维护脚本组成
    with open(os.path.join(ctrl_dir, "control"), "wb") as f:
        f.write(make_control())
    # 维护脚本必须放进 control.tar，且必须是 755（dpkg 直接 exec 它）。
    for script in ("postinst", "preinst", "postrm", "prerm"):
        src = os.path.join(LAYOUT, "DEBIAN", script)
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(ctrl_dir, script))
    ctrl_tar = os.path.join(work, "control.tar.gz")
    tar_dir(ctrl_dir, ctrl_tar)

    # data.tar.gz —— 排除 DEBIAN：那里面的东西属于 control.tar，
    # 混进 data.tar 会被装到设备的 /DEBIAN/ 下，且 dpkg 不会执行它们。
    data_tar = os.path.join(work, "data.tar.gz")
    tar_dir(LAYOUT, data_tar, exclude_top=("DEBIAN",))

    # 组装 ar
    with open(deb_path, "wb") as af:
        af.write(b"!<arch>\n")
        write_ar_member(af, "debian-binary", b"2.0\n")
        with open(ctrl_tar, "rb") as f:
            write_ar_member(af, "control.tar.gz", f.read())
        with open(data_tar, "rb") as f:
            write_ar_member(af, "data.tar.gz", f.read())

    print("[pack] 生成: %s (%d 字节)" % (deb_path, os.path.getsize(deb_path)))
    return deb_path


def parse_ar(path):
    """统一的 ar 解析器，返回 [(name, data), ...]。

    标准 System V ar 成员头固定 60 字节：
        name[0:16] date[16:28] uid[28:34] gid[34:40]
        mode[40:48] size[48:58] magic[58:60]
    数据体后若长度为奇数，补 1 字节 '\\n'。

    这里把解析集中到一处：此前 verify_deb 里写了两个几乎重复的遍历循环，
    两处偏移处理稍有差异就会导致"第一遍成功、第二遍错位"，
    而且报错信息只有一句 ValueError，根本无法定位。集中后只需维护一份。
    """
    members = []
    with open(path, "rb") as f:
        magic = f.read(8)
        if magic != b"!<arch>\n":
            die("不是合法 ar 归档（magic=%r）" % magic)

        while True:
            hdr = f.read(60)
            if len(hdr) == 0:
                break
            if len(hdr) != 60:
                die("ar 头部长度异常：期望 60，实际 %d（文件可能被截断）" % len(hdr))
            if hdr[58:60] != b"`\n":
                die("ar 头部 magic 异常：%r\n"
                    "  完整头部 hex: %s\n"
                    "  说明偏移与标准不符，不能再按固定位置截取字段。"
                    % (hdr[58:60], hdr.hex()))

            name = hdr[0:16].decode("ascii", "replace").rstrip()
            # 去掉 GNU ar 的尾随 '/'（部分实现会加）
            if name.endswith("/"):
                name = name[:-1]

            size_field = hdr[48:58].decode("ascii", "replace").strip()
            try:
                size = int(size_field)
            except ValueError:
                die("ar 头部 size 字段无法解析：%r\n"
                    "  完整头部 hex: %s\n"
                    "  size 字段原始 bytes: %r"
                    % (size_field, hdr.hex(), hdr[48:58]))

            data = f.read(size)
            if len(data) != size:
                die("成员 %s 数据被截断：期望 %d，实际 %d" %
                    (name, size, len(data)))
            if size % 2 == 1:
                f.read(1)  # 奇数补齐
            members.append((name, data))
    return members


def verify_deb(deb_path):
    """回读校验：ar 结构 + 必须存在的文件。"""
    members = parse_ar(deb_path)
    names = [n for n, _ in members]
    print("[pack] ar 成员: " + ", ".join(names))

    for need in ("debian-binary", "control.tar.gz", "data.tar.gz"):
        if need not in names:
            die("deb 缺少成员: " + need)

    # ---- control 语法校验（对产物里的真实字节）----
    # 这一项曾完全缺失：所有检查都是"内容包含"式，
    # 没有一个在检查 control 是否符合 dpkg 的解析要求。
    # 结果末尾缺换行的包一路通过所有检查，装到设备才被 dpkg 拒绝。
    ctrl_blob = dict(members)["control.tar.gz"]
    tmpc = os.path.join(BUILD, "_verify_control.tar.gz")
    os.makedirs(BUILD, exist_ok=True)
    with open(tmpc, "wb") as g:
        g.write(ctrl_blob)
    try:
        with tarfile.open(tmpc, "r:gz") as tar:
            cnames = [n for n in tar.getnames() if n.rstrip("/").endswith("control")]
            if not cnames:
                die("control.tar.gz 里找不到 control 文件")
            raw_ctrl = tar.extractfile(cnames[0]).read()
    finally:
        if os.path.exists(tmpc):
            os.remove(tmpc)

    problems = validate_control_text(raw_ctrl)
    if problems:
        die("control 语法不合格，dpkg 会拒绝安装：\n  - " + "\n  - ".join(problems))
    print("[pack] control 语法校验 OK（%d 字节，末尾换行正确）" % len(raw_ctrl))

    # 校验 data.tar.gz 的文件清单
    data_blob = dict(members)["data.tar.gz"]
    tmp = os.path.join(BUILD, "_verify_data.tar.gz")
    os.makedirs(BUILD, exist_ok=True)
    with open(tmp, "wb") as g:
        g.write(data_blob)
    try:
        with tarfile.open(tmp, "r:gz") as tar:
            got = tar.getnames()
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    must = [
        "./Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.dylib",
        "./Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.plist",
    ]
    for m in must:
        if m not in got:
            die("data 内缺少必需文件: " + m + "\n实际清单:\n  " + "\n  ".join(got))

    # ★ data.tar 不得携带 /var/ 条目，也不得带 DEBIAN/。
    # 这是真实事故：把 /var/mobile/Library/Logs/ShortcutsLagFix 放进 data.tar 后，
    # dpkg 以 root:wheel 755 创建它，App(mobile) 写不进去，
    # 表现是「日志目录存在但一条日志都没有」，看起来像插件没加载。
    bad = [n for n in got if n.startswith("./var") or "/DEBIAN" in n or n.startswith("./DEBIAN")]
    if bad:
        die("data.tar 含禁止的条目（属主会是 root，App 无法写；或维护脚本混入 data）：\n  "
            + "\n  ".join(bad))
    print("[pack] data 清单校验 OK (%d 项，无 /var 条目)" % len(got))

    # ★ control.tar 必须带可执行的 postinst（它负责把 /var/mobile 下的目录
    # 建好并 chown 给 mobile）。少了它，日志目录的权限问题会再次出现。
    with open(tmpc2 := os.path.join(BUILD, "_verify_control.tar.gz"), "wb") as g:
        g.write(ctrl_blob)
    try:
        with tarfile.open(tmpc2, "r:gz") as tar:
            cm = {m.name.lstrip("./"): m for m in tar.getmembers()}
            if "postinst" not in cm:
                die("control.tar.gz 里缺少 postinst，安装后无人创建/chown 日志目录")
            mode = cm["postinst"].mode & 0o777
            if mode != 0o755:
                die("postinst 权限为 %o，dpkg 需要 755 才能执行" % mode)
            body = tar.extractfile(cm["postinst"]).read()
            if b"chown" not in body:
                die("postinst 里没有 chown，日志目录仍会归 root，App 写不进去")
            if not body.endswith(b"\n"):
                die("postinst 末尾缺少换行")
    finally:
        if os.path.exists(tmpc2):
            os.remove(tmpc2)
    print("[pack] control.tar 含 postinst(755) 且已 chown mobile，OK")

    with open(deb_path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    print("[pack] sha256: " + sha)


def main():
    check_dylib()
    check_layout()
    deb = build_deb()
    verify_deb(deb)
    print("[pack] 全部校验通过，可交付。")


if __name__ == "__main__":
    main()