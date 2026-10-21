#!/usr/bin/env python3
"""打包 MemKeep++ 模块 ZIP，并可同步改写 update.json。

用法：
    python scripts/build.py                       # 只打包 -> dist/ 与 release/
    python scripts/build.py --update-json         # 打包 + 按 module.prop 重写 update.json
    python scripts/build.py --repo owner/repo     # 指定 GitHub 仓库
    python scripts/build.py --zip-base <URL前缀>  # 换下载源（自建镜像 / 对象存储）

设计要点：
  * 只打包白名单内容，仓库里的 prototype/、scripts/、.github/ 不会进 ZIP；
  * .sh 保留 0755，其余 0644 —— 模块脚本靠 customize.sh 的 set_perm 兜底，但 zip 内权限正确更稳；
  * 打包后校验 update.json 与 module.prop 的 version/versionCode 是否一致，不一致直接失败，
    避免出现「管理器提示有更新，但下载到的是旧包」这类线上事故。

关于下载源（国内可访问性）：
  根管理器只会从 update.json 的 zipUrl 取包，所以「换镜像」就是把 zipUrl 换个前缀。
  GitHub Release 直链在国内经常连不上，因此默认让 zipUrl 指向 jsDelivr 的 GitHub 通道：
      https://cdn.jsdelivr.net/gh/<repo>@main/release/<file>.zip
  为什么可行：
    - jsDelivr 有专门的 Near China 节点，不需要 ICP 备案；
    - 单文件上限 20 MB，本模块不到 100 KB，完全够用；
    - 分支引用（@main）缓存 12 小时，但**每次发版文件名都带版本号 = 新路径**，
      新路径不存在旧缓存，首请求即回源，所以包本身永远是最新的。
  代价：zip 需要提交进仓库的 release/ 目录（Release 附件 jsDelivr 取不到）。
  想换成自有对象存储/自建反代时，只需 --zip-base https://your.domain/memkeep 即可，
  zipUrl 会变成 <zip-base>/<file>.zip。
"""
import argparse
import json
import os
import re
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_DIR = os.path.join(ROOT, "module")
DIST_DIR = os.path.join(ROOT, "dist")
RELEASE_DIR = os.path.join(ROOT, "release")   # 入库，供 jsDelivr 分发
UPDATE_JSON = os.path.join(ROOT, "update.json")

DEFAULT_REPO = "qvq9999/MemKeep"

# ZIP 根目录下应当包含的条目（其余一律不打包）
INCLUDE = ["module.prop", "config.conf", "keep_apps.conf", "app_names.conf", "skip_mount", "META-INF", "webroot", "bin"]
INCLUDE_EXT = (".sh",)

# 这些按文本处理：打包时统一把 CRLF 掰回 LF。
# Windows 上 core.autocrlf=true 的机器检出后是 CRLF，直接压进 zip 会让
# 模块脚本在开机阶段集体报 "$'\r': not found"，所以这里必须兜一道底。
TEXT_EXT = (".sh", ".prop", ".conf", ".json", ".html", ".css", ".js", ".md", ".txt")
TEXT_NAMES = ("module.prop", "config.conf", "skip_mount", "update-binary", "updater-script")

VERSION_RE = re.compile(r"^version=(.+)$", re.M)
CODE_RE = re.compile(r"^versionCode=(\d+)$", re.M)

# WebUI 里版本号的占位符：打包时按 module.prop 注入。
# 之前关于页的版本是手写的常量，发版永远不跟着变；注入 + 运行时读 module.prop
# 双保险后，页面显示的版本一定等于设备上真正装着的版本。
VER_TOKEN = b"__MK_VERSION__"
CODE_TOKEN = b"__MK_CODE__"


def read_prop():
    with open(os.path.join(MODULE_DIR, "module.prop"), encoding="utf-8") as f:
        text = f.read()
    mv, mc = VERSION_RE.search(text), CODE_RE.search(text)
    if not mv or not mc:
        sys.exit("module.prop 缺少 version 或 versionCode")
    return mv.group(1).strip(), int(mc.group(1))


def collect():
    """返回 [(绝对路径, zip 内相对路径)]，保持稳定顺序。"""
    items = []
    for name in INCLUDE:
        path = os.path.join(MODULE_DIR, name)
        if os.path.isdir(path):
            for dirpath, dirnames, filenames in os.walk(path):
                dirnames.sort()
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    rel = os.path.relpath(full, MODULE_DIR).replace(os.sep, "/")
                    items.append((full, rel))
        elif os.path.isfile(path):
            items.append((path, name))
    for fn in sorted(os.listdir(MODULE_DIR)):
        if fn.endswith(INCLUDE_EXT):
            items.append((os.path.join(MODULE_DIR, fn), fn))
    return items


