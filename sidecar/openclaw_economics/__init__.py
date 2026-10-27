"""OpenClaw host adapter for the revenium-agent-economics library.

The package turns OpenClaw session state into input for the library and keeps
the sidecar's own bookkeeping (path validation, status files, the revenium CLI
capability probe and redaction) out of the library. Standard library only, so
it imports on any Python 3.11+ interpreter without extra packages.
"""
from __future__ import annotations

STATUS_SCHEMA = 1
