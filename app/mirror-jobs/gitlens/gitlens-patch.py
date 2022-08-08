#!/usr/bin/env python3
"""Download the latest stable GitLens VSIX and build a personal Graph patch.

Python standard library only. Node.js is required for syntax validation.
Unknown JavaScript layouts are rejected, not patched speculatively.

The output publisher comes from --publisher or the PUBLISHER environment
variable and is never hardcoded; the official input stays eamodio.gitlens.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

DEFAULT_RELEASE_API = "https://api.github.com/repos/gitkraken/vscode-gitlens/releases/latest"
RELEASE_API = os.environ.get("RELEASE_API") or DEFAULT_RELEASE_API
PUBLISHER_RE = re.compile(r"[a-z0-9][a-z0-9-]*")


def _limit_from_env(name, default):
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"补丁失败：环境变量 {name} 不是整数：{raw}")
    if value <= 0:
        raise SystemExit(f"补丁失败：环境变量 {name} 必须为正整数：{raw}")
    return value


MAX_DOWNLOAD = _limit_from_env("MAX_DOWNLOAD", 200 * 1024 * 1024)
MAX_UNPACKED = _limit_from_env("MAX_UNPACKED", 512 * 1024 * 1024)
FETCH_TIMEOUT = _limit_from_env("REQUEST_TIMEOUT", 60)
NS = {"v": "http://schemas.microsoft.com/developer/vsx-schema/2011"}
IDENT = r"[A-Za-z_$][\w$]*"
MEMBER = IDENT + r"(?:\s*\.\s*" + IDENT + r")*"
ASSIGNMENT = re.compile(r"\bthis\s*\.\s*_accountAccessRequired\s*=(?!=|>)\s*")


def notice_text(publisher):
    return f"""<!-- personal-gitlens-patch -->
# 自用 GitLens：无需登录即可查看 Commit Graph

这是 **自用的非官方插件**（`{publisher}.gitlens`），修复了 Commit Graph 必须登录账号才能查看的问题，包括首次欢迎页再次弹出登录界面的情况。版本号与官方保持一致。

仅调整 Commit Graph 的账号／首次欢迎入口；不伪造账号或订阅，不修改私有仓库及其他功能原有的 Pro 权限检查。安装前请禁用官方 `eamodio.gitlens`，避免命令冲突。原作者信息和许可证保留，使用与分发仍须遵循原许可。

---

