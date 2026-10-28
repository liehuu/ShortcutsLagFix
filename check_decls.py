#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
声明一致性检查（lint.py 的补充）。

lint.py 的 [3] 项只做"形似声明"的宽松匹配，误报很多。
本脚本做严格交叉验证：
  - 头文件里有原型的 SLF* 函数
  - 各 .m 内 static 定义的 SLF* 函数
  - 所有调用点必须落在上面两类之一
并额外检查：
  - 调用的实参个数与原型是否匹配（最容易被漏掉的一类错误）
"""

import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "ShortcutsLagFix")


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r"//[^\n]*", "", t)
    return t


def main():
    hdr_path = os.path.join(SRC, "SLFCommon.h")
    hdr = strip_comments(open(hdr_path, encoding="utf-8").read())

    # 原型: ret_type NAME(args)
    # 注意 "*" 后面可能直接跟函数名（NSString *SLFJBPath），也可能有空格，
    # 所以用 \s*\*?\s* 而不是要求固定空格。
    protos = {}
    for m in re.finditer(
            r"^(?:extern\s+)?(void|BOOL|NSInteger|uint64_t|NSString)\s*\*?\s*"
            r"(SLF\w+)\s*\(([^;{]*)\)\s*;", hdr, re.M):
        ret, name, args = m.group(1), m.group(2), m.group(3)
        nargs = 0 if args.strip() in ("", "void") else len(
            [a for a in split_args(args)])
        protos[name] = (ret.strip(), nargs)

    # static 定义
    defined = {}
    ret_types = r"void|BOOL|NSInteger|uint64_t|NSString|IMP|dispatch_source_t"
    for f in sorted(glob.glob(os.path.join(SRC, "*.m"))):
        body = strip_comments(open(f, encoding="utf-8").read())
        for m in re.finditer(
                r"^static\s+(?:__attribute__\S+\s+)?"
                r"(%s)\s*\*?\s*(SLF\w+)\s*\(([^;{]*)\)\s*\{" % ret_types,
                body, re.M):
            ret, name, args = m.group(1), m.group(2), m.group(3)
            nargs = 0 if args.strip() in ("", "void") else len(
                [a for a in split_args(args)])
            defined[name] = (os.path.basename(f), ret.strip(), nargs)

    print("头文件原型 (%d):" % len(protos))
    for k in sorted(protos):
        print("  %-24s ret=%-10s nargs=%d" % (k, protos[k][0], protos[k][1]))

    print("\nstatic 定义 (%d):" % len(defined))
    for k in sorted(defined):
        print("  %-24s %-16s ret=%-10s nargs=%d" %
              (k, defined[k][0], defined[k][1], defined[k][2]))

    errors = []

    # 收集宏名（#define SLFGetPC(...) 这类是宏，不是函数，调用时不应报未声明）
    macros = set()
    for f in sorted(glob.glob(os.path.join(SRC, "*.m")) +
                    [os.path.join(SRC, "SLFCommon.h")]):
        body = strip_comments(open(f, encoding="utf-8").read())
        for m in re.finditer(r"#\s*define\s+(SLF\w+)\s*\(", body):
            macros.add(m.group(1))
        # .m 内的前置声明也算已声明（C 要求先声明后使用）
        for m in re.finditer(
                r"^(?:extern\s+)?(void|BOOL|NSInteger|uint64_t|NSString)\s*\*?\s*"
                r"(SLF\w+)\s*\(([^;{]*)\)\s*;", body, re.M):
            name, args = m.group(2), m.group(3)
            if name not in protos:
                nargs = 0 if args.strip() in ("", "void") else len(split_args(args))
                protos[name] = (m.group(1), nargs)

    # 检查调用实参个数
    for f in sorted(glob.glob(os.path.join(SRC, "*.m"))):
        body = strip_comments(open(f, encoding="utf-8").read())
        lines = body.split("\n")
        for i, ln in enumerate(lines, 1):
            if "SLFLog" in ln:
                continue  # 变参，跳过
            for m in re.finditer(r"\b(SLF[A-Z]\w+)\s*\(([^;]*?)\)\s*[;{)]", ln):
                name, args = m.group(1), m.group(2)
                if name in macros:
                    continue
                spec = protos.get(name) or (
                    (defined[name][1], defined[name][2]) if name in defined else None)
                if spec is None:
                    # 定义行自身
                    if re.search(r"\b%s\s*\([^;]*\)\s*\{" % re.escape(name), ln):
                        continue
                    errors.append("%s:%d 未声明的函数 %s" %
                                  (os.path.basename(f), i, name))
                    continue
                want = spec[1]
                got = 0 if args.strip() in ("", "void") else len(split_args(args))
                if want != got:
                    errors.append("%s:%d %s 实参 %d 个，原型 %d 个: %s" %
                                  (os.path.basename(f), i, name, got, want,
                                   args.strip()[:60]))

    if errors:
        print("\n[ERROR]")
        for e in errors:
            print("  " + e)
        return 1

    print("\nOK: 声明与调用一致")
    return 0


def split_args(s):
    """按顶层逗号切分参数列表。"""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{<":
            depth += 1
        elif ch in ")]}>":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


if __name__ == "__main__":
    sys.exit(main())