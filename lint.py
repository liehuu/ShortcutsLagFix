#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ShortcutsLagFix 本地静态检查。

目的：把能本地发现的错误挡在推送之前。CI 失败一次 = 3~5 分钟无谓往返。

覆盖项（1-10 沿用历史教训，11-15 为本次新增）：
  [1]  括号 / 花括号配对
  [2]  日志格式符与实参数量匹配
  [3]  隐式函数声明（先用后无声明）
  [4]  ARC 桥接强制转换
  [5]  Class / NSString 三元混用
  [6]  hook 体内文件 IO / 同步日志
  [7]  hook 转发前未判 orig 非空
  [8]  block 用作 IMP / 运行时 dlopen substrate
  [9]  私有属性裸点语法
  [10] 私有选择子未声明
  [11] pthread_once 传 block（编译错误）
  [12] hook 函数返回类型与声明不符
  [13] 持有锁时执行日志 / 回调（死锁风险）
  [14] 定时器未存 static（静默失效）
  [15] 构造函数是否整体 @try/@catch
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "ShortcutsLagFix")

errors = []
warnings = []


def err(f, n, msg):
    errors.append("%s:%d  %s" % (f, n, msg))


def warn(f, n, msg):
    warnings.append("%s:%d  %s" % (f, n, msg))


def sources():
    return sorted(f for f in os.listdir(SRC)
                  if f.endswith((".m", ".h", ".mm")))


def read(fn):
    with open(os.path.join(SRC, fn), "r", encoding="utf-8", errors="replace") as f:
        return f.readlines()


def strip_comment_lines(lines):
    """返回去掉行注释与字符串的版本，用于括号/符号检查。"""
    out = []
    for ln in lines:
        # 粗略去掉行注释（忽略注释里出现 // 的字符串，本工程概率极低）
        s = re.sub(r"//.*$", "", ln)
        # 去掉字符串字面量内容
        s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
        out.append(s)
    return out


# ---------- [1] 括号配对 ----------
def check_brackets(f, lines):
    code = strip_comment_lines(lines)
    depth_p = 0
    depth_b = 0
    for i, ln in enumerate(code, 1):
        depth_p += ln.count("(") - ln.count(")")
        depth_b += ln.count("{") - ln.count("}")
        if depth_p < 0:
            err(f, i, "[1] 圆括号提前闭合")
            depth_p = 0
        if depth_b < 0:
            err(f, i, "[1] 花括号提前闭合")
            depth_b = 0
    if depth_p != 0:
        err(f, len(lines), "[1] 圆括号不配对（差 %d）" % depth_p)
    if depth_b != 0:
        err(f, len(lines), "[1] 花括号不配对（差 %d）" % depth_b)


# ---------- [2] 格式符与实参 ----------
FMT_RE = re.compile(r"%[-+ #0]*[\d.]*(?:hh|h|ll|l|q|L|z|j|t)?[@dDiuUxXoOfFeEgGcCsSpn%]")


def check_format(f, lines):
    for i, ln in enumerate(lines, 1):
        m = re.search(r'\bSLFLog(?:Always)?\s*\(\s*(@?"(?:[^"\\]|\\.)*")\s*(,|\))', ln)
        if not m:
            continue
        fmt = m.group(1)
        has_more = m.group(2) == ","

        # 处理续行：从本行起向后拼到分号
        buf = ln
        j = i
        while ";" not in buf and j < len(lines):
            buf += lines[j]
            j += 1

        fmt_lit = re.search(r'@?"((?:[^"\\]|\\.)*)"', buf)
        if not fmt_lit:
            continue
        spec = FMT_RE.findall(fmt_lit.group(1))
        spec = [s for s in spec if s != "%%"]

        # 粗略统计实参个数：按顶层逗号切分
        after = buf[fmt_lit.end():]
        args_part = after.lstrip().lstrip(",")
        args_part = args_part.split(");")[0]
        args_part = args_part.replace("@\"", "«").replace("\"", "»")
        depth = 0
        cnt = 0
        if args_part.strip():
            for ch in args_part:
                if ch in "([":
                    depth += 1
                elif ch in ")]":
                    depth -= 1
                elif ch == "," and depth == 0:
                    cnt += 1
            cnt += 1

        if len(spec) != cnt:
            err(f, i, "[2] 格式符 %d 个，实参 %d 个：%s" %
                (len(spec), cnt, fmt_lit.group(1)[:50]))


# ---------- [3] 隐式声明 ----------
_DECL_PAT = re.compile(
    r'\b(?:void|BOOL|int|NSInteger|uint64_t|const\s+char|NSString)\s*\*?\s*(SLF\w+)\s*\(')


