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
    #
    # ret_types 必须覆盖项目里实际用到的所有返回类型。
    # 漏一个的后果不是"漏报"，而是**误报**：定义没被收录 → 调用点被判成
    # "未声明的函数"，于是一堆假错误把所有真问题淹没。
    # 实测：这里原先没有 "const char"，SLFImageNameAndOffset 因此被误报 3 次。
    # 后来又漏了 "int"（SLFMainThreadRunState 返回 int），同样被误报。
    # 规律很清楚：**每新增一个返回类型，就必须同步这张表**，
    # 否则检查器会开始骗人 —— 它报的不是代码的问题，是自己的见识不够。
    ret_types = (r"void|BOOL|int|NSInteger|uint64_t|NSString|IMP|dispatch_source_t"
                 r"|dispatch_queue_t|const\s+char")
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
    """按顶层逗号切分参数列表。

    ★ 只把 ()[]{} 当作成对括号，**不要**把 <> 也算进去。
      实测教训：原实现把 '<' '>' 当括号，而 C/ObjC 的箭头操作符 -> 里的 '>'
      会让深度变成负数，此后所有逗号都被判为"在括号内"而不切分 ——
      SLFImageNameAndOffset(st->addrs[i], &off, &sym) 于是被数成 1 个实参，
      和原型 3 个不符，报出一条假错误。
      ObjC 里尖括号只用于泛型/协议限定，成对出现，不影响顶层逗号的切分。
    """
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
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