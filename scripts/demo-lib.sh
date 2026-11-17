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

# In a guided demo (just start) the next step runs by itself, so drop the "Then: just ..." hint.
next() {
  local msg="$*"
  [[ "${GUIDED:-0}" == "1" ]] && msg="${msg%% Then: just*}"
  printf '\n%s→ Next:%s %s\n' "$BOLD" "$RESET" "$msg"
}

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

# Open a URL in the default browser (set NO_BROWSER=1 to only print it).
browse() {
  info "Opening $1"
  [[ -n "${NO_BROWSER:-}" ]] || open "$1" >/dev/null 2>&1 || true
}

# Between steps of a guided demo: wait for Enter, unless AUTO=1.
#   pause "<what happens next>"
pause() {
  if [[ "${AUTO:-}" == "1" ]]; then return 0; fi
  printf '\n%s⏎  Press Enter to %s%s (Ctrl-C to stop) ' "$BOLD" "$1" "$RESET"
  read -r _ </dev/tty
}

# A numbered heading for each step of a guided demo.
step() { printf '\n%s%s[%s] %s%s\n' "$BOLD" "$BLUE" "$1" "$2" "$RESET"; }

# Fast checks before a guided demo; `just doctor` is the full version.
preflight() {
  kubectl get ns default >/dev/null 2>&1 || die "Can't reach minikube. Run: just doctor"
  local ready
  ready=$(kubectl -n testkube get deploy "testkube-$RUNNER-testkube-runner" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [[ "${ready:-0}" -ge 1 ]] || die "Testkube runner $RUNNER is not running. Run: just doctor"
  testkube get context 2>/dev/null | plain | grep -q "$TK_ENV" || die "Testkube CLI is not pointed at the demo environment. Run: just doctor"
  ok "minikube and the Testkube runner are up"
}

# Open `just watch` in a new terminal window, unless one is already running.
open_watch_window() {
  if pgrep -f "kubectl get pods -A --watch-only" >/dev/null 2>&1; then
    ok "Pod watch is already running"
    return 0
  fi
  local cmd="cd '$PWD' && clear && just watch"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal)
      osascript -e "tell application \"Terminal\" to do script \"$cmd\"" >/dev/null 2>&1 \
        && { ok "Opened the pod watch in a new Terminal window"; return 0; } ;;
    iTerm.app)
      osascript -e "tell application \"iTerm\" to create window with default profile command \"/bin/zsh -lc \\\"$cmd\\\"\"" >/dev/null 2>&1 \
        && { ok "Opened the pod watch in a new iTerm window"; return 0; } ;;
  esac
  warn "Open a second terminal pane in this folder and run: just watch"
}

# Stream every pod the demo creates: app pods in pr-/tk- namespaces, Testkube test
# pods for the demo workflows, and the Argo CD test hook. One line per status change.
watch_pods() {
  kubectl get pods -A --watch-only --output-watch-events -o json 2>/dev/null \
  | jq -r --unbuffered '
      .type as $t | .object
      | [ $t, .metadata.namespace, .metadata.name,
          (if $t == "DELETED" then "Deleted"
           elif .metadata.deletionTimestamp then "Terminating"
           else ([.status.containerStatuses[]?.state | (.waiting.reason // .terminated.reason // empty)] | first) // .status.phase
           end),
          (.metadata.labels["testkube.io/workflow-name"] // "") ] | @tsv' \
  | awk -F'\t' -v g="$GREEN" -v r="$RED" -v y="$YELLOW" -v d="$DIM" -v z="$RESET" '
      {
        ns=$2; name=$3; st=$4; wf=$5; role=""
        if (ns ~ /^tk-/ || ns ~ /^pr-/) role="app under test"
        else if (ns == "demo-ops") role="Argo CD test hook"
        else if (ns == "testkube" && (wf == "demo-app-ephemeral" || wf == "demo-app-e2e")) role="Testkube run: " wf
        if (role == "") next
        if (st ~ /ImagePull/ && ns ~ /^pr-/) role=role " (image still building)"
        key=ns "/" name
        if (seen[key] == st) next
        seen[key]=st
        c=""
        if (st == "Running" || st == "Completed" || st == "Succeeded") c=g
        else if (st ~ /Err|BackOff|Failed|Error/) c=r
        else if (st == "Terminating" || st == "Deleted") c=d
        else c=y
        cmd="date +%H:%M:%S"; cmd | getline ts; close(cmd)
        printf "%s  %-28s %-44s %s%-18s%s %s%s%s\n", ts, ns, name, c, st, z, d, role, z
        fflush()
      }'
}

# Start demo-app-ephemeral from the CLI and print the execution ID.
tk_start_ephemeral() {
  testkube run testworkflow demo-app-ephemeral --config imageTag=main --config "gitRevision=$1" \
    --target "name=$RUNNER" --output go --go-template '{{.Id}}' 2>/dev/null | tr -d '[:space:]'
}

# ID of the newest demo-app-ephemeral execution.
tk_latest_ephemeral() {
  testkube get testworkflowexecution -w demo-app-ephemeral --limit 1 -o json 2>/dev/null | jq -r '.[0].id // empty'
}

# Follow an execution until it finishes, reporting its namespace as it is created and removed.
#   tk_follow <execution-id>   (returns 0 if passed)
tk_follow() {
  local id=$1 ns="tk-$1" status="" last_status="" phase="" last_phase="none"
  show "testkube get testworkflowexecution $id   (every 3 seconds)"
  while true; do
    status=$(testkube get testworkflowexecution "$id" --output go --go-template '{{.Result.Status}}' 2>/dev/null | tr -d '[:space:]' || true)
    phase=$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    phase=${phase:-none}
    if [[ "$phase" != "$last_phase" ]]; then
      case "$phase" in
        Active) doing "Namespace $ns created" ;;
        Terminating) doing "Namespace $ns is being deleted" ;;
        none) [[ "$last_phase" != "none" ]] && ok "Namespace $ns deleted" ;;
      esac
      last_phase=$phase
    fi
    if [[ -n "$status" && "$status" != "$last_status" ]]; then
      case "$status" in
        queued|running) doing "Execution $status" ;;
      esac
      last_status=$status
    fi
    case "$status" in
      passed|failed|aborted|canceled|cancelled)
        # Teardown deletes the namespace as the run's last step; give it a moment to go.
        for _ in $(seq 1 20); do
          kubectl get ns "$ns" >/dev/null 2>&1 || break
          sleep 3
        done
        if kubectl get ns "$ns" >/dev/null 2>&1; then
          warn "Namespace $ns still exists"
        elif [[ "$last_phase" != "none" ]]; then
          ok "Namespace $ns deleted"
        fi
        if [[ "$status" == "passed" ]]; then ok "Tests passed"; return 0; fi
        bad "Tests $status"; return 1 ;;
    esac
    sleep 3
  done
}
