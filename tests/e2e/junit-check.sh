#!/usr/bin/env bash
# Fails on a skipped check in the bats JUnit reports in $1 unless its
# reason is expected for this run. A skip is a check that proved nothing,
# so CI may not pass on one by accident (a missing tool, a changed setup).
#
# Expected, by the run's own settings:
#   "not an upgrade run ..."           UPGRADE_FROM is unset
#   "IPv6 checks need IPV6=1 ..."      IPV6 is not 1 (cluster suite)
# Always expected:
#   "the <mode> sidecar cannot restrict them ...", "only the unprivileged
#   sidecar cannot restrict them": the Docker suite's two complementary
#   router advertisement checks, one per sidecar mode
#   "Transmission made no announce attempt while shutting down ...":
#   Transmission sends its shutdown announces only sometimes; the same file
#   forces announces in the window and counts them, so the path is covered
set -euo pipefail
dir=${1:?usage: $0 JUNIT_DIR}
shopt -s nullglob
reports=("$dir"/*.xml)
((${#reports[@]})) || { echo "No test report in $dir: the suite did not run its checks." >&2; exit 1; }
UPGRADE_FROM=${UPGRADE_FROM:-} IPV6=${IPV6:-0} python3 - "${reports[@]}" <<'PY'
import os, re, sys, xml.etree.ElementTree as ET

allowed = [
    (r"^not an upgrade run\b", not os.environ["UPGRADE_FROM"]),
    (r"^IPv6 checks need IPV6=1\b", os.environ["IPV6"] != "1"),
    (r"^the \S+ sidecar cannot restrict them\b", True),
    (r"^only the unprivileged sidecar cannot restrict them\b", True),
    (r"^Transmission made no announce attempt while shutting down\b", True),
]
bad = []
skipped = 0
for f in sys.argv[1:]:
    for case in ET.parse(f).iter("testcase"):
        s = case.find("skipped")
        if s is None:
            continue
        skipped += 1
        reason = (s.text or s.get("message") or "").strip()
        if not any(ok and re.search(pattern, reason) for pattern, ok in allowed):
            bad.append(f"{case.get('classname')}: {case.get('name')} ({reason or 'no reason given'})")
if bad:
    print(f"{len(bad)} unexpected skip(s), checks that proved nothing in this run:")
    for b in bad:
        print(f"  {b}")
    sys.exit(1)
print(f"{skipped} skip(s), all expected for this run")
PY
