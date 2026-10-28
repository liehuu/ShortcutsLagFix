#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
查询 GitHub Actions 运行状态，成功后下载产物（deb）。

为什么要单独写：
  本机没有 gh，且 github.com 被代理挡住，只有 api.github.com 可用。
  产物下载会 302 到 Azure Blob，urllib 默认会把 Authorization 带过去而被拒（401），
  所以下载那一步必须交给 curl -L 且不在重定向后继续带 token。

用法：
  python ci_check.py            # 等最近一次运行完成并下载产物
  python ci_check.py --log      # 失败时打印失败 job 的日志尾部
"""

import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from push_via_api import get_token  # noqa: E402  复用同一套凭证读取

API = "https://api.github.com"
OWNER, REPO = "liehuu", "ShortcutsLagFix"
ROOT = os.path.dirname(os.path.abspath(__file__))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """禁止自动跟随 302。

    为什么必须禁：GitHub 的日志与产物下载都会 302 到 Azure Blob，
    目标 URL 自带 SAS 签名、**不接受** Authorization 头。
    urllib 默认跟随重定向并把原请求头一起带过去，于是必然 401：
      HTTP Error 401: Server failed to authenticate the request
    正确做法是分两步：先用 token 拿到 Location，再匿名请求那个地址。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


_OPENER = urllib.request.build_opener(_NoRedirect)


def download_signed(url, token, out_path):
    """两步下载：带 token 取 Location，再匿名取内容。"""
    r = urllib.request.Request(url)
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Accept", "application/vnd.github+json")
    try:
        with _OPENER.open(r, timeout=120) as resp:      # 万一没有重定向
            data = resp.read()
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location") if e.headers else None
        if not loc:
            raise
        with urllib.request.urlopen(urllib.request.Request(loc), timeout=180) as resp:
            data = resp.read()
    with open(out_path, "wb") as fh:
        fh.write(data)
    return len(data)


def req(path, token, raw=False):
    r = urllib.request.Request(API + path)
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    with urllib.request.urlopen(r, timeout=60) as resp:
        data = resp.read()
    return data if raw else json.loads(data.decode("utf-8"))


def latest_run(token):
    d = req("/repos/%s/%s/actions/runs?per_page=1" % (OWNER, REPO), token)
    runs = d.get("workflow_runs") or []
    return runs[0] if runs else None


def job_log(token, job_id):
    url = API + "/repos/%s/%s/actions/jobs/%s/logs" % (OWNER, REPO, job_id)
    tmp = os.path.join(ROOT, "_ci_job.log")
    download_signed(url, token, tmp)
    with open(tmp, "rb") as fh:
        txt = fh.read().decode("utf-8", "replace")
    try:
        os.remove(tmp)
    except OSError:
        pass
    return txt


def main():
    token = get_token()
    run = latest_run(token)
    if not run:
        print("没有找到任何运行")
        return 1

    rid = run["id"]
    print("run %s  sha=%s  status=%s" % (rid, run["head_sha"][:8], run["status"]))

    # 最多等 15 分钟
    for _ in range(90):
        if run["status"] == "completed":
            break
        time.sleep(10)
        run = req("/repos/%s/%s/actions/runs/%s" % (OWNER, REPO, rid), token)
        print("  ... %s" % run["status"])

    print("conclusion=%s" % run["conclusion"])

    if run["conclusion"] != "success":
        if "--log" in sys.argv:
            jobs = req("/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, rid), token)
            for j in jobs.get("jobs", []):
                if j.get("conclusion") != "success":
                    print("\n===== 失败 job: %s =====" % j.get("name"))
                    txt = job_log(token, j["id"])
                    print("\n".join(txt.splitlines()[-120:]))
        return 2

    d = req("/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, rid), token)
    arts = d.get("artifacts") or []
    if not arts:
        print("运行成功但没有产物")
        return 3

    got_deb = 0
    for a in arts:
        if a.get("expired"):
            print("产物已过期: %s" % a["name"])
            continue
        # 用两步下载：302 到 blob 后不能再带 Authorization
        out = os.path.join(ROOT, "_ci_artifact.zip")
        try:
            download_signed(a["archive_download_url"], token, out)
        except Exception as exc:                      # noqa: BLE001
            print("下载失败: %s" % exc)
            return 4

        with zipfile.ZipFile(out) as z:
            for m in z.namelist():
                if m.endswith(".deb"):
                    data = z.read(m)
                    dst = os.path.join(ROOT, os.path.basename(m))
                    with open(dst, "wb") as fh:
                        fh.write(data)
                    print("已下载 %s (%d bytes)" % (os.path.basename(m), len(data)))
                    got_deb += 1
                elif m.endswith(".txt") or m.endswith(".log"):
                    # 构建日志/校验报告一并落盘，便于事后核对
                    txt = z.read(m).decode("utf-8", "replace")
                    if "结论" in txt or "FAIL" in txt or "OK" in txt:
                        name = "_ci_" + os.path.basename(m)
                        with open(os.path.join(ROOT, name), "w", encoding="utf-8") as fh:
                            fh.write(txt)
                        print("  附带报告: %s" % name)
        os.remove(out)

    # 判断必须放在循环之外：CI 会上传两个 artifact（dylib 与 deb），
    # 第一个是 dylib，若在循环内判断"本包没有 deb"就 return，
    # 会漏掉后面真正装着 deb 的那个。
    if got_deb == 0:
        print("所有压缩包里都没有 .deb")
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