def build(version, code):
    os.makedirs(DIST_DIR, exist_ok=True)
    target = os.path.join(DIST_DIR, "MemKeepPlus-%s.zip" % version)

    items = collect()
    fixed = 0
    injected = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for full, rel in items:
            info = zipfile.ZipInfo(rel)
            mode = 0o755 if (rel.endswith(".sh") or rel.endswith("update-binary")) else 0o644
            info.external_attr = mode << 16          # 关键：让解压后权限正确
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as f:
                data = f.read()
            if rel.endswith(TEXT_EXT) or os.path.basename(rel) in TEXT_NAMES:
                if b"\r\n" in data:
                    data = data.replace(b"\r\n", b"\n")
                    fixed += 1
            # 版本号注入：只对 WebUI 主页面做
            if rel == "webroot/index.html" and (VER_TOKEN in data or CODE_TOKEN in data):
                data = data.replace(VER_TOKEN, version.encode("utf-8"))
                data = data.replace(CODE_TOKEN, str(code).encode("ascii"))
                injected += 1
            z.writestr(info, data)

    size = os.path.getsize(target)
    print("built: %s  (%d files, %.1f KB)" % (os.path.relpath(target, ROOT), len(items), size / 1024))
    if fixed:
        print("normalized CRLF -> LF in %d file(s)" % fixed)
    if injected:
        print("injected version %s (%d) into webroot/index.html" % (version, code))

    return target


def sync_update_json(version, code, repo, zip_name, zip_base=None):
    """重写 update.json。

    zipUrl 默认走 jsDelivr 的 GitHub 通道：国内多数网络可直接访问，
    且文件名带版本号 = 每次都是新路径 = 不会命中 12 小时的旧缓存。
    换成自建镜像时传 zip_base 即可。
    """
    # 默认走 GitHub Release 直链：zip 不再提交进仓库，release/ 目录已废弃。
    # 需要镜像时用 --zip-base 覆盖即可。
    base = zip_base or ("https://github.com/%s/releases/download/%s" % (repo, version))
    base = base.replace("{repo}", repo).replace("{version}", version).rstrip("/")
    data = {
        "version": version,
        "versionCode": code,
        "zipUrl": "%s/%s" % (base, zip_name),
        "changelog": "https://%s.github.io/%s/CHANGELOG.md" % (repo.split("/")[0].lower(), repo.split("/")[1]),
    }
    with open(UPDATE_JSON, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("update.json -> %s (%d)" % (version, code))
    print("  zipUrl   : %s" % data["zipUrl"])
    print("  github   : https://github.com/%s/releases/download/%s/%s" % (repo, version, zip_name))


def verify(zip_path):
    problems = []
    with open(UPDATE_JSON, encoding="utf-8") as f:
        data = json.load(f)
    version, code = read_prop()
    if data.get("version") != version:
        problems.append("update.json version=%r ≠ module.prop version=%r" % (data.get("version"), version))
    if data.get("versionCode") != code:
        problems.append("update.json versionCode=%r ≠ module.prop versionCode=%r" % (data.get("versionCode"), code))
    for field in ("version", "versionCode", "zipUrl", "changelog"):
        if not data.get(field):
            problems.append("update.json 缺少必填字段 %s" % field)

    # 出包前再验一次：ZIP 里不允许出现 CRLF，否则脚本在设备上必挂
    with zipfile.ZipFile(zip_path) as z:
        for name in z.namelist():
            if name.endswith(TEXT_EXT) or os.path.basename(name) in TEXT_NAMES:
                if b"\r\n" in z.read(name):
                    problems.append("ZIP 内 %s 含 CRLF" % name)
        # 版本号占位符必须已经替换掉，否则关于页会显示 __MK_VERSION__
        if "webroot/index.html" in z.namelist():
            html = z.read("webroot/index.html")
            if VER_TOKEN in html or CODE_TOKEN in html:
                problems.append("ZIP 内 webroot/index.html 仍含版本占位符（注入失败）")

    if problems:
        sys.exit("校验失败：\n  - " + "\n  - ".join(problems))
    print("verify ok: update.json 与 module.prop 一致、ZIP 内全为 LF、版本号已注入")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update-json", action="store_true", help="按 module.prop 重写 update.json")
    ap.add_argument("--repo", default=DEFAULT_REPO, help="GitHub owner/repo，默认 %s" % DEFAULT_REPO)
    ap.add_argument("--zip-base", default=None,
                    help="zipUrl 前缀；支持 {repo} / {version} 占位符。"
                         "默认 jsDelivr 的 <repo>@main/release；换 ghproxy 示例："
                         "--zip-base 'https://ghfast.top/https://github.com/{repo}/releases/download/{version}'")
    args = ap.parse_args()

    version, code = read_prop()
    zip_name = "MemKeepPlus-%s.zip" % version

    if args.update_json:
        sync_update_json(version, code, args.repo, zip_name, args.zip_base)
    target = build(version, code)
    verify(target)


if __name__ == "__main__":
    main()
