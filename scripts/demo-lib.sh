# Shared helpers for the justfile recipes. Sourced, not run directly.
# Configuration values arrive as environment variables exported by the justfile.

set -euo pipefail

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
  DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; DIM=''; BOLD=''; RESET=''
fi

STATE_DIR="${STATE_DIR:-.demo-state}"
mkdir -p "$STATE_DIR"

ok()    { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
doing() { printf '%s→%s %s\n' "$BLUE" "$RESET" "$*"; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad()   { printf '%s✗%s %s\n' "$RED" "$RESET" "$*"; }
die()   { bad "$*"; exit 1; }
info()  { printf '  %s\n' "$*"; }

# Print a command the way a terminal would, then run it.
show()  { printf '%s$ %s%s\n' "$DIM" "$*" "$RESET"; }
run()   { show "$*"; "$@"; }

# Run a command quietly; print its output only if it fails.
quiet() {
  local out
  if ! out=$("$@" 2>&1); then
    printf '%s\n' "$out"
    return 1
  fi
}

next()  { printf '\n%s→ Next:%s %s\n' "$BOLD" "$RESET" "$*"; }

# Strip colour codes from CLI output so it can be matched.
plain() { sed -e $'s/\033\\[[0-9;]*m//g'; }

# Testkube dashboard links.
tk_workflow_url()  { printf '%s/test-workflows/%s' "$TK_DASHBOARD" "$1"; }
tk_execution_url() { printf '%s/test-workflows/%s/execution/%s' "$TK_DASHBOARD" "$1" "$2"; }

# The pull request a Path 1 step should target: the argument if given, otherwise
# the last one opened with `just pr-open`, otherwise the newest open live pull request.
resolve_pr() {
  local n="${1:-}"
  if [[ -z "$n" && -s "$STATE_DIR/last-pr" ]]; then
    n=$(cat "$STATE_DIR/last-pr")
  fi
  if [[ -z "$n" ]]; then
    n=$(live_prs | head -1)
  fi
  [[ -n "$n" ]] || die "No pull request to use. Run: just pr-open   (or pass a number, e.g. just pr-app 1)"
  [[ "$n" =~ ^[0-9]+$ ]] || die "Pull request number must be a number, got: $n"
  printf '%s' "$n"
}

# Start a kubectl port-forward in the background, replacing any earlier one on the same port.
#   port_forward <name> <namespace> <service> <local-port> <remote-port>
port_forward() {
  local name=$1 ns=$2 svc=$3 lport=$4 rport=$5
  stop_port_forward "$name"
  # Anything else still holding the port (for example a port-forward started by hand).
  local holder
  holder=$(lsof -ti "tcp:$lport" -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "$holder" ]]; then
    if ps -o command= -p "$holder" | grep -q 'kubectl.*port-forward'; then
      kill "$holder" 2>/dev/null || true
      sleep 1
    else
      die "Port $lport is in use by another program. Free it, then rerun this step."
    fi
  fi
  show "kubectl -n $ns port-forward svc/$svc $lport:$rport &"
  nohup kubectl -n "$ns" port-forward "svc/$svc" "$lport:$rport" \
    > "$STATE_DIR/pf-$name.log" 2>&1 &
  echo $! > "$STATE_DIR/pf-$name.pid"
  for _ in $(seq 1 20); do
    if lsof -ti "tcp:$lport" -sTCP:LISTEN >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  cat "$STATE_DIR/pf-$name.log"
  die "Port-forward to $svc in $ns did not start (log above)."
}

stop_port_forward() {
  local pidfile="$STATE_DIR/pf-$1.pid"
  if [[ -s "$pidfile" ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
}

port_forward_running() {
  local pidfile="$STATE_DIR/pf-$1.pid"
  [[ -s "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

# Namespaces left behind: pr-N whose pull request is no longer open, and tk-ID whose
# Testkube execution has finished. Prints one warning per namespace; returns the count.
leftover_namespaces() {
  local open_prs ns n id status count=0
  open_prs=" $(gh pr list --repo "$GH_REPO" --state open --json number --jq '.[].number' 2>/dev/null | tr '\n' ' ') "
  while read -r ns; do
    [[ -n "$ns" ]] || continue
    case "$ns" in
      pr-*)
        n=${ns#pr-}
        if [[ "$open_prs" != *" $n "* ]]; then
          warn "Namespace $ns: pull request #$n is closed (deleting takes about 3 minutes after close)"
          count=$((count + 1))
        fi ;;
      tk-*)
        id=${ns#tk-}
        status=$(testkube get testworkflowexecution "$id" --output go \
                   --go-template '{{.Result.Status}}' 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$status" != "running" && "$status" != "queued" ]]; then
          warn "Namespace $ns: its Testkube execution is ${status:-not found}, so teardown did not finish. Remove with: kubectl delete ns $ns"
          count=$((count + 1))
        fi ;;
    esac
  done < <(kubectl get ns -o name 2>/dev/null | sed 's|^namespace/||' | grep -E '^(pr|tk)-' || true)
  return $count
}

# Open pull requests opened by `just pr-open` (those with the live-demo label), newest first.
# Filters labels locally: GitHub's label search lags a few seconds behind new pull requests.
live_prs() {
  gh pr list --repo "$GH_REPO" --state open --json number,labels \
    --jq "[.[] | select(any(.labels[]; .name == \"$LIVE_LABEL\")) | .number] | .[]" 2>/dev/null || true
}