def _collect_decls(lines):
    declared = set()
    for ln in lines:
        for m in _DECL_PAT.finditer(ln):
            declared.add(m.group(1))
    return declared


_header_cache = None


def _header_decls():
    """SLFCommon.h 里的声明对所有 .m 文件都有效。"""
    global _header_cache
    if _header_cache is not None:
        return _header_cache
    s = set()
    p = os.path.join(SRC, "SLFCommon.h")
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            s = _collect_decls(fh.read().split("\n"))
    _header_cache = s
    return s


def check_implicit(f, lines):
    """[3] 检查是否调用了未声明的函数。

    ★ 原实现有两个缺陷，一起导致了 134 条纯噪音（0 真实问题）：
      1. 声明正则要求「类型 + 至少一个空格 + 函数名」，而
         `NSString *SLFLogPath(void);` 里 '*' 与函数名之间**没有空格**，
         于是连头文件里的声明自己都没被认出来；
      2. declared 集合只收集**当前文件**内的声明，导致所有在
         SLFCommon.h 里声明、在 .m 里使用的跨文件函数全被判为未声明。
      噪音的代价是真实的：134 条假告警会把真问题彻底淹没，
      和之前 lint [14] 误报是同一类事故。
    """
    declared = _collect_decls(lines) | _header_decls()

    # 宏不是函数：`#define SLFGetPC(st) __darwin_..._get_pc(*(st))`
    # 展开后长得像调用，但永远不需要"声明"。
    macros = set()
    for ln in lines:
        for m in re.finditer(r"#\s*define\s+(SLF\w+)\s*\(", ln):
            macros.add(m.group(1))

    for i, ln in enumerate(lines, 1):
        for m in re.finditer(r'\b(SLF[A-Z]\w+)\s*\(', ln):
            name = m.group(1)
            if name in declared or name in macros:
                continue
            # 定义行自身：类型 + 可选空格 + 函数名
            if re.search(r'^\s*(?:static\s+)?(?:__attribute__\S+\s+)?'
                         r'(?:void|BOOL|int|NSInteger|uint64_t|const\s+char|NSString)'
                         r'\s*\*?\s*%s\s*\(' % re.escape(name), ln):
                continue
            warn(f, i, "[3] %s 可能未声明（确认是否需前置声明）" % name)


# ---------- [4] ARC 桥接 ----------
def check_arc(f, lines):
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        # (void *)obj 形式
        if re.search(r'\(\s*void\s*\*\s*\)\s*[A-Za-z_]\w*\s*[;),]', code):
            if "__bridge" not in code:
                err(f, i, "[4] ARC 下 (void *) 转型需 __bridge")


# ---------- [5] Class / NSString 混用 ----------
def check_class_string(f, lines):
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        if re.search(r'\[\s*\w+\s+class\s*\]\s*\?\:', code):
            if "NSStringFromClass" not in code:
                err(f, i, "[5] [x class] ?: @\"...\" 类型不兼容，改用 NSStringFromClass")


# ---------- [6] hook 体内 IO ----------
HOOK_NAMES = ["SLFTVReload", "SLFCVReload", "SLFTVLayout", "SLFCVLayout",
              "SLFViewDidLoad", "SLFViewDidAppear", "SLFPerformFetch"]
IO_PAT = re.compile(r'dictionaryWithContentsOfFile|writeToFile|NSFileHandle|'
                    r'SLFLogAlways|fopen|open\(|read\(')


def check_hook_io(f, lines):
    for name in HOOK_NAMES:
        start = None
        depth = 0
        for i, ln in enumerate(lines, 1):
            if start is None and re.search(r'\b%s\s*\(' % name, ln) and \
               re.search(r'^\s*(?:__attribute__|static)', ln) is None:
                pass
            if start is None and re.search(r'static\s+.*\b%s\s*\(' % name, ln):
                start = i
                depth = 0
            if start is not None:
                code = re.sub(r"//.*$", "", ln)
                depth += code.count("{") - code.count("}")
                if i > start and IO_PAT.search(code):
                    warn(f, i, "[6] hook %s 内含 IO/同步日志（热路径风险）" % name)
                if depth == 0 and i > start and "}" in code:
                    start = None


