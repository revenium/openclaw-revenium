"""Path validation for the sidecar's stage context.

The cron shim already refuses unsafe directories before it launches Python.
This module checks them again from inside the interpreter, so a direct or
mis-wired launch cannot make the sidecar write where the agent can read or
tamper:

- the state dir must be owned by the current user, carry no group or other
  permission bits, and resolve outside OPENCLAW_HOME;
- the runtime dir must be owned by the current user, not group- or
  other-writable, and resolve outside OPENCLAW_HOME;
- the skill dir must contain scripts/session-store.sh as a regular file;
- the stage budget must be at least one second.

Every check resolves symlinks first, so a link outside OPENCLAW_HOME that
points inside it is refused. build_context raises UnsafePathError, whose
``code`` is a short fixed string that is safe to log.
"""
from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from typing import Any


class UnsafePathError(Exception):
    """A stage path failed validation. ``code`` names the failed check."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class Context:
    state_dir: str
    openclaw_home: str
    skill_dir: str
    runtime_dir: str
    store_script: str
    budget_seconds: int


def real_dir(path: str) -> str:
    """Return the resolved path of an existing directory, or raise."""
    if not path:
        raise UnsafePathError("missing_path")
    resolved = os.path.realpath(path)
    if not os.path.isdir(resolved):
        raise UnsafePathError("not_a_directory")
    return resolved


def is_under(child: str, parent: str) -> bool:
    """True when ``child`` resolves to ``parent`` or somewhere beneath it.

    A parent that resolves to the filesystem root contains everything, so it
    counts as under and callers refuse it.
    """
    child_r = os.path.realpath(child)
    parent_r = os.path.realpath(parent)
    if parent_r == os.sep:
        return True
    return child_r == parent_r or child_r.startswith(parent_r + os.sep)


def check_private_dir(path: str) -> bool:
    """True when ``path`` is owned by the current user with no group/other bits."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    if not stat.S_ISDIR(st.st_mode):
        return False
    return st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) & 0o077 == 0


def check_not_shared_writable(path: str) -> bool:
    """True when ``path`` is owned by the current user and only it can write."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    if not stat.S_ISDIR(st.st_mode):
        return False
    return st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) & 0o022 == 0


def build_context(args: Any) -> Context:
    """Validate the launcher arguments and return the stage Context."""
    openclaw_home = real_dir(args.openclaw_home)
    state_dir = real_dir(args.state_dir)
    runtime_dir = real_dir(args.runtime_dir)
    skill_dir = real_dir(args.skill_dir)

    if not check_private_dir(state_dir):
        raise UnsafePathError("state_dir_not_private")
    if is_under(state_dir, openclaw_home):
        raise UnsafePathError("state_dir_in_openclaw_home")
    if not check_not_shared_writable(runtime_dir):
        raise UnsafePathError("runtime_dir_shared_writable")
    if is_under(runtime_dir, openclaw_home):
        raise UnsafePathError("runtime_dir_in_openclaw_home")

    store_script = os.path.join(skill_dir, "scripts", "session-store.sh")
    try:
        st = os.lstat(store_script)
    except OSError:
        raise UnsafePathError("store_script_missing") from None
    if not stat.S_ISREG(st.st_mode):
        raise UnsafePathError("store_script_missing")

    budget = args.budget_seconds
    if not isinstance(budget, int) or budget < 1:
        raise UnsafePathError("budget_too_small")

    return Context(
        state_dir=state_dir,
        openclaw_home=openclaw_home,
        skill_dir=skill_dir,
        runtime_dir=runtime_dir,
        store_script=store_script,
        budget_seconds=budget,
    )
