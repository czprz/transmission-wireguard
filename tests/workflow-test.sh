#!/usr/bin/env bash
# A reusable workflow's jobs may not ask for more permissions than each
# caller grants it: GitHub refuses to start the caller at all
# (startup_failure, no jobs), and actionlint doesn't check it. Helm Main
# stopped running for that once.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob, sys, yaml

LEVEL = {"none": 0, "read": 1, "write": 2}
def perms(p):
    if p is None:
        return {}
    if isinstance(p, str):  # read-all / write-all
        return {"*": "write" if p == "write-all" else "read"}
    return p

failed = 0
for caller in sorted(glob.glob(".github/workflows/*.y*ml")):
    wf = yaml.safe_load(open(caller))
    for name, job in (wf.get("jobs") or {}).items():
        uses = job.get("uses", "")
        if not uses.startswith("./.github/workflows/"):
            continue
        granted = perms(job.get("permissions", wf.get("permissions")))
        callee = yaml.safe_load(open(uses[2:]))
        for cname, cjob in (callee.get("jobs") or {}).items():
            for scope, want in perms(cjob.get("permissions", callee.get("permissions"))).items():
                have = granted.get(scope, granted.get("*", "none"))
                if LEVEL[want] > LEVEL[have]:
                    print(f"FAIL  {caller} job {name} grants {scope}: {have}, but {uses[2:]} job {cname} asks for {want}")
                    failed = 1
print("PASS  every reusable workflow's jobs stay within what their callers grant" if not failed else "")
sys.exit(failed)
PY