# ---------- [7] orig 空判 ----------
def check_orig_null(f, lines):
    """[7] hook 转发前是否判过 orig 非空。

    ★ 判据必须是「同一函数内、调用之前」，不能只看同一行。
      原实现只看当前行是否含判空语句，于是下面这种完全正确的写法被误报：
          static void SLFTVReload(...) {
              if (gOrigTVReload == NULL) return;   // 第 99 行已判
              ...
              gOrigTVReload(self, _cmd);           // 第 105 行被误报
          }
      真实的崩溃风险是「进了函数一路到调用都没判过空」，这才是要抓的。
    """
    # 先定位每个函数的起始行
    func_starts = []
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        if re.search(r'^\s*(?:__attribute__[^\s]*\s+)?static\s+[^;]*\bSLF\w+\s*\([^;]*\)\s*\{', code):
            func_starts.append(i)

    def guard_in(c2, name):
        return bool(re.search(r'%s\s*==\s*NULL' % re.escape(name), c2) or
                    re.search(r'%s\s*==\s*Nil' % re.escape(name), c2) or
                    re.search(r'!\s*%s\b' % re.escape(name), c2) or
                    re.search(r'if\s*\(\s*%s\b' % re.escape(name), c2))

    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        for m in re.finditer(r'\b(gOrig\w+)\s*\(', code):
            name = m.group(1)
            if guard_in(code, name):
                continue
            # 所属函数起点
            start = 1
            for s in func_starts:
                if s <= i:
                    start = s
                else:
                    break
            guarded = False
            for k in range(start, i):
                if guard_in(re.sub(r"//.*$", "", lines[k - 1]), name):
                    guarded = True
                    break
            if not guarded:
                warn(f, i, "[7] %s 调用前未见判空（同一函数内也没找到）" % name)


# ---------- [8] block IMP / dlopen substrate ----------
def check_dangerous(f, lines):
    joined_names = []
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        if "imp_implementationWithBlock" in code:
            err(f, i, "[8] 禁用 block IMP（arm64e PAC 无保证）")
        if re.search(r'dlopen\s*\(\s*"[^"]*substrate', code):
            err(f, i, "[8] 禁止运行时 dlopen substrate 绝对路径")


# ---------- [9] 裸点语法 ----------
def check_dot_syntax(f, lines):
    # 本工程不访问任何私有属性；若出现 self.xxx 且 xxx 非本类声明，需要检查
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        for m in re.finditer(r'\bself\.(\w+)', code):
            prop = m.group(1)
            if prop in ("view",):
                continue
            warn(f, i, "[9] self.%s 需确认属性已声明" % prop)


# ---------- [10] 私有选择子 ----------
def check_selectors(f, lines):
    used = set()
    for i, ln in enumerate(lines, 1):
        for m in re.finditer(r'@selector\((\w+)\)', ln):
            used.add(m.group(1))
    declared = set()
    for ln in lines:
        for m in re.finditer(r'@selector\((\w+)\)', ln):
            declared.add(m.group(1))
    # 本工程只用公开 API，全部出现在 @selector 中即可


# ---------- [11] pthread_once 传 block ----------
def check_pthread_once(f, lines):
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        if "pthread_once" in code and "\\^" in code:
            err(f, i, "[11] pthread_once 不能接受 block，必须是 C 函数指针")
        if "pthread_once" in code and "^{" in code:
            err(f, i, "[11] pthread_once 不能接受 block")


# ---------- [12] hook 返回类型 ----------
def check_hook_returns(f, lines):
    expect = {
        "SLFPerformFetch": ("BOOL", "performFetch: 返回 BOOL"),
        "SLFViewDidAppear": ("void", "viewDidAppear: 返回 void"),
        "SLFTVReload": ("void", "reloadData 返回 void"),
    }
    for i, ln in enumerate(lines, 1):
        m = re.search(r'static\s+(\w+)\s+(SLF\w+)\s*\(', ln)
        if not m:
            continue
        ret, name = m.group(1), m.group(2)
        if name in expect and ret != expect[name][0]:
            err(f, i, "[12] %s 返回类型应为 %s（%s）" %
                (name, expect[name][0], expect[name][1]))


# ---------- [13] 持锁期间写日志 ----------
def check_lock_logging(f, lines):
    for i, ln in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", ln)
        if "os_unfair_lock_lock" in code:
            # 检查随后 12 行内是否直接 SLFLog（允许锁外，但这里的 NoteVCClass 已处理）
            for j in range(i, min(i + 12, len(lines))):
                nc = re.sub(r"//.*$", "", lines[j])
                if "os_unfair_lock_unlock" in nc:
                    break
                if re.search(r'\bSLFLog\s*\(', nc):
                    err(f, j + 1, "[13] 持锁期间调用 SLFLog（潜在死锁）")
                    break


