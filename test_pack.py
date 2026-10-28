#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack.py 的离线逻辑测试。

本机没有 macOS（无 lipo/codesign/clang），无法真实编译。
但 deb 的 ar 封装与校验逻辑是纯 Python，可以完整验证：
用伪造的 dylib 占位文件跑通 ar 组装 → 回读 → tar 清单校验。

测试目标：
  1. ar 头 60 字节、size 为原始长度、奇数补 '\\n' 对齐
  2. 回读能正确解析成员并解出 data.tar.gz
  3. data.tar.gz 内文件清单与权限符合 dpkg 预期
  4. 缺失关键文件时必须报错退出（硬闸门有效性）
"""

import os
import sys
import tarfile
import struct
import shutil
import importlib.util

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pack", os.path.join(ROOT, "pack.py"))
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


def parse_ar(path):
    """独立实现的 ar 解析，用于交叉验证 pack.py 的写入逻辑。"""
    out = []
    with open(path, "rb") as f:
        assert f.read(8) == b"!<arch>\n", "bad ar magic"
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            if len(hdr) != 60:
                raise AssertionError("ar header 长度不是 60")
            if hdr[58:60] != b"`\n":
                raise AssertionError("ar header magic 错误: %r" % hdr[58:60])
            name = hdr[0:16].decode("ascii").strip()
            size = int(hdr[48:58].decode("ascii").strip())
            data = f.read(size)
            if len(data) != size:
                raise AssertionError("成员 %s 数据长度不足: %d != %d" %
                                     (name, len(data), size))
            if size % 2 == 1:
                pad = f.read(1)
                assert pad == b"\n", "奇数长度补齐字节不是 \\n"
            out.append((name, data))
    return out


def main():
    # ★ 关键：把 pack 的工作目录全部重定向到临时目录。
    # 早期版本直接改写真实 layout/ 与 build/，第 8 步为了验证"缺文件必须拦截"
    # 会删掉 layout 里的配置文件 —— 结果把真实交付文件一起删了，
    # 导致随后提交推送的仓库缺少预置 plist，CI 报 "缺少预置配置文件"。
    # 测试必须与生产文件隔离：这是原则，不是可选项。
    import tempfile
    tmp = tempfile.mkdtemp(prefix="slf_test_")
    pack.BUILD = os.path.join(tmp, "build")
    pack.LAYOUT = os.path.join(tmp, "layout")
    pack.OUTDEB = os.path.join(tmp, "debs")
    pack.DYLIB = os.path.join(pack.BUILD, "ShortcutsLagFix.dylib")
    for d in (pack.BUILD, pack.LAYOUT, pack.OUTDEB):
        os.makedirs(d, exist_ok=True)

    print("=== 1. 构造伪造 dylib（临时目录 %s）===" % tmp)
    # 必须构造一个合法的 FAT 头，且同时含 arm64 与 arm64e 两个切片，
    # 否则会被 pack.check_dylib 的架构闸门拦下（这是正确的拦截）。
    # arm64e 的 subtype 用真实值 0x80000002，顺带验证掩码判定逻辑。
    body = b"FAKE_DYLIB_FOR_PACK_TEST" * 10 + b"\x01"  # 奇数长度，验证 ar 补齐
    fat_hdr = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
    off1 = 0x1000
    off2 = off1 + len(body)
    fat_hdr += struct.pack(">IIIII", 0x0100000C, 0, off1, len(body), 0)
    fat_hdr += struct.pack(">IIIII", 0x0100000C, 0x80000002, off2, len(body), 0)
    fake = fat_hdr + b"\x00" * (off1 - len(fat_hdr)) + body + body
    with open(pack.DYLIB, "wb") as f:
        f.write(fake)
    print("    dylib %d bytes，含 arm64 + arm64e 双切片" % len(fake))

    # 覆盖 check_dylib（本机无 lipo/codesign）
    pack.check_dylib = lambda: None

    print("=== 2. 布置 layout ===")
    dl = os.path.join(pack.LAYOUT, "Library/MobileSubstrate/DynamicLibraries")
    os.makedirs(dl, exist_ok=True)
    shutil.copy(pack.DYLIB, os.path.join(dl, "ShortcutsLagFix.dylib"))
    with open(os.path.join(dl, "ShortcutsLagFix.plist"), "w") as f:
        f.write("<plist><dict><key>Filter</key><dict><key>Bundles</key>"
                "<array><string>com.apple.shortcuts</string></array>"
                "</dict></dict></plist>")
    pref = os.path.join(pack.LAYOUT, "var/mobile/Library/Preferences")
    os.makedirs(pref, exist_ok=True)
    with open(os.path.join(pref, "com.liehuu.shortcutslagfix.plist"), "w") as f:
        f.write("<plist><dict><key>DebugLog</key><true/></dict></plist>")
    print("    layout OK")

    print("=== 3. 打包 ===")
    deb = pack.build_deb()

    print("=== 4. 独立解析 ar 交叉验证 ===")
    members = parse_ar(deb)
    names = [m[0] for m in members]
    print("    成员: %s" % names)
    assert names == ["debian-binary", "control.tar.gz", "data.tar.gz"], names
    assert members[0][1] == b"2.0\n", repr(members[0][1])
    print("    debian-binary 内容 OK: %r" % members[0][1])

    print("=== 5. 校验 control.tar.gz 可解 ===")
    ctrl_path = os.path.join(pack.BUILD, "_t_control.tar.gz")
    with open(ctrl_path, "wb") as f:
        f.write(members[1][1])
    with tarfile.open(ctrl_path, "r:gz") as t:
        cn = t.getnames()
        print("    control 内: %s" % cn)
        assert any(n.endswith("control") for n in cn), cn
        ctrl_txt = t.extractfile([n for n in cn if n.endswith("control")][0]).read().decode()
    os.remove(ctrl_path)
    # ★ 用 pack 的常量断言，不再硬编码 "iphoneos-arm64" / "1.0.0"。
    # 硬编码的后果：架构值从 iphoneos-arm64 改成 iphoneos-arm64e 时，
    # 这个测试会因"找不到 'Architecture: iphoneos-arm64'"而失败 ——
    # 看起来很"严格"，实际是测试写错了，反而会诱导人去改回错误的值。
    for key in ("Package: %s" % pack.PKG,
                "Architecture: %s" % pack.ARCH,
                "Version: %s" % pack.VERSION):
        # Architecture 必须整行匹配：子串匹配时 "iphoneos-arm64"
        # 会被 "iphoneos-arm64e" 命中，等于永远通过。
        if key.startswith("Architecture:"):
            lines = [l.strip() for l in ctrl_txt.splitlines()]
            assert key in lines, "control Architecture 行不等于 %r\n实际: %r" % (
                key, [l for l in lines if l.lower().startswith("architecture")])
        else:
            assert key in ctrl_txt, "control 缺少: " + key
    print("    control 内容 OK (Architecture=%s)" % pack.ARCH)

    print("=== 5b. 回归：control 架构写错时必须被拦截 ===")
    # 复刻本次真实事故：control 写成 rootless 的 iphoneos-arm64。
    # 这个断言同时证明"闸门真的会响"，而不是摆设。
    _real_root = pack.ROOT
    try:
        wrong_root = os.path.join(tmp, "wrongctrl")
        os.makedirs(wrong_root, exist_ok=True)
        with open(os.path.join(_real_root, "control"), "r", encoding="utf-8") as f:
            real_ctrl = f.read()
        with open(os.path.join(wrong_root, "control"), "w", encoding="utf-8") as f:
            f.write(real_ctrl.replace("Architecture: " + pack.ARCH,
                                      "Architecture: iphoneos-arm64"))
        pack.ROOT = wrong_root
        try:
            pack.make_control()
        except SystemExit:
            print("    架构写错 -> 已拦截 OK")
        else:
            raise AssertionError(
                "control 写成 iphoneos-arm64 却未报错，闸门失效！"
                "这正是导致 Sileo 拒绝安装 'update it for roothide' 的根因")
    finally:
        pack.ROOT = _real_root

    print("=== 5c. 回归：control 末尾缺换行时必须被拦截 ===")
    # 复刻第二次真实事故（用户设备上的 dpkg 报错原文）：
    #   parsing file '.../control' near line 8 package 'com.liehuu.shortcutslagfix':
    #   end of file during value of field 'Depends' (missing final newline)
    #
    # 上一版之所以没被拦住，是因为所有检查都用 ctrl.strip() 后的文本，
    # strip 恰好把"缺失的换行"这个事实抹掉了 —— 检查方式本身掩盖了缺陷。
    # 因此这里直接对【原始字节】断言。
    try:
        with open(os.path.join(_real_root, "control"), "r", encoding="utf-8") as f:
            no_eol = f.read().rstrip("\n")
        no_eol_root = os.path.join(tmp, "noeol")
        os.makedirs(no_eol_root, exist_ok=True)
        with open(os.path.join(no_eol_root, "control"), "w", encoding="utf-8") as f:
            f.write(no_eol)
        pack.ROOT = no_eol_root
        try:
            pack.make_control()
        except SystemExit:
            print("    末尾缺换行 -> 已拦截 OK")
        else:
            raise AssertionError(
                "control 末尾缺换行却未报错，闸门失效！dpkg 会拒绝安装："
                "end of file during value of field 'Depends'")
    finally:
        pack.ROOT = _real_root

    print("=== 5d. validate_control_text 双向验证 ===")
    good = open(os.path.join(_real_root, "control"), "rb").read()
    assert not pack.validate_control_text(good), \
        "合法的 control 被判为不合格: %r" % pack.validate_control_text(good)
    print("    合法 control -> 无告警 OK")

    # 逐个注入缺陷，必须每个都被识别
    cases = [
        ("缺末尾换行", good.rstrip(b"\n"), "missing final newline"),
        ("含 CR",      good.replace(b"\n", b"\r\n"), "CR"),
        ("空行",       good.replace(b"\n", b"\n\n", 1), "空行"),
        ("冒号后无空格", good.replace(b"Section: Tweaks", b"Section:Tweaks"), "缺空格"),
    ]
    for label, blob, expect_kw in cases:
        probs = pack.validate_control_text(blob)
        assert probs, "缺陷[%s]未被识别，校验失效" % label
        assert any(expect_kw in p for p in probs), \
            "缺陷[%s]报错信息未提及 %r，实际: %r" % (label, expect_kw, probs)
        print("    %s -> 已识别 OK" % label)

    print("=== 6. 校验 data.tar.gz 清单与权限 ===")
    data_path = os.path.join(pack.BUILD, "_t_data.tar.gz")
    with open(data_path, "wb") as f:
        f.write(members[2][1])
    with tarfile.open(data_path, "r:gz") as t:
        infos = t.getmembers()
        found = {}
        for m in infos:
            found[m.name] = m
        need = [
            "./Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.dylib",
            "./Library/MobileSubstrate/DynamicLibraries/ShortcutsLagFix.plist",
            "./var/mobile/Library/Preferences/com.liehuu.shortcutslagfix.plist",
        ]
        for n in need:
            assert n in found, "data 缺少 %s\n实际: %s" % (n, list(found))
        dyl = found[need[0]]
        cfg = found[need[2]]
        assert dyl.mode == 0o755, "dylib 权限应为 755，实际 %o" % dyl.mode
        assert cfg.mode == 0o644, "配置权限应为 644，实际 %o" % cfg.mode
        assert dyl.uid == 0 and dyl.uname == "root", "属主应为 root"
        print("    dylib: mode=%o uid=%d" % (dyl.mode, dyl.uid))
        print("    config: mode=%o" % cfg.mode)

    # 内嵌 dylib 必须与源文件逐字节一致
    with tarfile.open(data_path, "r:gz") as t:
        embedded = t.extractfile(need[0]).read()
    assert embedded == fake, "内嵌 dylib 内容与源不一致"
    print("    内嵌 dylib 字节一致 OK (%d bytes)" % len(embedded))
    os.remove(data_path)

    print("=== 7. 校验 verify_deb 自身能通过 ===")
    pack.verify_deb(deb)
    print("    verify_deb 通过")

    print("=== 8. 硬闸门：缺失 plist 时必须失败 ===")
    os.remove(os.path.join(pref, "com.liehuu.shortcutslagfix.plist"))
    try:
        pack.check_layout()
        print("    [FAIL] 缺配置未报错，闸门失效")
        return 1
    except SystemExit as e:
        print("    正确拦截（exit %s）" % e.code)

    # 清理测试产物（只清临时目录，绝不碰真实 layout/）
    if os.path.exists(deb):
        os.remove(deb)
    shutil.rmtree(tmp, ignore_errors=True)
    print("\n=== 全部通过 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())