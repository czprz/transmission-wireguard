#!/usr/bin/env bash
# Markdown summary of the bats JUnit reports in $1: the totals, and every
# failed or skipped check by name, for the CI run's summary page.
set -euo pipefail
dir=${1:?usage: $0 JUNIT_DIR}
shopt -s nullglob
reports=("$dir"/*.xml)
if ((${#reports[@]} == 0)); then
  echo "No test report: the suite did not get as far as running its checks."
  exit 0
fi
python3 - "${reports[@]}" <<'PY'
import sys, xml.etree.ElementTree as ET
cases = [c for f in sys.argv[1:] for c in ET.parse(f).iter("testcase")]
failed = [c for c in cases if c.find("failure") is not None or c.find("error") is not None]
skipped = [c for c in cases if c.find("skipped") is not None]
print(f"**{len(cases) - len(failed) - len(skipped)} passed, {len(failed)} failed, {len(skipped)} skipped**\n")
for title, group in (("Failed", failed), ("Skipped", skipped)):
    if group:
        print(f"{title}:")
        for c in group:
            print(f"- `{c.get('classname')}`: {c.get('name')}")
        print()
PY
