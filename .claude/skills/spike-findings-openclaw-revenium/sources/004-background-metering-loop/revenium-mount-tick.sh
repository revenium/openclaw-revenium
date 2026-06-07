#!/usr/bin/env bash
# Spike 004 (recommended model): host cron tick. Reads sandbox state via the
# SSHFS share-mount and writes guardrail-status.json back through it — no
# `nemoclaw exec`, no in-sandbox daemon, no per-call plugin re-init.
# In the real skill, this is where cron.sh would read OpenClaw session logs from
# ~/sbx-openclaw/... and meter via the host revenium CLI (host has open egress).
MNT="$HOME/sbx-openclaw"
[ -d "$MNT/skills" ] || exit 3   # mount gone -> let cron log a failure
N=$(( $(cat /tmp/rev-mt.count 2>/dev/null || echo 0) + 1 )); echo "$N" > /tmp/rev-mt.count
mkdir -p "$MNT/skills/revenium"
printf '{"halted":false,"warned":false,"updatedAt":%s,"_tick":%s,"_via":"host-mount-cron"}\n' "$(date +%s)" "$N" > "$MNT/skills/revenium/guardrail-status.json"
echo "$(date -u +%FT%TZ) tick=$N rc=$?" >> /tmp/rev-mt.history
