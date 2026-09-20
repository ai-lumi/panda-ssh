#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""资源审计工具的单元测试（OpenSpec 变更 add-app-internationalization 任务 1.3）。

覆盖：正常双语资源、意外漏译/硬编码中英文/错误排除、
边界空表/重复键/动态拼接，以及「程序包装说明不得被依赖错误排除项吞掉」的夹具验证。
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import audit  # noqa: E402


def write(tmp, rel, content):
    path = os.path.join(tmp, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def make_config(tmp, **overrides):
    cfg = {
        "root": tmp,
        "catalogs": {
            "localizable": os.path.join(tmp, "Resources/Localizable.xcstrings"),
            "messages": os.path.join(tmp, "Resources/Messages.xcstrings"),
        },
        "swift_sources": [os.path.join(tmp, "Sources")],
        "rust_sources": [os.path.join(tmp, "crates")],
        "exclusions": os.path.join(tmp, "exclusions.json"),
        "messages": os.path.join(tmp, "messages.json"),
        "exclude_paths": [],
        "swift_approved_patterns": [r'\bl10n\.(?:str|text|count)\(\s*"([a-z0-9_.]+)"'],
        "rust_approved_patterns": [r"\bmsg_code\("],
    }
    cfg.update(overrides)
    return cfg


def base_catalog(keys):
    """构造最小合法 xcstrings 结构。"""
    strings = {}
    for key, zh, en in keys:
        strings[key] = {
            "localizations": {
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
                "en": {"stringUnit": {"state": "translated", "value": en}},
            }
        }
    return {"sourceLanguage": "zh-Hans", "strings": strings}


def issue_codes(report):
    return {i.code for i in report.issues}


# 一条合法的 Rust 消息，供各夹具复用，保证 Messages catalog 与消息清单一致。
BASE_MESSAGE = {"code": "error.config_read_failed",
                "legacy_wire_text": "读取配置失败",
                "params": []}


def seed_messages_catalog():
    cat = base_catalog([("error.config_read_failed", "读取配置失败", "Failed to read configuration")])
    return json.dumps(cat, ensure_ascii=False)


class CatalogCompletenessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_complete_bilingual_catalog_has_no_issues(self):
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(
            base_catalog([("app.action.cancel", "取消", "Cancel"),
                          ("settings.title", "设置", "Settings")]),
            ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", seed_messages_catalog())
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", json.dumps([BASE_MESSAGE], ensure_ascii=False))
        report = audit.run_audit(make_config(self.tmp))
        catalog_issues = [i for i in report.issues if i.code.startswith(("MISSING", "EMPTY", "PARAM", "DUPLICATE", "OWNER"))]
        self.assertEqual(catalog_issues, [])

    def test_missing_translation_is_reported(self):
        cat = base_catalog([("app.action.cancel", "取消", "Cancel")])
        del cat["strings"]["app.action.cancel"]["localizations"]["en"]
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(cat, ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("MISSING_TRANSLATION", issue_codes(report))

    def test_empty_value_is_reported(self):
        cat = base_catalog([("app.action.cancel", "取消", "")])
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(cat, ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("EMPTY_VALUE", issue_codes(report))

    def test_empty_table_is_reported(self):
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("EMPTY_CATALOG", issue_codes(report))

    def test_duplicate_key_is_reported(self):
        entry = ('"app.action.cancel":{'
                 '"localizations":{'
                 '"zh-Hans":{"stringUnit":{"state":"translated","value":"取消"}},'
                 '"en":{"stringUnit":{"state":"translated","value":"Cancel"}}}}')
        dup = '{"sourceLanguage":"zh-Hans","strings":{' + entry + "," + entry + "}}"
        write(self.tmp, "Resources/Localizable.xcstrings", dup)
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("DUPLICATE_KEY", issue_codes(report))

    def test_param_pattern_drift_is_reported(self):
        cat = base_catalog([("transfer.files.count", "共 %lld 个文件", "%lld file(s) %lld")])
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(cat, ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("PARAM_MISMATCH", issue_codes(report))

    def test_param_order_may_differ_between_languages(self):
        cat = base_catalog([("host.tofu.detail", "%1$@（%2$@:%3$@）", "%1$@ (%3$@:%2$@) next")])
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(cat, ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")
        report = audit.run_audit(make_config(self.tmp))
        self.assertNotIn("PARAM_MISMATCH", issue_codes(report))


class KeyNamingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def seed(self, keys, messages="[]"):
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(
            base_catalog([(k, "中", "en") for k in keys]), ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", messages)

    def test_valid_key_passes(self):
        self.seed(["settings.language.title", "host.delete.confirm.count", "error.auth_failed.detail"])
        report = audit.run_audit(make_config(self.tmp))
        self.assertNotIn("BAD_KEY_NAME", issue_codes(report))

    def test_chinese_display_text_as_key_fails(self):
        self.seed(["取消"])
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("BAD_KEY_NAME", issue_codes(report))

    def test_unknown_module_token_fails(self):
        self.seed(["foo.bar.title"])
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("BAD_KEY_NAME", issue_codes(report))

    def test_unknown_purpose_token_fails(self):
        self.seed(["settings.language.banana"])
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("BAD_KEY_NAME", issue_codes(report))

    def test_uppercase_token_fails(self):
        self.seed(["Settings.language.title"])
        report = audit.run_audit(make_config(self.tmp))
        self.assertIn("BAD_KEY_NAME", issue_codes(report))


class SwiftHardcodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(
            base_catalog([("settings.language.title", "语言", "Language")]), ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")
        write(self.tmp, "messages.json", "[]")

    def run_scan(self, swift):
        write(self.tmp, "Sources/View.swift", swift)
        return audit.run_audit(make_config(self.tmp))

    def test_hardcoded_chinese_text_is_reported(self):
        report = self.run_scan('var body: some View { Text("取消") }')
        self.assertIn("SWIFT_HARDCODE", issue_codes(report))

    def test_hardcoded_english_text_is_reported(self):
        report = self.run_scan('var body: some View { Button("Delete") {} }')
        self.assertIn("SWIFT_HARDCODE", issue_codes(report))

    def test_dynamic_concat_is_reported(self):
        report = self.run_scan('var body: some View { Text("已连接 \\(count) 台设备") }')
        self.assertIn("SWIFT_HARDCODE", issue_codes(report))

    def test_approved_key_reference_passes(self):
        report = self.run_scan('var body: some View { Text(l10n.str("settings.language.title")) }')
        self.assertNotIn("SWIFT_HARDCODE", issue_codes(report))

    def test_approved_key_with_unknown_key_is_reported(self):
        report = self.run_scan('var body: some View { Text(l10n.str("settings.banana.title")) }')
        self.assertIn("UNKNOWN_RESOURCE_KEY", issue_codes(report))

    def test_variable_argument_passes(self):
        report = self.run_scan('var body: some View { Text(model.userName) }')
        self.assertNotIn("SWIFT_HARDCODE", issue_codes(report))

    def test_excluded_literal_passes(self):
        excl = [{"id": "brand", "file": "Sources/View.swift",
                 'content': 'Panda SSH',
                 "reason": "brand_or_contract", "note": "品牌名不翻译"}]
        write(self.tmp, "exclusions.json", json.dumps(excl, ensure_ascii=False))
        report = self.run_scan('var body: some View { Text(verbatim: "Panda SSH") }')
        self.assertNotIn("SWIFT_HARDCODE", issue_codes(report))


class ExclusionValidationTests(unittest.TestCase):
    """夹具：程序包装说明不得被依赖错误排除项吞掉。"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(
            base_catalog([("app.action.cancel", "取消", "Cancel")]), ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(base_catalog([]), ensure_ascii=False))
        write(self.tmp, "messages.json", "[]")
        self.rust = '#[derive(Error)]\n#[error("读取配置失败: {0}")]\nConfigRead(String),\n'
        write(self.tmp, "crates/core/src/lib.rs", self.rust)

    def run_scan(self, exclusions):
        write(self.tmp, "exclusions.json", json.dumps(exclusions, ensure_ascii=False))
        return audit.run_audit(make_config(self.tmp))

    def test_chinese_wrapping_cannot_be_excluded_as_dependency_error(self):
        excl = [{"id": "cfg", "file": "crates/core/src/lib.rs",
                 "content": "读取配置失败",
                 "reason": "raw_dependency_diagnostic", "note": "误标为依赖错误"}]
        report = self.run_scan(excl)
        self.assertIn("INVALID_EXCLUSION", issue_codes(report))
        self.assertIn("RUST_LITERAL_UNREGISTERED", issue_codes(report))

    def test_stale_exclusion_is_reported(self):
        excl = [{"id": "gone", "file": "crates/core/src/lib.rs",
                 "content": "已经不存在的文案",
                 "reason": "brand_or_contract", "note": "过期排除"}]
        report = self.run_scan(excl)
        self.assertIn("STALE_EXCLUSION", issue_codes(report))

    def test_unknown_reason_is_reported(self):
        excl = [{"id": "bad", "file": "crates/core/src/lib.rs",
                 "content": "读取配置失败",
                 "reason": "看起来像依赖错误", "note": "非法原因"}]
        report = self.run_scan(excl)
        self.assertIn("INVALID_EXCLUSION", issue_codes(report))


class RustMessageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(
            base_catalog([("app.action.cancel", "取消", "Cancel")]), ensure_ascii=False))
        write(self.tmp, "Resources/Messages.xcstrings", json.dumps(
            base_catalog([("error.config_read_failed", "读取配置失败", "Failed to read configuration")]),
            ensure_ascii=False))
        write(self.tmp, "exclusions.json", "[]")

    def run_scan(self, rust, messages):
        write(self.tmp, "crates/core/src/lib.rs", rust)
        write(self.tmp, "messages.json", json.dumps(messages, ensure_ascii=False))
        return audit.run_audit(make_config(self.tmp))

    def test_registered_rust_literal_passes(self):
        rust = '#[error("读取配置失败")]\nConfigRead,'
        messages = [{"code": "error.config_read_failed", "legacy_wire_text": "读取配置失败", "params": []}]
        report = self.run_scan(rust, messages)
        rust_issues = [i for i in report.issues if i.code.startswith("RUST")]
        self.assertEqual(rust_issues, [])

    def test_unregistered_rust_literal_is_reported(self):
        rust = '#[error("读取配置失败")]\nConfigRead,'
        report = self.run_scan(rust, [])
        self.assertIn("RUST_LITERAL_UNREGISTERED", issue_codes(report))

    def test_legacy_text_drift_is_reported(self):
        rust = '#[error("读取配置失败")]\nConfigRead,'
        messages = [{"code": "error.config_read_failed", "legacy_wire_text": "别的文本", "params": []}]
        report = self.run_scan(rust, messages)
        self.assertIn("RUST_LITERAL_UNREGISTERED", issue_codes(report))

    def test_message_code_missing_from_messages_catalog_is_reported(self):
        rust = '#[error("读取配置失败")]\nConfigRead,'
        messages = [{"code": "error.other_thing", "legacy_wire_text": "x", "params": []}]
        report = self.run_scan(rust, messages)
        self.assertIn("MESSAGES_CATALOG_DRIFT", issue_codes(report))

    def test_messages_key_in_localizable_is_owner_violation(self):
        cat = base_catalog([("error.config_read_failed", "读取配置失败", "Failed to read configuration")])
        write(self.tmp, "Resources/Localizable.xcstrings", json.dumps(cat, ensure_ascii=False))
        report = self.run_scan('', [])
        self.assertIn("OWNER_VIOLATION", issue_codes(report))


class ExitCodeTests(unittest.TestCase):
    def test_exit_code_reflects_errors(self):
        clean = audit.AuditReport(issues=[])
        failing = audit.AuditReport(issues=[audit.Issue("error", "SWIFT_HARDCODE", "a.swift", 1, "x")])
        self.assertEqual(audit.audit_exit_code(clean), 0)
        self.assertEqual(audit.audit_exit_code(failing), 1)


if __name__ == "__main__":
    unittest.main()
