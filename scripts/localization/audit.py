#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地化资源完整性审计工具。

OpenSpec 变更 add-app-internationalization 的统一 CI 入口（任务 1.3-1.6），
组合三类检查：
1. String Catalog（xcstrings JSON）双语完整性、参数模式、键命名与所有者规则；
2. 生产 Swift 提示出口扫描：硬编码中英文提示必须资源化或逐条排除；
3. Rust/FFI 程序消息检查：固定用户说明只能引用声明式消息清单中的 message code，
   并与 Messages catalog 保持一致。

仅使用 Python 3 标准库；以仓库根目录下的 audit-config.json 为配置。
"""

import json
import os
import re
import sys
from collections import Counter
from collections import namedtuple

ISSUE_SEVERITY_ERROR = "error"
ISSUE_SEVERITY_WARNING = "warning"

Issue = namedtuple("Issue", ["severity", "code", "file", "line", "message"])
AuditReport = namedtuple("AuditReport", ["issues"])

# 排除原因闭集：依赖/开发诊断类不允许包含中文（中文只可能是程序自写文案）。
EXCLUSION_REASONS = {
    "user_data",
    "raw_dependency_diagnostic",
    "dev_diagnostic",
    "brand_or_contract",
    "demo_fixture",
    "protocol_contract",
}
CJK_FREE_EXCLUSION_REASONS = {"raw_dependency_diagnostic", "dev_diagnostic"}

DEFAULT_KEY_MODULES = [
    "app", "settings", "host", "group", "snippet", "workspace", "terminal",
    "sftp", "transfer", "monitor", "log", "auth", "error",
]
DEFAULT_KEY_PURPOSE_TOKENS = [
    "title", "detail", "action", "label", "placeholder", "help",
    "accessibility_label", "confirm", "count", "status", "toast", "hint",
    "section", "menu", "subtitle", "message", "header", "empty", "unit",
    "tooltip", "name", "summary", "description", "subtitle",
]

SWIFT_PRESENTING_APIS = [
    "Text", "Button", "Label", "TextField", "SecureField", "Toggle",
    "Picker", "Menu", "Section", "LabeledContent", "Stepper",
]
SWIFT_PRESENTING_MODIFIERS = [
    "navigationTitle", "alert", "confirmationDialog", "help",
    "accessibilityLabel", "accessibilityHint", "accessibilityValue",
]

RUST_LITERAL_PATTERNS = [
    ("error_attribute", re.compile(r'#\[error\(\s*"((?:[^"\\]|\\.)*)"')),
    ("anyhow_context", re.compile(r'\.context\(\s*"((?:[^"\\]|\\.)*)"')),
    ("core_format", re.compile(r'Core\(format!\(\s*"((?:[^"\\]|\\.)*)"')),
    ("core_literal", re.compile(r'Core\(\s*"((?:[^"\\]|\\.)*)"')),
]

FORMAT_SPECIFIER_RE = re.compile(
    r"%(?:(\d+)\$)?(l{1,2}|ll|z|t|h)?([@diouxXfFeEgGcCsSaA])"
)


class CatalogError(Exception):
    pass


def _no_duplicate_keys(pairs):
    seen = set()
    out = {}
    for k, v in pairs:
        if k in seen:
            raise CatalogError("duplicate key: %s" % k)
        seen.add(k)
        out[k] = v
    return out


def _load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=_no_duplicate_keys)


def _has_cjk(text):
    return any("\u4e00" <= ch <= "\u9fff" for ch in text)


def _string_units(node):
    """递归取出一个语言节点下全部 stringUnit 的 value（含复数/设备变体）。"""
    values = []
    if not isinstance(node, dict):
        return values
    if "stringUnit" in node and isinstance(node["stringUnit"], dict):
        values.append(node["stringUnit"].get("value", ""))
    for variation in (node.get("variations") or {}).values():
        values.extend(_string_units(variation))
    for substitution in (node.get("substitutions") or {}).values():
        values.extend(_string_units(substitution))
    return values


def _specifier_classes(value):
    """提取格式说明符的类别多重集（忽略位置，允许译文调整顺序）。"""
    classes = Counter()
    for match in FORMAT_SPECIFIER_RE.finditer(value):
        conv = match.group(3)
        length = match.group(2) or ""
        if conv == "@" or conv == "s":
            classes["string"] += 1
        elif conv in "di":
            classes["int"] += 1
        elif conv in "u":
            classes["uint"] += 1
        elif conv in "xXo":
            classes["uint"] += 1
        elif conv in "fFeEgG":
            classes["float"] += 1
        elif conv == "c":
            classes["char"] += 1
        elif conv == "a" or conv == "A":
            classes["float"] += 1
        else:
            classes["other:" + length + conv] += 1
    return classes


def _swift_strip_comments_and_previews(source):
    out = []
    i = 0
    n = len(source)
    depth_block = 0
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if depth_block > 0:
            if ch == "*" and nxt == "/":
                depth_block -= 1
                i += 2
            else:
                if ch == "\n":
                    out.append(ch)
                i += 1
            continue
        if ch == "/" and nxt == "*":
            depth_block += 1
            i += 2
            continue
        if ch == "/" and nxt == "/":
            while i < n and source[i] != "\n":
                i += 1
            continue
        out.append(ch)
        i += 1
    text = "".join(out)
    # 去掉 #Preview { ... } / #Preview("...") { ... } 块（DEBUG 画布）。
    text = re.sub(
        r'#Preview\s*(?:\(\s*"[^"]*"\s*\))?\s*\{',
        lambda m: m.group(0) + _match_braces(text[m.end():]) + "}",
        text,
    )
    return text


def _match_braces(fragment):
    """返回与 fragment 开头配平的 `{...}` 内部内容（不含外层花括号）。"""
    depth = 0
    in_string = False
    escape = False
    for idx, ch in enumerate(fragment):
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return fragment[:idx]
    return fragment


def _swift_source_hit_regex():
    names = SWIFT_PRESENTING_APIS + SWIFT_PRESENTING_MODIFIERS
    alt = "|".join(names)
    # 命名 API + 可选 verbatim 标签 + 首个字符串字面量（可含插值）。
    return re.compile(
        r'\b(?:%s)\(\s*(?:verbatim:\s*)?"((?:[^"\\]|\\.)*)"' % alt
    )


SWIFT_HIT_RE = _swift_source_hit_regex()


SWIFT_KEY_REF_RES_CACHE = {"patterns": None, "compiled": []}


def _swift_key_ref_res(patterns):
    if SWIFT_KEY_REF_RES_CACHE["patterns"] != patterns:
        SWIFT_KEY_REF_RES_CACHE["patterns"] = patterns
        SWIFT_KEY_REF_RES_CACHE["compiled"] = [re.compile(p) for p in patterns]
    return SWIFT_KEY_REF_RES_CACHE["compiled"]


SWIFT_UNESCAPE_RE = re.compile(r"\\(.)")


def _decode_swift_literal(literal):
    def _replace(match):
        ch = match.group(1)
        return {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(ch, "\\" + ch)
    return SWIFT_UNESCAPE_RE.sub(_replace, literal)


def check_key_naming(key, catalog_name, modules, purposes, code_whitelist):
    """返回错误消息或 None。Messages 键以消息清单为准（免用途词元约束）。"""
    segments = key.split(".")
    if len(segments) < 2:
        return "键至少需要 模块.场景 两段：%s" % key
    token_re = re.compile(r"^[a-z][a-z0-9_]*$")
    for seg in segments:
        if not token_re.match(seg):
            return "键词元必须是小写蛇形：%s" % key
    if segments[0] not in modules:
        return "键首词元不在受控模块清单中：%s" % key
    if catalog_name == "localizable" and len(segments) >= 3:
        if segments[-1] not in purposes:
            return "键末词元不在受控用途清单中：%s" % key
    if catalog_name == "localizable" and key in code_whitelist:
        return "Localizable 键不得使用 Rust/FFI message code（所有者唯一）：%s" % key
    return None


def load_catalog(path):
    """返回 (keys dict, issues)。keys: key -> {lang: [values]}。"""
    issues = []
    try:
        data = _load_json(path)
    except FileNotFoundError:
        return {}, [Issue(ISSUE_SEVERITY_ERROR, "MISSING_CATALOG", path, 0,
                          "catalog 文件缺失：%s" % path)]
    except CatalogError as exc:
        return {}, [Issue(ISSUE_SEVERITY_ERROR, "DUPLICATE_KEY", path, 0, str(exc))]
    except ValueError as exc:
        return {}, [Issue(ISSUE_SEVERITY_ERROR, "CATALOG_PARSE_ERROR", path, 0, str(exc))]
    keys = {}
    strings = data.get("strings") or {}
    for key, node in strings.items():
        entry = {}
        for lang, lang_node in (node.get("localizations") or {}).items():
            entry[lang] = _string_units(lang_node)
        keys[key] = entry
    return keys, issues


def check_catalog(name, keys, config, code_whitelist):
    issues = []
    path = config["catalogs"][name]
    modules = config.get("key_modules", DEFAULT_KEY_MODULES)
    purposes = config.get("key_purpose_tokens", DEFAULT_KEY_PURPOSE_TOKENS)
    if not keys:
        issues.append(Issue(ISSUE_SEVERITY_ERROR, "EMPTY_CATALOG", path, 0,
                            "catalog 没有任何资源键：%s" % path))
        return issues
    for key, langs in sorted(keys.items()):
        naming_error = check_key_naming(key, name, modules, purposes, code_whitelist)
        if naming_error:
            issues.append(Issue(ISSUE_SEVERITY_ERROR, "BAD_KEY_NAME", path, 0, naming_error))
        for lang in ("zh-Hans", "en"):
            if lang not in langs or not langs[lang]:
                issues.append(Issue(
                    ISSUE_SEVERITY_ERROR, "MISSING_TRANSLATION", path, 0,
                    "键 %s 缺少 %s 译文" % (key, lang)))
                continue
            for value in langs[lang]:
                if not value.strip():
                    issues.append(Issue(
                        ISSUE_SEVERITY_ERROR, "EMPTY_VALUE", path, 0,
                        "键 %s 的 %s 译文为空" % (key, lang)))
        if "zh-Hans" in langs and "en" in langs and langs["zh-Hans"] and langs["en"]:
            zh_classes = Counter()
            for v in langs["zh-Hans"]:
                zh_classes += _specifier_classes(v)
            en_classes = Counter()
            for v in langs["en"]:
                en_classes += _specifier_classes(v)
            if zh_classes != en_classes:
                issues.append(Issue(
                    ISSUE_SEVERITY_ERROR, "PARAM_MISMATCH", path, 0,
                    "键 %s 中英参数模式不一致：zh=%s en=%s" % (key, dict(zh_classes), dict(en_classes))))
    return issues


def load_exclusions(path):
    try:
        entries = _load_json(path)
    except FileNotFoundError:
        return [], []
    except ValueError as exc:
        return [], [Issue(ISSUE_SEVERITY_ERROR, "EXCLUSIONS_PARSE_ERROR", path, 0, str(exc))]
    return entries, []


def _resolve_file(root, rel):
    if os.path.isabs(rel):
        return rel
    return os.path.join(root, rel)


def _iter_source_files(source_dirs, exclude_paths):
    files = []
    for d in source_dirs:
        if os.path.isfile(d):
            files.append(d)
            continue
        for base, _dirs, names in os.walk(d):
            for name in names:
                if name.endswith(".swift") or name.endswith(".rs"):
                    files.append(os.path.join(base, name))
    def excluded(path):
        normalized = path.replace(os.sep, "/")
        for ex in exclude_paths:
            exn = ex.replace(os.sep, "/")
            if normalized == exn or normalized.startswith(exn.rstrip("/") + "/"):
                return True
        return False
    return [f for f in sorted(set(files)) if not excluded(f)]


def validate_exclusion_entries(entries, root, exclude_paths):
    issues = []
    for entry in entries:
        reason = entry.get("reason", "")
        note = entry.get("note", "")
        content = entry.get("content", "")
        file_rel = entry.get("file", "")
        if reason not in EXCLUSION_REASONS:
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "INVALID_EXCLUSION", file_rel, 0,
                "排除项 %s 使用了未登记的排除原因：%r（合法值：%s）"
                % (entry.get("id", "?"), reason, sorted(EXCLUSION_REASONS))))
            continue
        if _has_cjk(content) and reason in CJK_FREE_EXCLUSION_REASONS:
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "INVALID_EXCLUSION", file_rel, 0,
                "排除项 %s：中文文案只可能是程序自写包装说明，不得以依赖/诊断原文为由排除（%s）"
                % (entry.get("id", "?"), reason)))
            continue
        if not note.strip():
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "INVALID_EXCLUSION", file_rel, 0,
                "排除项 %s 缺少可审查的用途说明（note）" % entry.get("id", "?")))
            continue
        if content == "*":
            continue  # 整文件排除（DEBUG/生成物），仍须有 reason+note。
        path = _resolve_file(root, file_rel)
        if not os.path.isfile(path):
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "STALE_EXCLUSION", file_rel, 0,
                "排除项 %s 指向不存在的文件" % entry.get("id", "?")))
            continue
        with open(path, "r", encoding="utf-8") as f:
            body = f.read()
        if content not in body:
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "STALE_EXCLUSION", file_rel, 0,
                "排除项 %s 的目标内容已不存在（排除已过期，应删除）：%r"
                % (entry.get("id", "?"), content[:60])))
    return issues


def _hit_is_excluded(hit_snippet, hit_literal, hit_file, entries):
    for entry in entries:
        reason = entry.get("reason", "")
        if reason not in EXCLUSION_REASONS:
            continue  # 无效排除不产生任何豁免效果。
        if _has_cjk(entry.get("content", "")) and reason in CJK_FREE_EXCLUSION_REASONS:
            continue
        content = entry.get("content", "")
        if content == "*":
            continue
        if entry.get("file", "") != hit_file:
            continue
        if content and (content in hit_snippet or content in hit_literal):
            return True
    return False


def scan_swift(config, root, exclusions, all_catalog_keys):
    issues = []
    files = _iter_source_files(
        [_resolve_file(root, d) for d in config.get("swift_sources", [])],
        config.get("exclude_paths", []))
    hit_re = SWIFT_HIT_RE
    key_ref_res = _swift_key_ref_res(config.get("swift_approved_patterns", []))
    all_keys = set()
    for keys in all_catalog_keys.values():
        all_keys.update(keys.keys())
    for path in files:
        with open(path, "r", encoding="utf-8") as f:
            source = _swift_strip_comments_and_previews(f.read())
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        for match in hit_re.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            snippet = match.group(0)
            literal = _decode_swift_literal(match.group(1))
            if _hit_is_excluded(snippet, literal, rel, exclusions):
                continue
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "SWIFT_HARDCODE", rel, line,
                "提示出口存在硬编码文案（须经资源入口取值）：%r" % literal[:80]))
        for key_ref_re in key_ref_res:
            for match in key_ref_re.finditer(source):
                line = source.count("\n", 0, match.start()) + 1
                key = match.group(1)
                if key not in all_keys:
                    issues.append(Issue(
                        ISSUE_SEVERITY_ERROR, "UNKNOWN_RESOURCE_KEY", rel, line,
                        "资源键未在任何 catalog 中登记：%s" % key))
    return issues


def load_messages(path):
    try:
        entries = _load_json(path)
    except FileNotFoundError:
        return None, [Issue(ISSUE_SEVERITY_ERROR, "MISSING_MESSAGES_LIST", path, 0,
                            "声明式消息清单缺失：%s" % path)]
    except ValueError as exc:
        return None, [Issue(ISSUE_SEVERITY_ERROR, "MESSAGES_PARSE_ERROR", path, 0, str(exc))]
    return entries, []


def check_messages(entries, messages_catalog_keys, config, root):
    issues = []
    catalog_path = config["catalogs"]["messages"]
    code_by_key = {}
    for entry in entries:
        code = entry.get("code", "")
        if not re.match(r"^[a-z][a-z0-9_.]*$", code):
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "BAD_KEY_NAME", config["messages"], 0,
                "消息 code 必须是小写点分语义键：%r" % code))
            continue
        if code in code_by_key:
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "MESSAGES_CATALOG_DRIFT", config["messages"], 0,
                "消息清单中 code 重复：%s" % code))
        code_by_key[code] = entry
    for code in sorted(set(code_by_key) | set(messages_catalog_keys)):
        if code in code_by_key and code not in messages_catalog_keys:
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "MESSAGES_CATALOG_DRIFT", catalog_path, 0,
                "消息清单中的 code 缺少 Messages catalog 资源：%s" % code))
        elif code in messages_catalog_keys and code not in code_by_key:
            issues.append(Issue(
                ISSUE_SEVERITY_ERROR, "MESSAGES_CATALOG_DRIFT", catalog_path, 0,
                "Messages catalog 存在消息清单未声明的 code：%s" % code))
    return issues, code_by_key


def scan_rust(config, root, exclusions, code_by_key):
    issues = []
    if code_by_key is None:
        return issues
    legacy_by_text = {}
    for code, entry in code_by_key.items():
        legacy = entry.get("legacy_wire_text")
        if legacy:
            legacy_by_text[legacy] = code
    files = _iter_source_files(
        [_resolve_file(root, d) for d in config.get("rust_sources", [])],
        config.get("exclude_paths", []))
    for path in files:
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        stripped = re.sub(r"//[^\n]*", "", source)
        for label, pattern in RUST_LITERAL_PATTERNS:
            for match in pattern.finditer(stripped):
                line = source.count("\n", 0, match.start()) + 1
                literal = match.group(1)
                if literal in legacy_by_text:
                    continue
                snippet = match.group(0)
                if _hit_is_excluded(snippet, literal, rel, exclusions):
                    continue
                issues.append(Issue(
                    ISSUE_SEVERITY_ERROR, "RUST_LITERAL_UNREGISTERED", rel, line,
                    "Rust 程序文案（%s）未登记到消息清单：%r" % (label, literal[:80])))
    return issues


def run_audit(config):
    root = config.get("root", os.getcwd())
    config = dict(config)
    config["exclude_paths"] = [_resolve_file(root, p) for p in config.get("exclude_paths", [])]
    issues = []
    localizable, issues_a = load_catalog(_resolve_file(root, config["catalogs"]["localizable"]))
    messages_cat, issues_b = load_catalog(_resolve_file(root, config["catalogs"]["messages"]))
    issues.extend(issues_a)
    issues.extend(issues_b)

    exclusions, issues_c = load_exclusions(_resolve_file(root, config["exclusions"]))
    issues.extend(issues_c)

    messages_entries, issues_d = load_messages(_resolve_file(root, config["messages"]))
    issues.extend(issues_d)

    code_whitelist = set()
    if messages_entries is not None:
        code_whitelist = {e.get("code", "") for e in messages_entries}

    # catalog 文件缺失/损坏时不再叠加逐键检查。
    if not issues_a:
        issues.extend(check_catalog("localizable", localizable, config, code_whitelist))
    if not issues_b:
        issues.extend(check_catalog("messages", messages_cat, config, code_whitelist))

    # 所有者唯一性：同一键不得同时出现在两个 catalog；Localizable 不得使用 message code。
    for key in sorted(set(localizable) & set(messages_cat)):
        issues.append(Issue(
            ISSUE_SEVERITY_ERROR, "OWNER_VIOLATION",
            config["catalogs"]["localizable"], 0,
            "键 %s 同时出现在 Localizable 与 Messages，违反唯一所有者规则" % key))

    if messages_entries is not None:
        messages_issues, code_by_key = check_messages(
            messages_entries, set(messages_cat.keys()), config, root)
        issues.extend(messages_issues)
    else:
        code_by_key = None

    issues.extend(validate_exclusion_entries(exclusions, root, config.get("exclude_paths", [])))
    issues.extend(scan_swift(config, root, exclusions,
                             {"localizable": localizable, "messages": messages_cat}))
    issues.extend(scan_rust(config, root, exclusions, code_by_key))

    issues.sort(key=lambda i: (i.file, i.line, i.code))
    return AuditReport(issues=issues)


def audit_exit_code(report):
    return 1 if any(i.severity == ISSUE_SEVERITY_ERROR for i in report.issues) else 0


def _repo_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main(argv):
    config_path = argv[1] if len(argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "audit-config.json")
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
    config.setdefault("root", _repo_root())
    report = run_audit(config)
    for issue in report.issues:
        print("[%s] %s: %s:%s %s" % (
            issue.severity, issue.code, issue.file, issue.line, issue.message))
    print("共 %d 个问题" % len(report.issues))
    return audit_exit_code(report)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