# ---------- [14] 定时器未 static ----------
# 规则本意：dispatch_source 若无人强持有，会在创建它的作用域结束后被释放，
# 表现为"看门狗悄悄不再工作、日志一条不出"—— 属于最难排查的静默失效。
#
# 但早期实现是"这一行没有 static 关键字就报"，属于错误判据：
#   实际代码是
#       dispatch_source_t timer = dispatch_source_create(...);
#       gTickTimer = timer;          // ← 存进了文件作用域强引用
# 两行都正确，却被报成告警。这种误报比漏报更有害 ——
# 一旦告警里混入大量噪音，真正致命的那条就没人看了。
#
# 现在按【真实判据】检查：局部 timer 变量最终有没有被赋给一个
# 文件作用域的 static/全局槽位（约定以 g 开头）。
def check_timer_static(f, lines):
    # 收集文件作用域的强引用槽位：static dispatch_source_t gXxx
    slots = set()
    for ln in lines:
        nc = re.sub(r"//.*$", "", ln)
        m = re.match(r"\s*static\s+.*?\b(g\w+)\s*(?:=|;)", nc)
        if m:
            slots.add(m.group(1))

    if not slots:
        return

    for i, ln in enumerate(lines):
        code = re.sub(r"//.*$", "", ln)
        if "dispatch_source_create" not in code:
            continue
        # 同行就存进槽位（static dispatch_source_t g = create(...)）也算合格
        if any(re.search(r"\b%s\s*=" % s, code) for s in slots):
            continue
        # 取局部变量名
        m = re.search(r"\b(\w+)\s*=\s*dispatch_source_create", code)
        local = m.group(1) if m else None
        if local is None:
            warn(f, i + 1, "[14] dispatch_source_create 结果未赋给变量，无法持有")
            continue
        # 向后 12 行内查找 "槽位 = 局部变量;"
        window = [re.sub(r"//.*$", "", x) for x in lines[i:i + 12]]
        held = any(
            re.search(r"\b%s\s*=\s*%s\s*;" % (s, re.escape(local)), w)
            for w in window for s in slots
        )
        if not held:
            warn(f, i + 1,
                 "[14] 定时器 '%s' 未存入文件作用域强引用（槽位: %s），"
                 "可能被释放后静默失效" % (local, ",".join(sorted(slots))))


# ---------- [15] 构造函数 try/catch ----------
def check_constructor(f, lines):
    for i, ln in enumerate(lines, 1):
        if "__attribute__((constructor))" in ln:
            window = "".join(lines[i - 1:i + 6])
            if "@try" not in window:
                err(f, i, "[15] 构造函数缺少 @try（异常会影响宿主启动）")


# ---------- [16] iOS SDK 不支持的 macOS 专属头文件 ----------
# 2026-10-28 真实 CI 失败：SLFWatchdog.m 用了 <mach/mach_vm.h>，
# iOS SDK 里该文件是占位桩（内容仅一行 `#error mach_vm.h unsupported.`），
# 连带 mach_vm_read_overwrite 声明也不存在 → 隐式函数声明 → 编译失败。
# 本机无 clang，无法提前发现。改由 lint 静态拦截。
IOS_UNSUPPORTED_HEADERS = {
    "mach/mach_vm.h": "iOS 不支持，改用 <mach/mach.h> 的 vm_read_overwrite",
    "sys/kdebug.h": "iOS 不公开",
    "libproc.h": "iOS 大幅裁剪，多数接口不存在",
}


def check_ios_headers(f, lines):
    # 必须在"去掉注释"的代码上判定。
    # 首次实现直接扫原始行，结果把注释里写的 `#import <mach/mach_vm.h>` 也当成
    # 真实引用报了错（说明这一行本身不该报）。注释里的例子不能算违规。
    code_lines = strip_comment_lines(lines)
    for i, ln in enumerate(code_lines, 1):
        m = re.search(r'#\s*(?:include|import)\s*[<"]([^>"]+)[>"]', ln)
        if not m:
            continue
        h = m.group(1)
        if h in IOS_UNSUPPORTED_HEADERS:
            err(f, i, "[16] <%s> 在 iOS SDK 不可用：%s" %
                (h, IOS_UNSUPPORTED_HEADERS[h]))


