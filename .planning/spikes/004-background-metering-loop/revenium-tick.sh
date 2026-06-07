#!/usr/bin/env bash
# Spike 004: host-side metering tick. A host crontab runs this every minute.
# It performs a bounded `nemoclaw exec` one-shot that refreshes the in-sandbox
# guardrail-status.json the OpenClaw agent reads. (No in-sandbox daemon needed —
# exec is synchronous, so per-tick exec is the right model.)
export PATH="/home/ubuntu/.local/bin:$PATH"
TS=$(date +%s)
N=$(( $(cat /tmp/revenium-tick.count 2>/dev/null || echo 0) + 1 ))
echo "$N" > /tmp/revenium-tick.count
# In the real skill this is where cron.sh would meter usage + read Revenium guardrails.
# Here we just write a valid status doc with a fresh timestamp to prove the loop mechanic.
nemoclaw revenium-spike exec --timeout 40 -- sh -lc \
  "mkdir -p /sandbox/.openclaw/skills/revenium; printf '{\"halted\":false,\"warned\":false,\"updatedAt\":%s,\"_tick\":%s}\n' $TS $N > /sandbox/.openclaw/skills/revenium/guardrail-status.json" \
  >/tmp/revenium-tick.log 2>&1
echo "tick=$N ts=$TS rc=$?" >> /tmp/revenium-tick.history
