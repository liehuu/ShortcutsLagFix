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
VERSION = "1.0.0"
ARCH = "iphoneos-arm64"

DYLIB = os.path.join(BUILD, "ShortcutsLagFix.dylib")


def die(msg):
    print("[pack][FATAL] " + msg, file=sys.stderr)
    sys.exit(1)


def check_dylib():
    if not os.path.exists(DYLIB):
        die("dylib 不存在，先跑 build.sh: %s" % DYLIB)

    # macOS 上用 lipo 验证；本地 Windows 无 lipo 时退化为解析 Mach-O 头
    try:
        info = subprocess.run(["lipo", "-info", DYLIB],
                              capture_output=True, text=True)
        if info.returncode == 0:
            print("[pack] lipo -info: " + info.stdout.strip())
            if "arm64" not in info.stdout or "arm64e" not in info.stdout:
                die("dylib 不是 arm64+arm64e 双切片，在 arm64e 设备上会静默失效")
    except FileNotFoundError:
        print("[pack] 无 lipo，改用 Mach-O 头解析")
        with open(DYLIB, "rb") as f:
            magic = f.read(4)
        if magic != b"\xca\xfe\xba\xbe":
            die("dylib 不是 FAT 二进制（magic=%r）" % magic)
        print("[pack] FAT magic OK")

    # adhoc 签名检查（arm64e 上 RootHide 加载器会跳过无签名 dylib）
    try:
        dv = subprocess.run(["codesign", "-dv", DYLIB],
                            capture_output=True, text=True)
        combined = (dv.stdout or "") + (dv.stderr or "")
        if "Signature=adhoc" in combined or "Signature=Ad Hoc" in combined:
            print("[pack] adhoc 签名 OK")
        else:
            die("dylib 未 adhoc 签名，RootHide 加载器会跳过它")
    except FileNotFoundError:
        print("[pack] 无 codesign，跳过签名校验（由 CI 保证）")


def check_layout():
    dl = os.path.join(LAYOUT, "Library/MobileSubstrate/DynamicLibraries")
    pl = os.path.join(dl, "ShortcutsLagFix.plist")
    cfg = os.path.join(LAYOUT, "var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist")

    if not os.path.exists(pl):
        die("缺少注入过滤 plist: " + pl)
    with open(pl, "r", encoding="utf-8") as f:
        content = f.read()
    if "com.apple.shortcuts" not in content and "is.workflow.my.app" not in content:
        die("过滤 plist 不含目标 bundle id，插件永不会被加载")

    if not os.path.exists(cfg):
        die("缺少预置配置文件: " + cfg)

    if not os.path.exists(os.path.join(dl, "ShortcutsLagFix.dylib")):
        die("layout 里没有 dylib，先跑 build.sh")

    print("[pack] layout 校验 OK")


def make_control():
    control = """Package: {pkg}
Name: ShortcutsLagFix
Version: {ver}
Architecture: {arch}
Description: Diagnose and mitigate UI stalls when creating a new Shortcut (iOS 17). A main-thread watchdog captures the blocking stack, so the actual cause is identified from logs instead of guessed. All hooks use public UIKit APIs only. Config: /var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist
Maintainer: liehuu
Author: liehuu
Section: Tweaks
Depends: mobilesubstrate
""".format(pkg=PKG, ver=VERSION, arch=ARCH)
    return control.encode("utf-8")


def tar_dir(src_dir, out_path, arc_root="."):
    """构建 tar.gz，规范化权限与属主。"""
    with tarfile.open(out_path, "w:gz", format=tarfile.GNU_FORMAT) as tar:
        for root, dirs, files in os.walk(src_dir):
            dirs.sort()
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
                # 按扩展名判定，不依赖 os.access（CI 上 check-out 的权限位不可靠）。
                # dylib 必须可读可加载 -> 755；其余配置文件 644。
                ti.mode = 0o755 if f.endswith(".dylib") else 0o644
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

    # control.tar.gz
    with open(os.path.join(ctrl_dir, "control"), "wb") as f:
        f.write(make_control())
    ctrl_tar = os.path.join(work, "control.tar.gz")
    tar_dir(ctrl_dir, ctrl_tar)

    # data.tar.gz
    data_tar = os.path.join(work, "data.tar.gz")
    tar_dir(LAYOUT, data_tar)

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
        "./var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist",
    ]
    for m in must:
        if m not in got:
            die("data 内缺少必需文件: " + m + "\n实际清单:\n  " + "\n  ".join(got))
    print("[pack] data 清单校验 OK (%d 项)" % len(got))

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