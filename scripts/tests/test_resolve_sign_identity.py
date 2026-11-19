#!/usr/bin/env python3
"""Issue #121: 构建脚本的代码签名身份解析（TCC 授权稳定性）。

这里的断言只覆盖**对外可观察行为**：`scripts/resolve-sign-identity.sh` 的
标准输出、退出码、标准错误，以及两个构建入口是否还把 ad-hoc 身份写死。

背景：ad-hoc 签名（`codesign --sign -`）的 designated requirement 是 cdhash，
每次重新构建都变，macOS 会把屏幕录制等 TCC 授权判成「另一个 App」而作废。
带证书签名后 requirement 变成 `identifier ... and certificate leaf = H"..."`，
证书不变 → 重建后授权继续有效。所以构建脚本必须允许指定固定身份，且**在指定
的身份不可用时大声失败**——静默回退 ad-hoc 等于悄悄退回这个 bug。

运行：python3 scripts/tests/test_resolve_sign_identity.py
"""

from __future__ import annotations

import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts" / "resolve-sign-identity.sh"
ENV_VAR = "CMUX_DEV_SIGN_IDENTITY"
_UNSET = object()


def run_resolver(identity=_UNSET):
    """按需注入 CMUX_DEV_SIGN_IDENTITY 后运行解析脚本。"""
    env = dict(os.environ)
    env.pop(ENV_VAR, None)
    if identity is not _UNSET:
        env[ENV_VAR] = identity
    return subprocess.run(
        [str(RESOLVER)],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def first_available_identity():
    """当前机器上第一个可用的代码签名身份（没有则返回 None）。"""
    try:
        proc = subprocess.run(
            ["security", "find-identity", "-v", "-p", "codesigning"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        match = re.search(r'"(.+)"', line)
        if match:
            return match.group(1)
    return None


class ResolveSignIdentityTests(unittest.TestCase):
    def test_default_is_adhoc(self):
        """未设置环境变量 → 输出 `-`，保持别人的环境行为不变。"""
        proc = run_resolver()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "-")

    def test_explicit_adhoc_passes_through(self):
        """显式设置为 `-` → 仍然输出 `-`（明确要求 ad-hoc 也允许）。"""
        proc = run_resolver("-")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "-")

    def test_blank_value_falls_back_to_default(self):
        """空白值当作未设置，输出 `-`。"""
        proc = run_resolver("   ")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "-")

    def test_adhoc_note_mentions_tcc(self):
        """ad-hoc 时必须提示 TCC 授权会随重建失效。"""
        proc = run_resolver()
        stderr = proc.stderr.lower()
        self.assertIn("ad-hoc", stderr)
        self.assertIn("tcc", stderr)

    def test_unknown_identity_fails_loudly(self):
        """指定了不存在的身份 → 非零退出，绝不静默回退 ad-hoc。"""
        missing = "cmux-nonexistent-signing-identity-for-tests"
        proc = run_resolver(missing)
        self.assertNotEqual(proc.returncode, 0, "不存在的身份必须以失败退出")
        self.assertEqual(proc.stdout.strip(), "", "失败时不应输出任何身份")
        self.assertIn(missing, proc.stderr)
        self.assertIn(ENV_VAR, proc.stderr, "报错要指出是哪个环境变量配错了")

    def test_available_identity_is_resolved(self):
        """机器上有可用身份时，指定的名字要原样解析出来（没有则跳过）。"""
        identity = first_available_identity()
        if not identity:
            self.skipTest("本机没有可用的代码签名身份")
        proc = run_resolver(identity)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), identity)


class BuildScriptsUseResolverTests(unittest.TestCase):
    """两个构建入口都必须走统一解析，不允许把 ad-hoc 身份写死。"""

    ENTRY_POINTS = ("reload.sh", "reloads.sh")
    ADHOC_LITERAL = re.compile(r"--sign\s+-(\s|$)")

    def test_entry_points_delegate_to_resolver(self):
        for name in self.ENTRY_POINTS:
            text = (ROOT / "scripts" / name).read_text(encoding="utf-8")
            self.assertIn(
                "resolve-sign-identity.sh",
                text,
                f"{name} 必须通过 scripts/resolve-sign-identity.sh 解析签名身份",
            )

    def test_entry_points_do_not_hardcode_adhoc(self):
        for name in self.ENTRY_POINTS:
            text = (ROOT / "scripts" / name).read_text(encoding="utf-8")
            self.assertIsNone(
                self.ADHOC_LITERAL.search(text),
                f"{name} 里仍有写死的 `--sign -`，会把 TCC 授权打回 cdhash",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
