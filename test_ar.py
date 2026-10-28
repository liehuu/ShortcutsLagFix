#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ar 解析器的边界测试。

背景（2026-10-28 真实 CI 失败）：
verify_deb 里原本有两个几乎重复的遍历循环，第二个循环在跳过奇数补齐时
写成了"先 f.read(1) 跳过补齐，循环末尾又 f.seek(size % 2) 再跳一次"，
导致 size 为奇数时偏移多走 1 字节 → 下一个头部整体错位 →
hdr[48:58] 取到 '60       `' 这种垃圾 → ValueError。

本地测试的 tar.gz 长度恰好都是偶数，所以完全掩盖了这个 bug；
CI 上长度是奇数，立刻暴露。教训：边界值必须显式构造，不能靠运气。

本测试显式构造奇数/偶数长度的成员来覆盖两种情况。
"""

import os
import sys
import struct
import importlib.util

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pack", os.path.join(ROOT, "pack.py"))
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


def build_ar(path, members):
    """按标准 System V ar 写归档。members = [(name, data), ...]"""
    with open(path, "wb") as f:
        f.write(b"!<arch>\n")
        for name, data in members:
            raw = len(data)
            hdr = "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n".format(
                name, "0", "0", "0", "100644", str(raw)
            ).encode("ascii")
            assert len(hdr) == 60
            f.write(hdr)
            f.write(data)
            if raw % 2 == 1:
                f.write(b"\n")


def case(label, sizes):
    print("\n--- %s ---" % label)
    path = os.path.join(ROOT, "_ar_test_%s.deb" % label)
    members = []
    for i, sz in enumerate(sizes):
        members.append(("m%d.dat" % i, bytes([65 + i]) * sz))
    build_ar(path, members)

    try:
        got = pack.parse_ar(path)
    except SystemExit as e:
        print("  [FAIL] parse_ar 退出 code=%s" % e.code)
        os.remove(path)
        return False

    ok = True
    for (n_in, d_in), (n_out, d_out) in zip(members, got):
        match = (n_in == n_out and d_in == d_out)
        print("  %-10s size=%-5d -> %-10s size=%-5d  %s" %
              (n_in, len(d_in), n_out, len(d_out), "OK" if match else "MISMATCH"))
        if not match:
            ok = False

    if len(got) != len(members):
        print("  [FAIL] 成员数不符: 期望 %d 实际 %d" % (len(members), len(got)))
        ok = False
    os.remove(path)
    return ok


def main():
    results = {}

    # 关键：必须覆盖奇数长度，这正是此前漏掉的情况
    results["全偶数"] = case("even", [4, 100, 200])
    results["全奇数"] = case("odd", [3, 101, 201])
    results["奇偶混合"] = case("mixed", [4, 451, 366, 7, 1, 0])
    results["单字节"] = case("single", [1])
    results["零长度"] = case("zero", [0, 0])
    results["奇数在末位"] = case("odd_last", [100, 101])
    results["奇数在首位"] = case("odd_first", [101, 100])

    print("\n" + "=" * 50)
    all_ok = True
    for k, v in results.items():
        print("  %-12s %s" % (k, "PASS" if v else "FAIL"))
        if not v:
            all_ok = False

    if all_ok:
        print("\n全部通过：奇偶长度下 ar 解析均正确")
        return 0
    print("\n存在失败用例")
    return 1


if __name__ == "__main__":
    sys.exit(main())