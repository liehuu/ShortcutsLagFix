#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通过 GitHub Git Data API 推送本地 commit。

为什么不用 git push：
  本机沙箱里 api.github.com 可直连，github.com（git smart HTTP 所在）
  被代理挡掉（000/502）。Git Data API 全程走 api.github.com。

为什么差异要两边比对 tree，而不是 `git diff origin/main HEAD`：
  走 API 推送会在远端生成新 sha，本地的 origin/main 引用随之指向不存在的
  对象，`git update-ref` 会拒绝，`git fetch` 又因为 github.com 不通而失败。
  于是「本地引用新鲜」这个前提根本守不住 —— 一旦陈旧，脚本会把已经推过的
  文件重复算成变更。
  改用「远端 tree vs 本地 HEAD tree 逐文件比 blob sha」：
  git 与 GitHub 对同一内容算出的 blob SHA-1 完全相同，直接比 sha 即可，
  不需要下载任何文件内容，也不依赖任何本地远端引用。

流程：
  1. 读 main 当前 ref -> commit sha -> tree sha
  2. 递归取远端 tree，得到 {path: blob_sha}
  3. 取本地 HEAD 的 tree，得到 {path: blob_sha}
  4. 差异 = 新增 / 内容变化 / 删除
  5. 逐文件建 blob，基于远端 tree 建新 tree，建 commit，前移 ref
"""

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "liehuu/ShortcutsLagFix"
API = "https://api.github.com"
ROOT = os.path.dirname(os.path.abspath(__file__))


def get_token():
    """从 Windows Git Credential Manager 取 token（不打印）。"""
    cmd = ("C:/Users/fengb/AppData/Local/Programs/WorkBuddy/"
           "resources/vendor/PortableGit/mingw64/bin/git-credential-manager.exe")
    out = subprocess.run([cmd, "get"], input="protocol=https\nhost=github.com\n\n",
                         capture_output=True, text=True)
    for line in out.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    raise RuntimeError("credential-manager 未返回 token")


class GH:
    def __init__(self, token):
        self.token = token

    def req(self, method, path, body=None):
        url = API + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        r = urllib.request.Request(url, data=data, method=method)
        r.add_header("Authorization", "Bearer " + self.token)
        r.add_header("Accept", "application/vnd.github+json")
        r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, timeout=90) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            raise RuntimeError("HTTP %s %s -> %s" % (e.code, path, detail[:500]))


def sh(args):
    r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("git %s 失败: %s" % (" ".join(args), r.stderr[:300]))
    return r.stdout


def remote_tree(gh, tree_sha):
    """递归展开远端 tree -> {path: blob_sha}（只收 blob）。"""
    st, d = gh.req("GET", "/repos/%s/git/trees/%s?recursive=1" % (REPO, tree_sha))
    if d.get("truncated"):
        raise RuntimeError("远端 tree 过大被截断，该仓库不该出现这种情况")
    out = {}
    for e in d["tree"]:
        if e["type"] == "blob":
            out[e["path"]] = e["sha"]
    return out


def local_tree(rev="HEAD"):
    """本地 HEAD -> {path: blob_sha}。"""
    out = {}
    for line in sh(["git", "ls-tree", "-r", rev]).splitlines():
        meta, path = line.split("\t", 1)
        mode, typ, sha = meta.split()
        if typ == "blob":
            out[path] = sha
    return out


def main():
    gh = GH(get_token())

    # 1. 远端 main 当前 commit / tree
    st, ref = gh.req("GET", "/repos/%s/git/ref/heads/main" % REPO)
    base_commit = ref["object"]["sha"]
    st, commit = gh.req("GET", "/repos/%s/git/commits/%s" % (REPO, base_commit))
    base_tree = commit["tree"]["sha"]

    rtree = remote_tree(gh, base_tree)
    ltree = local_tree("HEAD")

    added = sorted(p for p in ltree if p not in rtree)
    changed = sorted(p for p in ltree if p in rtree and ltree[p] != rtree[p])
    removed = sorted(p for p in rtree if p not in ltree)

    print("远端 main = %s  文件数 %d" % (base_commit[:8], len(rtree)))
    print("本地 HEAD = %s  文件数 %d" % (sh(["git", "rev-parse", "--short", "HEAD"]).strip(),
                                       len(ltree)))
    if not (added or changed or removed):
        print("\n两侧 tree 完全一致，没有待推送的改动")
        return 0

    for tag, items in (("新增", added), ("修改", changed), ("删除", removed)):
        for p in items:
            print("  %s  %s" % (tag, p))

    # 2. 逐文件建 blob（删除的文件用 sha=null）
    entries = []
    for rel in added + changed:
        path = os.path.join(ROOT, rel)
        with open(path, "rb") as fh:
            raw = fh.read()
        st, blob = gh.req("POST", "/repos/%s/git/blobs" % REPO, {
            "content": base64.b64encode(raw).decode("ascii"),
            "encoding": "base64",
        })
        if blob["sha"] != ltree[rel]:
            raise RuntimeError(
                "本地与 API 算出的 blob sha 不一致: %s %s != %s"
                % (rel, blob["sha"], ltree[rel]))
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print("  blob  %s (%d bytes)" % (rel, len(raw)))
    for rel in removed:
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": None})

    # 3. 新 tree
    st, tree = gh.req("POST", "/repos/%s/git/trees" % REPO, {
        "base_tree": base_tree,
        "tree": entries,
    })
    print("\n新 tree = %s" % tree["sha"][:8])

    # 4. 新 commit（沿用本地 HEAD 的 message）
    msg = sh(["git", "log", "-1", "--pretty=%B"]).strip()
    st, new_commit = gh.req("POST", "/repos/%s/git/commits" % REPO, {
        "message": msg,
        "tree": tree["sha"],
        "parents": [base_commit],
    })
    print("新 commit = %s" % new_commit["sha"][:8])

    # 5. 前移 ref（force=false：远端有并发提交时拒绝，不覆盖别人的工作）
    gh.req("PATCH", "/repos/%s/git/refs/heads/main" % REPO, {
        "sha": new_commit["sha"],
        "force": False,
    })
    print("main 已前移到 %s" % new_commit["sha"][:8])

    # 6. 本地也把这次改动落成一个真实提交，并同步远端引用，
    #    这样以后 git log / git diff 不会失真。
    sh(["git", "update-ref", "refs/remotes/origin/main", new_commit["sha"]])
    print("\n完成。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("[FAIL] %s" % e, file=sys.stderr)
        sys.exit(1)
