#!/usr/bin/env python3
"""Issue #136: 文件编辑器的自动保存设置必须同时被配置 schema 与设置目录接受。

背景：`fileEditor.*` 的键由 `FileEditorCatalogSection` 定义，但 `cmux.json` 的
合法性由 `schemas/config/cmux.schema.json` 判定（`additionalProperties: false`）。
只在目录里加键、忘了改 schema，用户写进 cmux.json 会被判非法；只改 schema、
忘了改目录，设置页与读取代码读不到这个键。两边必须成对出现，而且**默认值与
范围必须一致**（目录所有者是唯一权威，schema 跟着它走）。

运行：python3 scripts/tests/test_file_editor_autosave_schema.py
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "schemas" / "config" / "cmux.schema.json"
CATALOG = (
    ROOT
    / "Packages"
    / "macOS"
    / "CmuxSettings"
    / "Sources"
    / "CmuxSettings"
    / "Keys"
    / "FileEditorCatalogSection.swift"
)

# 目录里的声明形状：`supportedAutoSaveDelayRange: ClosedRange<Int> = 200...5000`
RANGE_PATTERN = re.compile(
    r"supportedAutoSaveDelayRange[^=\n]*=\s*(\d+)\s*\.\.\.\s*(\d+)"
)
# 键声明：`id: "fileEditor.autoSaveDelay", defaultValue: 600`
DELAY_DEFAULT_PATTERN = re.compile(
    r'id:\s*"fileEditor\.autoSaveDelay",\s*defaultValue:\s*(\d+)',
    re.DOTALL,
)
ENABLED_DEFAULT_PATTERN = re.compile(
    r'id:\s*"fileEditor\.autoSave",\s*defaultValue:\s*(true|false)',
    re.DOTALL,
)


class FileEditorAutoSaveSchemaTests(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.catalog_text = CATALOG.read_text(encoding="utf-8")
        self.file_editor = self.schema["properties"]["fileEditor"]

    def test_file_editor_section_rejects_unknown_keys(self):
        # 这条是「新增键必须同时改 schema」的前提：未知键会被直接判非法，
        # 而不是静默忽略。
        self.assertIs(
            self.file_editor.get("additionalProperties"),
            False,
            "fileEditor 段必须保持 additionalProperties: false",
        )

    def test_auto_save_key_is_a_boolean_that_defaults_on(self):
        auto_save = self.file_editor["properties"].get("autoSave")
        self.assertIsNotNone(auto_save, "schema 缺少 fileEditor.autoSave")
        self.assertEqual(auto_save.get("type"), "boolean")
        self.assertIs(auto_save.get("default"), True)
        self.assertEqual(
            auto_save.get("descriptionKey"),
            "schemaDescriptions.fileEditor.autoSave",
            "新键需要自己的本地化描述键",
        )

    def test_auto_save_delay_key_carries_its_bounds(self):
        delay = self.file_editor["properties"].get("autoSaveDelay")
        self.assertIsNotNone(delay, "schema 缺少 fileEditor.autoSaveDelay")
        self.assertEqual(delay.get("type"), "integer")
        self.assertEqual(delay.get("default"), 600)
        self.assertEqual(delay.get("minimum"), 200)
        self.assertEqual(delay.get("maximum"), 5000)
        self.assertEqual(
            delay.get("descriptionKey"),
            "schemaDescriptions.fileEditor.autoSaveDelay",
        )

    def test_catalog_default_and_bounds_match_the_schema(self):
        # 目录是默认值与范围的唯一权威；schema 抄它。形状变了就让测试报错、
        # 而不是悄悄放过——放宽断言等于把这里最想防的漂移放回来。
        range_match = RANGE_PATTERN.search(self.catalog_text)
        self.assertIsNotNone(
            range_match,
            "FileEditorCatalogSection 里找不到 supportedAutoSaveDelayRange 的声明；"
            "若改了声明形状，请同步更新本测试的解析规则，不要删除比对",
        )
        delay_match = DELAY_DEFAULT_PATTERN.search(self.catalog_text)
        self.assertIsNotNone(
            delay_match,
            "FileEditorCatalogSection 里找不到 fileEditor.autoSaveDelay 的 defaultValue 声明；"
            "若改了声明形状，请同步更新本测试的解析规则，不要删除比对",
        )
        enabled_match = ENABLED_DEFAULT_PATTERN.search(self.catalog_text)
        self.assertIsNotNone(
            enabled_match,
            "FileEditorCatalogSection 里找不到 fileEditor.autoSave 的 defaultValue 声明；"
            "若改了声明形状，请同步更新本测试的解析规则，不要删除比对",
        )

        catalog_lower, catalog_upper = (int(value) for value in range_match.groups())
        delay_schema = self.file_editor["properties"]["autoSaveDelay"]
        enabled_schema = self.file_editor["properties"]["autoSave"]

        self.assertEqual(catalog_lower, delay_schema["minimum"])
        self.assertEqual(catalog_upper, delay_schema["maximum"])
        self.assertEqual(int(delay_match.group(1)), delay_schema["default"])
        self.assertEqual(
            enabled_match.group(1) == "true",
            enabled_schema["default"],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