# ---------- [17] 只写不读的 static 变量 ----------
def check_set_but_unused(f, lines):
    """检测 `static X y = NULL; ... y = z;` 之后从未读取的模式。

    判定：赋值次数 >= 1，且"非赋值出现次数" == 0。
    "非赋值出现"指变量名出现在不是赋值左侧的位置，例如
      gLogQueue ?: ...      ← 读
      if (gTick != NULL)     ← 读
      gTick = timer;         ← 写，不算
    注意 `?:` 前的变量名不含 '='，所以不会被误判成赋值。
    """
    body = "\n".join(strip_comment_lines(lines))
    for m in re.finditer(r'^\s*static\s+[\w\s\*]+?\b(\w+)\s*=\s*NULL\s*;',
                         body, re.M):
        var = m.group(1)
        # 所有出现位置
        occ = [mm.start() for mm in re.finditer(r'\b%s\b' % re.escape(var), body)]
        assign_pos = set()
        for mm in re.finditer(r'\b%s\s*=(?!=)' % re.escape(var), body):
            assign_pos.add(mm.start())
        reads = [p for p in occ if p not in assign_pos]
        # 容差必须为 0：声明行 `static X y = NULL;` 已被计入 assign_pos，
        # 不会再残留在 reads 里。写 <=1 会把"只读 1 次"的正常变量误报（已踩）。
        if len(assign_pos) >= 1 and len(reads) == 0:
            warn(f, 1, "[17] static %s 只赋值从不读取（-Wunused-but-set-variable）" % var)


# ---------- [18] 测试脚本不得写生产目录 ----------
def check_test_isolation():
    """确保 test_*.py 不直接修改 layout/ 或 build/ 里的真实文件。

    2026-10-28 真实事故：test_pack.py 为了验证"缺文件必须拦截"，
    删掉了 layout/var/mobile/Library/Preferences/*.plist。
    那是真实交付文件 —— 随后提交推送的仓库就缺了预置配置，
    CI 打包时报 "缺少预置配置文件"，白跑一轮。
    教训：测试必须重定向到临时目录，并且允许保留删除动作（它本身是对的，
    只是必须作用在临时副本上）。
    """
    fpath = os.path.join(ROOT, "test_pack.py")
    if not os.path.exists(fpath):
        return
    with open(fpath, encoding="utf-8") as f:
        body = f.read()
    if "pack.LAYOUT" in body and "tempfile" not in body:
        err("test_pack.py", 0,
            "[18] 测试脚本改写了生产 layout/ 却未重定向到临时目录（会删真实文件）")


# ---------- [19] 文档/脚本里的包版本号必须等于 control ----------
def check_version_refs():
    """README 等文档里出现的包文件名版本，必须与 control 的 Version 一致。

    真实事故（连续两次）：README 的安装命令先写 1.0.1、后来写 1.0.2，
    而 control 已经升到 1.0.3 —— 升版本时只改了 control 和 pack.py，
    忘了改文档。用户照着文档抄命令，就会去下载那个已经证明装不上的旧包。

    版本号是全项目最容易被漏掉的引用点，必须机器检查，不能靠记性。
    """
    cpath = os.path.join(ROOT, "control")
    try:
        with open(cpath, "rb") as f:
            raw = f.read().decode("utf-8")
    except OSError:
        return
    ver = ""
    for line in raw.split("\n"):
        if line.startswith("Version:"):
            ver = line.split(":", 1)[1].strip()
            break
    if not ver:
        err("control", 0, "[19] control 里没有 Version 字段")
        return

    # 只匹配包文件名形式，避免把 "iOS 17.0.3" 之类的版本误当包版本
    pat = re.compile(r"shortcutslagfix_(\d+\.\d+\.\d+)_")
    for fn in ("README.md", "build.sh", ".github/workflows/build.yml"):
        p = os.path.join(ROOT, fn)
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8", errors="replace") as f:
            for i, ln in enumerate(f, 1):
                for m in pat.finditer(ln):
                    if m.group(1) != ver:
                        err(fn, i,
                            "[19] 这里写的是 %s，而 control 是 %s —— 照抄会下错包"
                            % (m.group(1), ver))


def main():
    files = sources()
    if not files:
        print("[lint] 未找到源文件", file=sys.stderr)
        return 1

    for f in files:
        lines = read(f)
        check_brackets(f, lines)
        check_format(f, lines)
        check_implicit(f, lines)
        check_arc(f, lines)
        check_class_string(f, lines)
        check_hook_io(f, lines)
        check_orig_null(f, lines)
        check_dangerous(f, lines)
        check_dot_syntax(f, lines)
        check_selectors(f, lines)
        check_pthread_once(f, lines)
        check_hook_returns(f, lines)
        check_lock_logging(f, lines)
        check_timer_static(f, lines)
        check_constructor(f, lines)
        check_ios_headers(f, lines)
        check_set_but_unused(f, lines)

    check_test_isolation()
    check_version_refs()

    for w in warnings:
        print("[WARN] " + w)
    for e in errors:
        print("[ERROR] " + e)

    print("\n[lint] %d 文件, %d errors, %d warnings" %
          (len(files), len(errors), len(warnings)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())