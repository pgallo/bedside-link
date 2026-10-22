#!/usr/bin/env bash
# Runs the demo binary against the recorded streams and checks its output.
set -euo pipefail

bin="${1:?usage: demo_smoke.sh <bedsidelink binary> <data dir>}"
data="${2:?usage: demo_smoke.sh <bedsidelink binary> <data dir>}"

out="$("$bin" --data "$data")"

expect() {
  if ! grep -qF -- "$1" <<<"$out"; then
    echo "demo smoke: expected output not found: $1" >&2
    exit 1
  fi
}

expect "Not a medical device."
expect "3 channels"
expect "MSH|^~\\&|BEDSIDELINK|"
expect "ORU^R01^ORU_R01"
expect "ALARM RAISED  BED01  SPO2  high   low"
expect "ALARM LATCHED BED02  INF_OCCL"
expect "Heparin 25000 U \\T\\ NaCl 0.9%\\S\\50 mL"
expect "Summary: 76 HL7 messages, 12 alarm transitions, 10 frames rejected"

echo "demo smoke: OK"
