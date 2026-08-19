#!/usr/bin/env bash
#
# mayhem/test.sh — RUN PCL's own io/common/octree gtest suite (built by mayhem/build.sh into
# build-tests/). exit 0 = pass. These assert concrete values (gtest EXPECT_EQ/ASSERT_*), so a
# no-op/exit(0) PATCH to the fuzzed code fails this — not a reward-hackable "didn't crash" check.
#
# IMPORTANT: CTest itself only checks a test BINARY's exit code — a process that _exit(0)s before
# gtest's RUN_ALL_TESTS() ever runs (e.g. under the anti-reward-hack LD_PRELOAD sabotage, which
# fires at dynamic-loader constructor time, before main()) would look like a ctest PASS despite
# running zero assertions. To stay a genuine behavioral oracle we bypass ctest's own pass/fail and
# instead run every registered test binary directly with its own `--gtest_output=xml:`, requiring a
# well-formed report for EACH one — gtest only writes that file once RUN_ALL_TESTS() completes, so a
# sabotaged (never-ran) binary produces no report and counts as a failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d build-tests ]; then
  echo "build-tests/ missing — mayhem/build.sh should have configured it" >&2
  emit_ctrf "cmake-ctest" 0 1 0
  exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Discover every registered ctest test's exact command (name + argv + executable) without
# guessing binary paths — stays correct if PCL adds/removes/relocates a test binary upstream.
( cd build-tests/test && ctest --show-only=json-v1 ) > "$TMPD/tests.json" 2>"$TMPD/show-only.err"
python3 - "$TMPD/tests.json" "$TMPD/manifest.tsv" <<'PY'
import json, sys, shlex
with open(sys.argv[1]) as f:
    d = json.load(f)
with open(sys.argv[2], "w") as out:
    for t in d.get("tests", []):
        cmd = t.get("command", [])
        if not cmd:
            continue
        out.write(t["name"] + "\t" + cmd[0] + "\t" + shlex.join(cmd[1:]) + "\n")
PY

if [ ! -s "$TMPD/manifest.tsv" ]; then
  echo "no ctest-registered tests found in build-tests/ (see $TMPD/show-only.err)" >&2
  cat "$TMPD/show-only.err" >&2 2>/dev/null || true
  emit_ctrf "cmake-ctest" 0 1 0
  exit 1
fi

: > "$TMPD/results"
while IFS=$'\t' read -r name exe args; do
  [ -n "$name" ] || continue
  xml="$TMPD/report-$name.xml"
  ( cd build-tests && eval "$exe" $args --gtest_output="xml:$xml" ) >"$TMPD/log.$name" 2>&1
  echo "$name	$xml" >> "$TMPD/results"
done < "$TMPD/manifest.tsv"

passed=0 failed=0 skipped=0
while IFS=$'\t' read -r name xml; do
  if [ ! -s "$xml" ]; then
    echo "MISSING gtest report for '$name' — binary did not complete RUN_ALL_TESTS (log: $TMPD/log.$name)" >&2
    failed=$((failed+1))
    continue
  fi
  read -r p f s <<<"$(python3 - "$xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
tests = failures = errors = skipped = 0
for su in suites:
    tests += int(su.get("tests", 0))
    failures += int(su.get("failures", 0))
    errors += int(su.get("errors", 0))
    skipped += int(su.get("skipped", 0))
print(tests - failures - errors - skipped, failures + errors, skipped)
PY
)"
  if [ -z "${p:-}" ]; then
    echo "unparseable gtest report for '$name': $xml" >&2
    failed=$((failed+1))
    continue
  fi
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+s))
done < "$TMPD/results"

emit_ctrf "cmake-ctest" "$passed" "$failed" "$skipped"