"""


class PatchError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PatchError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def github_url(url):
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    return (parsed.scheme == "https" and parsed.username is None and parsed.password is None
            and parsed.port in (None, 443)
            and (host in ("api.github.com", "github.com") or host.endswith(".githubusercontent.com")))


class GithubRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(github_url(newurl), f"拒绝非 GitHub HTTPS 重定向：{newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, limit=None):
    require(github_url(url), f"不是可信 GitHub HTTPS 地址：{url}")
    if limit is None:
        limit = MAX_DOWNLOAD
    request = urllib.request.Request(url, headers={
        "User-Agent": "personal-gitlens-patch", "Accept": "application/vnd.github+json"
        if urllib.parse.urlsplit(url).hostname == "api.github.com" else "application/octet-stream",
    })
    opener = urllib.request.build_opener(GithubRedirect())
    with opener.open(request, timeout=FETCH_TIMEOUT) as response:
        chunks, size = [], 0
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            require(size <= limit, f"下载超过大小限制：{limit} bytes")
            chunks.append(chunk)
    return b"".join(chunks)


def select_asset(release):
    require(not release.get("draft") and not release.get("prerelease"), "不是稳定版 release")
    tag = release.get("tag_name", "")
    require(re.fullmatch(r"v?\d+\.\d+\.\d+", tag), f"无法识别稳定版 tag：{tag}")
    assets = [a for a in release.get("assets", []) if a.get("name", "").lower().endswith(".vsix")]
    exact = [a for a in assets if a["name"] == f"gitlens-{tag.removeprefix('v')}.vsix"]
    if exact:
        assets = exact
    require(len(assets) == 1, "无法唯一选择官方 VSIX 资产（缺失或有多个候选）")
    asset = assets[0]
    require(github_url(asset.get("browser_download_url", "")), "VSIX 下载地址不可信")
    require(isinstance(asset.get("size"), int) and 0 < asset["size"] <= MAX_DOWNLOAD, "VSIX 大小无效")
    return asset


def download_latest(release_file=None):
    if release_file is not None:
        data = Path(release_file).read_bytes()
        require(len(data) <= 4 * 1024 * 1024, "release 文件超过大小限制")
        provenance_extra = {"release_file": str(Path(release_file).absolute())}
    else:
        data = fetch(RELEASE_API, 4 * 1024 * 1024)
        provenance_extra = {}
    release = json.loads(data)
    asset = select_asset(release)
    print(f"下载 GitLens {release['tag_name']}：{asset['name']}", flush=True)
    data = fetch(asset["browser_download_url"])
    require(len(data) == asset["size"], "下载大小与 GitHub 资产元数据不符")
    expected = asset.get("digest")
    if expected:
        require(expected == "sha256:" + digest(data), "GitHub 资产 digest 校验失败或算法不支持")
    return data, {"url": asset["browser_download_url"], "tag": release["tag_name"],
                  "asset_digest": expected, "asset_size": asset["size"],
                  "digest_verified": bool(expected), **provenance_extra}


def read_archive(data):
    require(len(data) <= MAX_DOWNLOAD, "输入 VSIX 超过大小限制")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        require(len(entries) <= 20000, "ZIP 条目过多")
        require(sum(e.file_size for e in entries) <= MAX_UNPACKED, "ZIP 解压大小超过限制")
        seen = set()
        for entry in entries:
            name = entry.filename
            path = PurePosixPath(name)
            require(name and not path.is_absolute() and not re.match(r"^[A-Za-z]:", name)
                    and "\\" not in name and "\x00" not in name
                    and all(p not in (".", "..", "") for p in name.rstrip("/").split("/")),
                    f"不安全 ZIP 路径：{name}")
            key = name.rstrip("/").casefold()
            require(key not in seen, f"重复或大小写冲突的 ZIP 路径：{name}")
            seen.add(key)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR), f"不支持的 ZIP 文件类型：{name}")
            require(not entry.flag_bits & 1, "不支持加密 ZIP")
        files = {entry.filename: archive.read(entry) for entry in entries}
    return entries, files


def identity(files, publisher="eamodio"):
    package = json.loads(files["extension/package.json"])
    manifest = ET.fromstring(files["extension.vsixmanifest"])
    ident = manifest.find("v:Metadata/v:Identity", NS)
    version = package.get("version", "")
    require(re.fullmatch(r"\d+\.\d+\.\d+", version), f"不支持的官方稳定版版本号：{version}")
    require(package.get("name") == "gitlens" and package.get("publisher") == publisher,
            f"输入必须是 {publisher}.gitlens，不能是已修改包")
    require(ident is not None and (ident.get("Id"), ident.get("Publisher"), ident.get("Version"))
            == ("gitlens", publisher, version), "package.json 与 VSIX manifest 身份不一致")
    return package


def balanced_end(text, start):
    """Scan a bounded expression/body, rejecting regex and template ambiguity.

    This is deliberately not a general JavaScript parser. Unrecognized syntax
    requires a reviewed matcher update, even when node --check would accept it.
    """
    pairs = {"(": ")", "[": "]", "{": "}"}
    require(text[start] in pairs, "缺少起始括号")
    stack, i = [], start
    while i < len(text) and i - start < 100000:
        ch = text[i]
        if ch in "'\"`":
            quote = ch
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i += 2
                    continue
                require(not (quote == "`" and text.startswith("${", i)), "模板插值需要人工审核")
                if text[i] == quote:
                    break
                i += 1
            require(i < len(text), "字符串未闭合")
        elif text.startswith("//", i):
            end = text.find("\n", i + 2)
            require(end >= 0, "注释后缺少结束括号")
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            require(end >= 0, "注释未闭合")
            i = end + 1
        elif ch == "/":
            raise PatchError("目标表达式含正则／除法歧义，需要人工审核")
        elif ch in pairs:
            stack.append(pairs[ch])
        elif ch in ")]}":
            require(stack and stack.pop() == ch, "目标括号不匹配")
            if not stack:
                return i + 1
        i += 1
    raise PatchError("无法确定目标表达式的结束位置")


def call_end(text, start):
    # Webpack's (0,module.export)(arg), or an unminified helper/member call.
    indirect = re.match(r"\(\s*0\s*,\s*" + MEMBER + r"\s*\)\s*\(", text[start:])
    direct = re.match(MEMBER + r"\s*\(", text[start:])
    match = indirect or direct
    require(match is not None, f"无法识别账号检查调用：{text[start:start + 100]}")
    end = balanced_end(text, start + match.end() - 1)
    rest = text[end:].lstrip()
    require(rest and rest[0] in ",;)}", "账号检查调用之后仍有运算，不执行部分替换")
    return end


def getter_span(text, name):
    matches = list(re.finditer(r"\bget\s+" + re.escape(name) + r"\s*\(\s*\)\s*\{", text))
    require(len(matches) == 1, f"getter {name} 应唯一，实际 {len(matches)} 处")
    start = matches[0].start()
    body = matches[0].end() - 1
    return start, body, balanced_end(text, body)


def apply_edits(text, edits):
    previous = len(text) + 1
    for start, end, replacement in sorted(edits, reverse=True):
        require(0 <= start < end <= previous, "补丁范围重叠或无效")
        text = text[:start] + replacement + text[end:]
        previous = start
    return text


def patch_host(text):
    require("gitlens.graph" in text and "_etagSubscription" in text, "账号检查不在已知 Graph 宿主中")
    matches = list(ASSIGNMENT.finditer(text))
    # One initialization and one subscription-change path: extra paths need review.
    require(len(matches) == 2, f"预期 Graph 初始化／订阅变更两条路径，实际 {len(matches)} 处")
    edits = [(m.end(), call_end(text, m.end()), "!1") for m in matches]
    return apply_edits(text, edits), len(edits)


def patch_ui(text):
    require("gl-graph-access-account" in text and "graphState" in text, "不是已知 Graph UI")
    access_start, _, access_end = getter_span(text, "isAccessGated")
    access = text[access_start:access_end]
    require(re.search(r"!\s*this\s*\.\s*graphState\s*\.\s*allowed", access), "无法确认 Pro access 分支")
    require(re.search(r"this\.isAccountGated\s*\|\|\s*this\.shouldShowWelcome", text), "Graph 登录／欢迎页入口已变化")
    edits = []
    for name in ("isAccountGated", "shouldShowWelcome"):
        _, body, end = getter_span(text, name)
        edits.append((body + 1, end - 1, "return!1"))
    result = apply_edits(text, edits)
    a, _, b = getter_span(result, "isAccessGated")
    require(result[a:b] == access, "Pro access getter 发生意外变化")
    return result


def patch_files(original, publisher):
    package = identity(original)
    files = original.copy()
    changes = []
    hosts, uis = [], []
    for name, data in files.items():
        if not name.startswith("extension/") or not name.endswith(".js"):
            continue
        text = data.decode("utf-8")
        if ASSIGNMENT.search(text):
            hosts.append(name)
        if re.search(r"\bget\s+isAccountGated\s*\(", text):
            uis.append(name)
    require(hosts, "未发现 Graph 宿主账号检查；上游结构可能已改变")
    require(len(uis) == 1, f"无法唯一发现 Graph UI：{uis}")
    for key in ("main", "browser"):
        if not package.get(key):
            continue
        entry = PurePosixPath("extension") / package[key]
        require(str(entry) in files, f"入口不存在：{entry}")
        require(any(PurePosixPath(h).parent == entry.parent for h in hosts),
                f"{key} 入口对应的 Graph 宿主未发现，拒绝不完整补丁")
    for name in hosts:
        try:
            text, count = patch_host(files[name].decode("utf-8"))
        except PatchError as exc:
            raise PatchError(f"{name}: {exc}") from exc
        files[name] = text.encode("utf-8")
        changes.append({"file": name, "patch": "graph-host-account", "count": count})
    for name in uis:
        files[name] = patch_ui(files[name].decode("utf-8")).encode("utf-8")
        changes.append({"file": name, "patch": "graph-account-and-welcome-getters", "count": 2})

    def replace(name, pattern, replacement, expected=None):
        text, count = re.subn(pattern, replacement, files[name].decode("utf-8"))
        require(expected is None or count == expected, f"{name} 身份匹配数错误：{count}")
        if count:
            files[name] = text.encode("utf-8")
            changes.append({"file": name, "patch": "identity", "count": count})

    replace("extension/package.json", r'("publisher"\s*:\s*)"eamodio"', r'\g<1>"' + publisher + '"', 1)
    replace("extension/package.json", r"\^eamodio(?:\\\\\.|\.)gitlens", "^" + publisher + ".gitlens")
    # XML is parsed for validation; preserve formatting, namespace prefixes and assets.
    manifest = files["extension.vsixmanifest"].decode("utf-8")
    match = re.search(r"<(?:[\w]+:)?Identity\b[^>]*>", manifest)
    require(match is not None, "VSIX Identity 标记缺失")
    new_tag, count = re.subn(r'''(\bPublisher\s*=\s*)(["'])eamodio\2''',
                            lambda m: m[1] + m[2] + publisher + m[2], match[0])
    require(count == 1, "VSIX Identity Publisher 不唯一")
    files["extension.vsixmanifest"] = (manifest[:match.start()] + new_tag + manifest[match.end():]).encode("utf-8")
    changes.append({"file": "extension.vsixmanifest", "patch": "publisher", "count": 1})
    for name in list(files):
        if name.startswith("extension/") and name.endswith(".js"):
            replace(name, r'''(["'])eamodio\.gitlens\1''', lambda m: m[1] + publisher + ".gitlens" + m[1])
    details = ET.fromstring(original["extension.vsixmanifest"]).find(
        "v:Assets/v:Asset[@Type='Microsoft.VisualStudio.Services.Content.Details']", NS)
    require(details is not None and details.get("Path") in files, "包内 README 资产缺失")
    readme = details.get("Path")
    files[readme] = notice_text(publisher).encode("utf-8") + files[readme]
    changes.append({"file": readme, "patch": "chinese-personal-use-notice", "count": 1})
    patched = identity(files, publisher)
    require(patched["version"] == package["version"], "不能修改官方版本号")
    require(PUBLISHER_RE.fullmatch(patched.get("publisher", "")), "输出 publisher 不符合命名规范")
    return files, changes, uis


def check_javascript(changed, directory):
    checked = []
    for name in changed:
        if name.endswith(".js"):
            result = subprocess.run(["node", "--check", str(directory / name)], capture_output=True, text=True, timeout=60)
            require(result.returncode == 0, f"JavaScript 语法错误 {name}:\n{result.stderr}")
            checked.append(name)
    return checked


def build(data, provenance, publisher, output_dir=None):
    require(shutil.which("node"), "需要 Node.js 进行语法检查，请先安装 Node.js")
    entries, original = read_archive(data)
    package = identity(original)
    version = package["version"]
    if provenance.get("tag"):
        require(provenance["tag"].removeprefix("v") == version, "GitHub tag 与包内版本不符")
    if output_dir is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        output_dir = Path(__file__).resolve().parent / "dist" / f"{version}-{stamp}"
    output_dir = Path(output_dir).absolute()
    require(not output_dir.exists(), f"输出目录已存在，拒绝覆盖：{output_dir}")
    files, changes, _ = patch_files(original, publisher)
    changed = sorted(name for name in files if files[name] != original[name])
    require(set(changed) == {c["file"] for c in changes}, "变更集合与报告不符")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".gitlens-patch-", dir=output_dir.parent) as temporary:
        stage = Path(temporary)
        unpacked = stage / "unpacked"
        for entry in entries:
            path = unpacked / entry.filename
            if entry.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(files[entry.filename])
        checked = check_javascript(changed, unpacked)
        output = stage / f"{publisher}.gitlens-{version}.vsix"
        with zipfile.ZipFile(output, "w") as archive:
            for entry in entries:
                archive.writestr(entry, files[entry.filename])
        with zipfile.ZipFile(output) as archive:
            require(archive.namelist() == [e.filename for e in entries], "成品 ZIP 条目变化")
            require(all(archive.read(name) == content for name, content in files.items()), "成品回读验证失败")
        source = stage / f"eamodio.gitlens-{version}.original.vsix"
        source.write_bytes(data)
        output_hash = digest(output.read_bytes())
        report = {
            "extension_id": f"{publisher}.gitlens", "version": version,
            "vscode_engine": package.get("engines", {}).get("vscode"),
            "source": {**provenance, "sha256": digest(data)},
            "output": output.name, "output_sha256": output_hash,
            "patches": changes, "zip_entries": len(entries),
            "changed_files": [{"path": name, "before_sha256": digest(original[name]),
                               "after_sha256": digest(files[name])} for name in changed],
            "checks": {"zip_readback": "passed", "identity_and_version": "passed",
                       "javascript_syntax": checked, "pro_access_getter_unchanged": True,
                       "gui_test": "not performed by this script"},
        }
        (stage / "patch-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (stage / "SHA256SUMS").write_text(f"{digest(data)}  {source.name}\n{output_hash}  {output.name}\n", encoding="utf-8")
        # Publish only after all checks pass; do not overwrite even an empty directory.
        output_dir.mkdir(exist_ok=False)
        try:
            for child in stage.iterdir():
                shutil.move(str(child), output_dir / child.name)
        except Exception:
            shutil.rmtree(output_dir)
            raise
    return output_dir / output.name


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="自动下载 GitLens 最新稳定版，为自用补丁并输出 <publisher>.gitlens VSIX")
    parser.add_argument("--publisher", default=os.environ.get("PUBLISHER", ""),
                        help="输出扩展发布者 ID，默认取环境变量 PUBLISHER")
    parser.add_argument("--source", type=Path, help="离线使用官方 VSIX（默认从 GitHub 下载最新稳定版）")
    parser.add_argument("--release-file", type=Path,
                        help="使用本地保存的 GitHub release JSON，与 --source 互斥，避免重复查询上游")
    parser.add_argument("--output-dir", type=Path, help="全新输出目录（默认 dist/<官方版本>-<UTC时间戳>）")
    args = parser.parse_args(argv)
    try:
        require(shutil.which("node"), "请先安装 Node.js，以验证修改后的 JavaScript 语法")
        require(PUBLISHER_RE.fullmatch(args.publisher),
                f"publisher 必须匹配 {PUBLISHER_RE.pattern}，可通过 --publisher 或环境变量 PUBLISHER 提供")
        if args.output_dir:
            require(not args.output_dir.exists(), f"输出目录已存在，拒绝覆盖：{args.output_dir}")
        if args.source and args.release_file:
            raise PatchError("--source 与 --release-file 不能同时使用")
        if args.source:
            require(args.source.stat().st_size <= MAX_DOWNLOAD, "输入 VSIX 超过大小限制")
            data, provenance = args.source.read_bytes(), {"path": str(args.source.absolute())}
        else:
            data, provenance = download_latest(args.release_file)
        output = build(data, provenance, args.publisher, args.output_dir)
        print(f"完成：{output}\n版本保持官方一致；报告和 SHA256SUMS 位于同目录。\n注意：静态检查不等于真实界面测试；请禁用官方 GitLens 后安装。")
        return 0
    except (PatchError, OSError, ValueError, KeyError, zipfile.BadZipFile, ET.ParseError,
            urllib.error.URLError, subprocess.SubprocessError) as exc:
        print(f"补丁失败：{exc}\n未生成可安装成品；若是上游代码结构变化，需要更新匹配规则。", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
