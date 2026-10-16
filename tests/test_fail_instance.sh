#!/usr/bin/env bash
# Tests scripts/fail-instance.sh safety checks against tests/stubs/aws (no AWS calls).
# Each case feeds stdin answers and asserts whether a terminate call was recorded.
# Run: bash tests/test_fail_instance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PATH="$ROOT/tests/stubs:$PATH"
A=i-0aaaa1111aaaa1111; B=i-0bbbb2222bbbb2222
PASS=0; FAIL=0

two_healthy='{"instances":{"'$A'":{"lc":"InService","target":"healthy","az":"ap-south-1a"},"'$B'":{"lc":"InService","target":"healthy","az":"ap-south-1b"}}}'

run_case() {  # name, scenario-json, expect(terminated|refused), stdin, args...
  local name="$1" scenario="$2" expect="$3" input="$4"; shift 4
  export STUB_SCENARIO="$TMP/$name.json"
  echo "$scenario" > "$STUB_SCENARIO"
  printf '%b' "$input" | "$ROOT/scripts/fail-instance.sh" --no-watch "$@" > "$TMP/$name.out" 2>&1
  local got
  got=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("terminated", [])))' "$STUB_SCENARIO")
  if { [[ $expect == refused && -z "$got" ]] || [[ $expect == terminated:* && "$got" == "${expect#terminated:}" ]]; }; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (expected %s, terminated=[%s])\n' "$name" "$expect" "$got"; tail -5 "$TMP/$name.out" | sed 's/^/        /'
  fi
}

echo "fail-instance.sh safety tests"
run_case happy_path_by_id         "$two_healthy" "terminated:$A" "$A\nterminate\n" "$A"
run_case happy_path_by_menu       "$two_healthy" "terminated:$A" "1\n$A\nterminate\n"
run_case crash_mode_uses_ec2      "$two_healthy" "terminated:$A" "$A\nterminate\n" --mode crash "$A"
run_case wrong_id_typed           "$two_healthy" refused "$B\nterminate\n" "$A"
run_case partial_id_typed         "$two_healthy" refused "i-0aaaa\nterminate\n" "$A"
run_case second_confirm_missing   "$two_healthy" refused "$A\nyes\n" "$A"
run_case empty_input              "$two_healthy" refused "" "$A"
run_case malformed_id_arg         "$two_healthy" refused "x\nterminate\n" "i-ZZZ;rm"
run_case not_an_asg_member        "$two_healthy" refused "i-0dddd4444dddd4444\nterminate\n" i-0dddd4444dddd4444
run_case asg_not_tagged_project   '{"asg_project":"None","instances":{}}' refused "$A\nterminate\n" "$A"
run_case instance_tag_mismatch    '{"instances":{"'$A'":{"lc":"InService","target":"healthy","az":"ap-south-1a","asg_tag":"ABC-Business"},"'$B'":{"lc":"InService","target":"healthy","az":"ap-south-1b"}}}' refused "$A\nterminate\n" "$A"
run_case pending_member_refused   '{"instances":{"'$A'":{"lc":"Pending","target":"initial","az":"ap-south-1a"},"'$B'":{"lc":"InService","target":"healthy","az":"ap-south-1b"}}}' refused "$A\nterminate\n" "$A"
run_case last_healthy_target      '{"instances":{"'$A'":{"lc":"InService","target":"healthy","az":"ap-south-1a"},"'$B'":{"lc":"InService","target":"initial","az":"ap-south-1b"}}}' refused "$A\nterminate\n" "$A"
run_case only_one_instance        '{"instances":{"'$A'":{"lc":"InService","target":"healthy","az":"ap-south-1a"}}}' refused "$A\nterminate\n" "$A"
run_case survivor_lost_before_act "$(echo "$two_healthy" | sed 's/^{/{"flip_on_others_check":2,/')" refused "$A\nterminate\n" "$A"
run_case allow_outage_flag_gone   '{"instances":{"'$A'":{"lc":"InService","target":"healthy","az":"ap-south-1a"}}}' refused "$A\nterminate\n" --allow-outage "$A"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
