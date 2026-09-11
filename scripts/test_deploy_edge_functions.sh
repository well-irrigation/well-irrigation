#!/bin/sh
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/scripts/deploy_edge_functions.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wi-edge-deploy-test.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin"
cat > "$tmp/bin/npx" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_ARGS_FILE"
exit "${MOCK_NPX_EXIT:-0}"
MOCK
chmod +x "$tmp/bin/npx"

pass=0
fail=0

run_case() {
  name=$1
  expected=$2
  mock_exit=$3
  output="$tmp/$name.log"
  args="$tmp/$name.args"

  : > "$args"
  set +e
  PATH="$tmp/bin:$PATH" \
    MOCK_ARGS_FILE="$args" \
    MOCK_NPX_EXIT="$mock_exit" \
    SUPABASE_ACCESS_TOKEN=test-token \
    sh "$script" > "$output" 2>&1
  actual=$?
  set -e

  if [ "$actual" -ne "$expected" ]; then
    printf 'FAIL %s status=%s expected=%s\n' "$name" "$actual" "$expected"
    fail=$((fail + 1))
    return
  fi

  case "$name" in
    success)
      if grep -Fq 'RESULT=SUCCESS' "$output" \
        && grep -Fq -- '--project-ref hxfhczpfrfdpzsobfbab' "$args"; then
        printf 'PASS %s\n' "$name"
        pass=$((pass + 1))
      else
        printf 'FAIL %s missing-success-contract\n' "$name"
        fail=$((fail + 1))
      fi
      ;;
    failure)
      if grep -Fq 'RESULT=FAILED_AT=4' "$output" \
        && ! grep -Fq 'RESULT=SUCCESS' "$output"; then
        printf 'PASS %s\n' "$name"
        pass=$((pass + 1))
      else
        printf 'FAIL %s false-success\n' "$name"
        fail=$((fail + 1))
      fi
      ;;
  esac
}

run_case success 0 0
run_case failure 1 17

printf 'PASS_COUNT=%s FAIL_COUNT=%s\n' "$pass" "$fail"
if [ "$pass" -eq 2 ] && [ "$fail" -eq 0 ]; then
  printf 'RESULT=SUCCESS\n'
  exit 0
fi
printf 'RESULT=FAILED\n'
exit 1
