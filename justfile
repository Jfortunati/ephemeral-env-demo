# Demo commands for the ephemeral environment demo.
#
#   just              open the menu
#   just --list       list every command with its description
#
# Recipes wrap the commands in docs/SETUP.md and docs/DEMO-RUNBOOK.md.
# Shared shell helpers live in scripts/demo-lib.sh.

set export := true
set shell := ["bash", "-euo", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# Configuration. Change these when moving the demo to another account or laptop.
# ---------------------------------------------------------------------------

# Testkube runner that executes the workflows (must match testkubeHook.runner in chart/demo-app/values.yaml).
RUNNER := "jf-minikube"

# Testkube organization and environment the demo runs in. Not secret.
TK_ORG := "tkcorg_b5ace2135f138dc8"
TK_ENV := "tkcenv_362177294460621a"

# Testkube dashboard for that environment.
TK_DASHBOARD := "https://app.testkube.io/organization/" + TK_ORG + "/environment/" + TK_ENV + "/dashboard"

# GitHub repository (owner/name) that Argo CD watches for pull requests.
GH_REPO := "Jfortunati/ephemeral-env-demo"

# Label put on pull requests opened by `just pr-open`. `just reset` closes only these.
LIVE_LABEL := "demo-live"

# Branches of the fallback pull requests that must stay open (passing, failing).
FALLBACK_BRANCHES := "change/seed-items demo/failing-test"

# Argo CD version installed in minikube.
ARGOCD_VERSION := "v3.6.1"

# Cluster size: minikube runs inside colima's virtual machine, which needs headroom.
MINIKUBE_CPUS := "4"
MINIKUBE_MEMORY_MB := "8192"
COLIMA_CPUS := "8"
COLIMA_MEMORY_GB := "12"

# Images pre-pulled into minikube before a demo.
IMAGES := "mcr.microsoft.com/playwright:v1.65.1-noble alpine/k8s:1.37.2 kubeshop/testkube-cli:2.15.2 ghcr.io/jfortunati/ephemeral-env-demo:main"

# Local folder for the last pull request number and port-forward process IDs.
STATE_DIR := ".demo-state"

# ---------------------------------------------------------------------------

# Show the demo plans
[private]
default: plan

# ===== Start here ==========================================================

# Show both demos, step by step, and the command that runs each one
[group('1. Start here')]
plan:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    h() { printf '\n%s%s%s   %s%s%s\n' "$BOLD" "$1" "$RESET" "$BLUE" "$2" "$RESET"; }
    s() { printf '  %s%s%s  %s\n' "$DIM" "$1" "$RESET" "$2"; }
    printf '%sTwo demos. One command runs each, start to finish.%s\n' "$BOLD" "$RESET"

    h "Testkube demo: Testkube deploys, tests and tears down" "just start testkube"
    s 1 "Checks minikube and the Testkube runner"
    s 2 "Opens a pod watch in a new terminal window"
    s 3 "Opens the demo-app-ephemeral workflow in the Testkube dashboard; you click Run"
    s " " "(auto: starts the run from the terminal and opens it in the dashboard)"
    s 4 "Follows the run: namespace created, app installed, tests, namespace deleted"
    s 5 "Same again on the branch with a failing test: teardown still runs"

    h "Argo CD demo: Argo CD deploys each pull request, Testkube tests it" "just start argo"
    s 1 "Checks Argo CD, starts its UI (no login needed), opens Argo CD and Testkube"
    s 2 "Opens a pod watch in a new terminal window"
    s 3 "Opens a GitHub pull request and shows it, then the Argo CD app for it"
    s 4 "Waits for the image build (about 1.5 min) and the deploy, opens the app"
    s 5 "Follows the Testkube tests the Argo CD hook starts, opens the execution"
    s 6 "Closes the pull request and waits for its namespace to go (about 3 min)"

    printf '\n%sHow it runs%s\n' "$BOLD" "$RESET"
    info "Each demo pauses before each step so you can talk; press Enter to go on."
    info "Add auto (just start testkube auto) to run straight through without waiting for you."
    printf '\n%sAround the demos%s\n' "$BOLD" "$RESET"
    info "Before the call   just doctor     checks everything, changes nothing"
    info "After the call    just reset      closes pull requests opened during the demo"
    info "One step at a time   just menu"

# Run a demo start to finish: `just start testkube` or `just start argo` (add `auto` to skip pauses)
[group('1. Start here')]
start demo="" mode="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    demo="{{ demo }}"; mode="{{ mode }}"
    case "$mode" in
      "") export AUTO=0 ;;
      auto) export AUTO=1 ;;
      *) die "Unknown option '$mode'. Use nothing or: auto" ;;
    esac
    export GUIDED=1
    case "$demo" in
      testkube) ;;
      argo) ;;
      *) just plan; echo; die "Say which demo: just start testkube   or   just start argo" ;;
    esac

    if [[ "$demo" == "testkube" ]]; then
      printf '%sTestkube demo: Testkube deploys, tests and tears down%s\n' "$BOLD" "$RESET"
      step 1 "Check minikube and the Testkube runner"
      preflight
      step 2 "Pod watch"
      open_watch_window

      for rev in main demo/failing-test; do
        if [[ "$rev" == "main" ]]; then
          pause "open the workflow in Testkube"
          step 3 "Run demo-app-ephemeral"
        else
          pause "run it again on the branch with a failing test"
          step 5 "Run demo-app-ephemeral on $rev: one test fails, teardown still runs"
        fi
        if [[ "$AUTO" == "1" ]]; then
          show "testkube run testworkflow demo-app-ephemeral --config gitRevision=$rev --target name=$RUNNER"
          id=$(tk_start_ephemeral "$rev")
          [[ -n "$id" ]] || die "Testkube did not start the run. Try: just run-ephemeral cli"
          ok "Started execution $id"
          browse "$(tk_execution_url demo-app-ephemeral "$id")"
        else
          before=$(tk_latest_ephemeral)
          browse "$(tk_workflow_url demo-app-ephemeral)"
          info "Click Run, then pick runner $RUNNER and choose $rev in the gitRevision dropdown (imageTag stays main)"
          doing "Waiting for you to click Run in Testkube"
          until id=$(tk_latest_ephemeral) && [[ -n "$id" && "$id" != "$before" ]]; do sleep 3; done
          ok "Execution $id started"
        fi
        [[ "$rev" == "main" ]] && step 4 "Follow the run"
        if tk_follow "$id"; then
          next "Walk through Provision (namespace, chart, image and revision in the log), the test results, then Teardown."
        else
          next "Show the failed test and its screenshot under Artifacts, then point at Teardown: it still ran, and the namespace is gone."
        fi
      done
      printf '\n%s✓ Testkube demo done.%s Nothing to clean up: each run removed its own namespace.\n' "$GREEN" "$RESET"
      exit 0
    fi

    printf '%sArgo CD demo: Argo CD deploys each pull request, Testkube tests it%s\n' "$BOLD" "$RESET"
    step 1 "Check Argo CD and open the dashboards"
    preflight
    ready=$(kubectl -n argocd get deploy argocd-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [[ "${ready:-0}" -ge 1 ]] || die "Argo CD is not running. Run: just doctor"
    argocd_ui
    browse "https://localhost:8443/applications"
    browse "$(tk_workflow_url demo-app-e2e)"
    step 2 "Pod watch"
    open_watch_window

    pause "open a pull request"
    step 3 "Open a pull request"
    just pr-open
    n=$(cat "$STATE_DIR/last-pr")
    doing "Waiting for Argo CD to pick up pull request #$n (it checks GitHub every 30 seconds)"
    for _ in $(seq 1 60); do
      kubectl -n argocd get app "demo-app-pr-$n" >/dev/null 2>&1 && break
      sleep 3
    done
    if kubectl -n argocd get app "demo-app-pr-$n" >/dev/null 2>&1; then
      ok "Argo CD created app demo-app-pr-$n"
      browse "https://localhost:8443/applications/argocd/demo-app-pr-$n"
    else
      warn "Argo CD has not created demo-app-pr-$n yet; carrying on"
    fi

    step 4 "Wait for the deploy and open the app"
    just pr-app "$n"

    pause "follow the tests"
    step 5 "Follow the Testkube tests"
    just pr-tests "$n"

    pause "close the pull request"
    step 6 "Close the pull request"
    just pr-close "$n"
    doing "Waiting for namespace pr-$n to go (about 3 minutes)"
    start=$SECONDS
    while kubectl get ns "pr-$n" >/dev/null 2>&1; do
      (( SECONDS - start > 420 )) && { warn "Namespace pr-$n is still terminating; just doctor will show if it stays"; break; }
      sleep 5
    done
    kubectl get ns "pr-$n" >/dev/null 2>&1 || ok "Namespace pr-$n deleted after $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
    printf '\n%s✓ Argo CD demo done.%s Pull requests #1 and #2 stay open as fallbacks.\n' "$GREEN" "$RESET"

# Watch every pod the demos create: app, Testkube test runs, Argo CD hook (Ctrl-C to stop)
[group('1. Start here')]
watch:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    printf '%sPods created by the demos%s  (app under test, Testkube test runs, Argo CD test hook)\n' "$BOLD" "$RESET"
    show "kubectl get pods -A --watch-only"
    watch_pods

# Pick one demo step at a time from a list
[group('1. Start here')]
menu:
    @just --choose --unsorted

# ===== Before the call =====================================================

# Check that everything the demo needs is in place (changes nothing)
[group('1. Start here')]
doctor:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    set +e
    problems=0; warnings=0
    problem() { bad "$1"; info "Fix: $2"; problems=$((problems + 1)); }
    caution() { warn "$1"; warnings=$((warnings + 1)); }

    # 1. Tools
    missing=()
    for t in just fzf colima docker minikube kubectl helm testkube gh jq; do
      command -v "$t" >/dev/null || missing+=("$t")
    done
    if ((${#missing[@]})); then problem "Missing tools: ${missing[*]}" "brew bundle"
    else ok "Tools installed"; fi

    # 2. Docker
    if docker info >/dev/null 2>&1; then ok "Docker is running"
    else problem "Docker is not running" "colima start --cpu $COLIMA_CPUS --memory $COLIMA_MEMORY_GB"; fi

    # 3. minikube: running, big enough, current kubectl context
    cluster=0
    host=$(minikube status -o json 2>/dev/null | jq -r '.Host // empty')
    if [[ "$host" != "Running" ]]; then
      problem "minikube is not running" "minikube start"
    else
      read -r cpus mem < <(docker inspect minikube 2>/dev/null | jq -r '.[0].HostConfig | "\(.NanoCpus / 1e9 | floor) \(.Memory / 1048576 | floor)"')
      if (( cpus < MINIKUBE_CPUS || mem < MINIKUBE_MEMORY_MB )); then
        problem "minikube has ${cpus} CPUs / ${mem} MB, needs $MINIKUBE_CPUS / $MINIKUBE_MEMORY_MB" "see 'Size the cluster' in docs/SETUP.md"
      elif [[ "$(kubectl config current-context 2>/dev/null)" != "minikube" ]]; then
        problem "kubectl is not pointed at minikube" "kubectl config use-context minikube"
      else
        ok "minikube is running (${cpus} CPUs, ${mem} MB) and is the kubectl context"; cluster=1
      fi
    fi

    # 4. GitHub CLI
    if gh auth status -h github.com >/dev/null 2>&1; then ok "GitHub CLI is logged in"
    else problem "GitHub CLI is not logged in" "gh auth login"; fi

    # 5. Testkube CLI
    ctx=$(testkube get context 2>/dev/null | plain)
    if grep -q "$TK_ORG" <<<"$ctx" && grep -q "$TK_ENV" <<<"$ctx"; then ok "Testkube CLI is logged in to the demo environment"
    else problem "Testkube CLI is not logged in to the demo environment" "testkube login, then testkube set context --org-id $TK_ORG --env-id $TK_ENV"; fi

    # Runner name in the Helm chart must match
    chart_runner=$(awk '/^testkubeHook:/{f=1} f && /^  runner:/{print $2; exit}' chart/demo-app/values.yaml)
    [[ "$chart_runner" == "$RUNNER" ]] || problem "Runner in chart/demo-app/values.yaml is '$chart_runner', justfile says '$RUNNER'" "make them the same"

    if ((cluster)); then
      # 6. Runner pod and connection
      ready=$(kubectl -n testkube get deploy "testkube-$RUNNER-testkube-runner" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      if [[ "${ready:-0}" -ge 1 ]]; then ok "Testkube runner $RUNNER is running in minikube"
      else problem "Testkube runner $RUNNER is not running in minikube" "kubectl -n testkube get pods; see step 2 of docs/SETUP.md"; fi
      age=$(testkube get runner -o json 2>/dev/null | jq -r --arg n "$RUNNER" '.[] | select(.name == $n) | now - (.accessedAt | sub("\\.[0-9]+Z$"; "Z") | fromdate) | floor' 2>/dev/null)
      if [[ -n "$age" && "$age" -lt 120 ]]; then ok "Testkube runner $RUNNER is connected to Testkube"
      else problem "Testkube runner $RUNNER has not checked in with Testkube recently" "kubectl -n testkube logs deploy/testkube-$RUNNER-testkube-runner"; fi

      # 7. Argo CD
      ready=$(kubectl -n argocd get deploy argocd-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      if [[ "${ready:-0}" -ge 1 ]]; then ok "Argo CD is running"
      else problem "Argo CD is not running" "see step 3 of docs/SETUP.md"; fi
      if [[ "$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.users\.anonymous\.enabled}' 2>/dev/null)" == "true" ]]; then ok "Argo CD UI needs no login"
      else problem "Argo CD UI asks for a login" "see 'Turn off the Argo CD login' in step 3 of docs/SETUP.md"; fi

      # 8, 9. Secrets
      if kubectl -n argocd get secret github-token >/dev/null 2>&1; then ok "GitHub token secret exists (for Argo CD)"
      else problem "GitHub token secret is missing (Argo CD can't see pull requests)" "see step 4 of docs/SETUP.md"; fi
      if kubectl -n demo-ops get secret testkube-api >/dev/null 2>&1; then ok "Testkube API token secret exists (for the Argo CD test hook)"
      else problem "Testkube API token secret is missing (the Argo CD test hook can't start tests)" "see step 4 of docs/SETUP.md"; fi

      # 10. Permissions for the deploy-and-test workflow
      if kubectl -n testkube get sa demo-app-ephemeral >/dev/null 2>&1 && kubectl get clusterrolebinding demo-app-ephemeral >/dev/null 2>&1; then
        ok "Permissions for the deploy-and-test workflow are applied"
      else problem "Permissions for the deploy-and-test workflow are missing" "kubectl apply -f deploy/testkube/rbac.yaml"; fi
    fi

    # 11. Testkube workflows
    tk_missing=()
    testkube get testworkflowtemplate playwright-e2e -o json >/dev/null 2>&1 || tk_missing+=("template playwright-e2e")
    for wf in demo-app-e2e demo-app-ephemeral; do
      testkube get testworkflow "$wf" -o json >/dev/null 2>&1 || tk_missing+=("workflow $wf")
    done
    if ((${#tk_missing[@]})); then problem "Missing in Testkube: ${tk_missing[*]}" "see step 6 of docs/SETUP.md"
    else ok "Testkube template and both workflows exist"; fi

    if ((cluster)); then
      # 12. ApplicationSet
      if kubectl -n argocd get applicationset demo-app-pull-requests >/dev/null 2>&1; then ok "Argo CD watches the GitHub repo's pull requests"
      else problem "Argo CD ApplicationSet is missing" "kubectl apply -f deploy/argocd/applicationset.yaml"; fi

      # 13. Images
      present=$(minikube image ls 2>/dev/null)
      img_missing=()
      for img in $IMAGES; do
        grep -qxF -e "$img" -e "docker.io/$img" <<<"$present" || img_missing+=("$img")
      done
      if ((${#img_missing[@]})); then problem "Images not yet in minikube: ${img_missing[*]}" "minikube image pull <image> (step 8 of docs/SETUP.md)"
      else ok "All demo images are in minikube"; fi

      # 14. Leftover namespaces (warning only)
      leftover_namespaces; n=$?
      if ((n)); then warnings=$((warnings + n)); else ok "No leftover pr- or tk- namespaces"; fi
    fi

    # 15. Fallback material (warning only)
    for b in $FALLBACK_BRANCHES; do
      pr=$(gh pr list --repo "$GH_REPO" --head "$b" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
      if [[ -n "$pr" ]]; then ok "Fallback pull request #$pr ($b) is open"
      else caution "No open fallback pull request for branch $b"; fi
    done
    for s in passed failed; do
      c=$(testkube get testworkflowexecution -w demo-app-ephemeral --status "$s" --limit 1 -o json 2>/dev/null | jq 'length' 2>/dev/null)
      if [[ "${c:-0}" -ge 1 ]]; then ok "A $s demo-app-ephemeral run exists in Testkube to fall back on"
      else caution "No $s demo-app-ephemeral run in Testkube to fall back on"; fi
    done

    echo
    if ((problems)); then
      bad "$problems problem(s). Fix the lines marked ✗ above."
      exit 1
    elif ((warnings)); then
      ok "Ready, with $warnings warning(s) above."
    else
      ok "All ready."
    fi

# Print every URL the demo uses, and start the Argo CD UI
[group('1. Start here')]
links:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    argocd_ui >/dev/null
    echo
    printf '%sTestkube%s\n' "$BOLD" "$RESET"
    info "Dashboard                 $TK_DASHBOARD"
    info "demo-app-ephemeral        $(tk_workflow_url demo-app-ephemeral)"
    info "demo-app-e2e              $(tk_workflow_url demo-app-e2e)"
    printf '%sArgo CD%s\n' "$BOLD" "$RESET"
    info "UI                        https://localhost:8443   (no login; accept the self-signed certificate)"
    printf '%sGitHub%s\n' "$BOLD" "$RESET"
    info "Repository                https://github.com/$GH_REPO"
    info "Actions (image builds)    https://github.com/$GH_REPO/actions"
    info "Pull requests             https://github.com/$GH_REPO/pulls"

# ===== Testkube demo, one step at a time ====================================

# Show how to run demo-app-ephemeral from the dashboard (or `just run-ephemeral cli` to run it here)
[group('2. Testkube demo, one step at a time')]
run-ephemeral mode="": (_ephemeral "main" mode)

# Same, on the branch with a failing test, to show teardown still runs (`cli` to run it here)
[group('2. Testkube demo, one step at a time')]
run-failing mode="": (_ephemeral "demo/failing-test" mode)

[private]
_ephemeral revision mode:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    rev="{{ revision }}"; mode="{{ mode }}"
    cli=(testkube run testworkflow demo-app-ephemeral --config imageTag=main --config "gitRevision=$rev" --target "name=$RUNNER" -f)
    if [[ "$rev" == "main" ]]; then
      cue="Walk through Provision (namespace, chart, image and revision in the log), the test results, then Teardown. The tk- namespace disappears in the pod watch (just watch)."
    else
      cue="One test fails and its screenshot is under Artifacts. Point at Teardown: it still ran, and the tk- namespace is gone."
    fi
    case "$mode" in
      "")
        printf '%sRun this from the Testkube dashboard:%s\n' "$BOLD" "$RESET"
        browse "$(tk_workflow_url demo-app-ephemeral)"
        info "Click Run, then set:"
        info "  Runner       $RUNNER"
        info "  imageTag     main"
        info "  gitRevision  $rev   (dropdown)"
        echo
        printf '%sBackup, from this terminal:%s just %s cli\n' "$DIM" "$RESET" "$([[ $rev == main ]] && echo run-ephemeral || echo run-failing)"
        next "While it runs (about 2 minutes), show the pods appear in the pod watch (just watch). $cue" ;;
      cli)
        run "${cli[@]}" || true
        next "$cue Same run in the dashboard: $(tk_workflow_url demo-app-ephemeral)" ;;
      *)
        die "Unknown option '$mode'. Use nothing (dashboard) or: cli" ;;
    esac

# ===== Argo CD demo, one step at a time =====================================

# Open a pull request with a small visible change to the app
[group('3. Argo CD demo, one step at a time')]
pr-open:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    gh auth status -h github.com >/dev/null 2>&1 || die "GitHub CLI is not logged in. Run: gh auth login"
    stamp=$(date '+%Y-%m-%d %H:%M')
    branch="demo/pr-$(date '+%Y%m%d-%H%M%S')"
    # Work in a temporary checkout so this terminal's branch and files are never touched.
    tree=$(mktemp -d)/pr
    quiet git fetch -q origin main
    quiet git worktree add -q -b "$branch" "$tree" origin/main
    trap 'git worktree remove --force "$tree" >/dev/null 2>&1; git branch -D "$branch" >/dev/null 2>&1 || true' EXIT

    cd "$tree"
    show "git switch -c $branch origin/main"
    show "edit app/server.js: 'Run end-to-end tests' -> 'Run end-to-end tests ($stamp)'"
    perl -pi -e "s/addItem\('Run end-to-end tests'\)/addItem('Run end-to-end tests ($stamp)')/" app/server.js
    grep -q "Run end-to-end tests ($stamp)" app/server.js || die "Could not find the seed item to edit in app/server.js."
    msg="Show when the end-to-end tests item was last updated"
    show "git commit -am \"$msg\""
    quiet git commit -q -am "$msg"
    show "git push -u origin $branch"
    quiet git push -q -u origin "$branch"

    quiet gh label create "$LIVE_LABEL" --repo "$GH_REPO" --color 1d76db \
      --description "Opened during a live demo; closed by just reset" --force
    show "gh pr create --base main --head $branch --label $LIVE_LABEL"
    url=$(gh pr create --repo "$GH_REPO" --base main --head "$branch" --label "$LIVE_LABEL" \
            --title "$msg" --body "Adds a timestamp to one checklist item so the change is visible in the deployed app.")
    n=${url##*/}
    cd - >/dev/null
    echo "$n" > "$STATE_DIR/last-pr"
    ok "Pull request #$n: $url"
    browse "$url"
    next "GitHub Actions builds the image (about 1.5 minutes): https://github.com/$GH_REPO/actions . Within 30 seconds the Argo CD app demo-app-pr-$n appears: https://localhost:8443/applications/argocd/demo-app-pr-$n . Then: just pr-app"

# Open the pull request's app on localhost:8080, waiting until it is ready (default: last pr-open)
[group('3. Argo CD demo, one step at a time')]
pr-app number="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    n=$(resolve_pr "{{ number }}"); ns="pr-$n"
    show "kubectl -n $ns rollout status deploy/demo-app"
    start=$SECONDS; last=""; shown_argo=0
    until kubectl -n "$ns" rollout status deploy/demo-app --timeout=5s >/dev/null 2>&1; do
      if (( ! shown_argo && ! ${GUIDED:-0} )) && port_forward_running argocd && kubectl -n argocd get app "demo-app-pr-$n" >/dev/null 2>&1; then
        browse "https://localhost:8443/applications/argocd/demo-app-pr-$n"; shown_argo=1
      fi
      if ! kubectl get ns "$ns" >/dev/null 2>&1; then
        msg="Waiting for Argo CD to create namespace $ns (it checks GitHub every 30 seconds)"
      else
        reason=$(kubectl -n "$ns" get pods -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
        case "$reason" in
          ErrImagePull|ImagePullBackOff) msg="Waiting for GitHub Actions to finish building the image" ;;
          "") msg="Waiting for the app to start" ;;
          *) msg="Waiting for the app to start ($reason)" ;;
        esac
      fi
      [[ "$msg" != "$last" ]] && { doing "$msg"; last=$msg; }
      (( SECONDS - start > 600 )) && die "The app in $ns was not ready after 10 minutes. Check the Argo CD app demo-app-pr-$n."
      sleep 5
    done
    ok "App in $ns is ready"
    port_forward app "$ns" demo-app 8080 8080
    browse "http://localhost:8080"
    next "The banner shows $ns, pull request #$n and the commit. Then: just pr-tests"

# Follow the Argo CD hook that runs the Testkube tests for the pull request (default: last pr-open)
[group('3. Argo CD demo, one step at a time')]
pr-tests number="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    n=$(resolve_pr "{{ number }}")
    sha=$(gh pr view "$n" --repo "$GH_REPO" --json headRefOid --jq .headRefOid) || die "Could not read pull request #$n from GitHub."
    sha7=${sha:0:7}; job="e2e-pr-$n-$sha7"
    start=$SECONDS; said=0
    until kubectl -n demo-ops get job "$job" >/dev/null 2>&1; do
      # Hook jobs delete themselves an hour after finishing. If Argo CD already finished
      # this commit's sync, point at the Testkube execution instead.
      read -r phase rev < <(kubectl -n argocd get app "demo-app-pr-$n" \
        -o jsonpath='{.status.operationState.phase} {.status.operationState.syncResult.revision}' 2>/dev/null || true) || true
      if [[ "$rev" == "$sha" && "$phase" =~ ^(Succeeded|Failed|Error)$ ]]; then
        exe=$(testkube get testworkflowexecution -w demo-app-e2e --tag "pr=$n" --tag "sha=$sha7" --limit 1 -o json 2>/dev/null)
        id=$(jq -r '.[0].id // empty' <<<"$exe"); status=$(jq -r '.[0].result.status // empty' <<<"$exe")
        ok "Tests for #$n at $sha7 already finished: $status (Argo CD sync: $phase)"
        [[ -n "$id" ]] && browse "$(tk_execution_url demo-app-e2e "$id")"
        next "The Testkube execution is tagged pr=$n and sha=$sha7. In Argo CD, demo-app-pr-$n shows the sync as $phase."
        exit 0
      fi
      ((said)) || { doing "Waiting for Argo CD to start the test hook (it runs once the app is healthy)"; said=1; }
      (( SECONDS - start > 900 )) && die "No test hook after 15 minutes. Check the Argo CD app demo-app-pr-$n."
      sleep 5
    done
    show "kubectl -n demo-ops logs -f job/$job"
    until kubectl -n demo-ops logs -f "job/$job" 2>/dev/null | while IFS= read -r line; do
            printf '%s\n' "$line"
            if [[ "$line" == https://app.testkube.io/* ]]; then browse "$line"; fi
          done; do sleep 3; done
    # The log stream ends a moment before the job records its result.
    result=""
    for _ in $(seq 1 30); do
      result=$(kubectl -n demo-ops get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null || true)
      [[ -n "$result" ]] && break
      sleep 1
    done
    if [[ "$(kubectl -n demo-ops get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
      next "The demo-app-e2e execution is tagged pr=$n and sha=$sha7. In Argo CD, demo-app-pr-$n shows the sync as Succeeded. Then: just pr-close"
    else
      next "Show the failing test in the Testkube execution. In Argo CD, demo-app-pr-$n shows the sync as Failed, with the hook as the failed step."
    fi

# Close the pull request; Argo CD then deletes its environment (default: last pr-open)
[group('3. Argo CD demo, one step at a time')]
pr-close number="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    n=$(resolve_pr "{{ number }}")
    labels=$(gh pr view "$n" --repo "$GH_REPO" --json labels --jq '[.labels[].name] | join(" ")') || die "Could not read pull request #$n from GitHub."
    [[ " $labels " == *" $LIVE_LABEL "* ]] || die "Pull request #$n was not opened by just pr-open, so it may be a fallback. Close it by hand if you mean to: gh pr close $n"
    stop_port_forward app
    run gh pr close "$n" --repo "$GH_REPO" --delete-branch
    [[ "$(cat "$STATE_DIR/last-pr" 2>/dev/null)" == "$n" ]] && rm -f "$STATE_DIR/last-pr"
    next "Argo CD deletes demo-app-pr-$n within 30 seconds. Namespace pr-$n takes about 3 minutes to finish terminating; watch it in the pod watch (just watch)."

# ===== After the call ======================================================

# Close pull requests opened during the demo and stop port-forwards (`keep-argocd` keeps the Argo CD UI)
[group('4. After the call')]
reset keep="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    keep="{{ keep }}"
    [[ -z "$keep" || "$keep" == "keep-argocd" ]] || die "Unknown option '$keep'. Use nothing or: keep-argocd"
    prs=$(live_prs)
    if [[ -z "$prs" ]]; then ok "No live pull requests open"; fi
    for n in $prs; do run gh pr close "$n" --repo "$GH_REPO" --delete-branch; done
    for f in "$STATE_DIR"/pf-*.pid; do
      [[ -e "$f" ]] || continue
      name=$(basename "$f" .pid); name=${name#pf-}
      [[ "$name" == "argocd" && "$keep" == "keep-argocd" ]] && continue
      stop_port_forward "$name"; ok "Stopped port-forward: $name"
    done
    rm -f "$STATE_DIR/last-pr"
    git fetch -q --prune origin 2>/dev/null || true
    echo
    set +e
    leftover_namespaces; left=$?
    set -e
    if ((left == 0)); then ok "No leftover namespaces"
    elif [[ -n "$prs" ]]; then info "Namespaces for the pull requests just closed take about 3 minutes to go. Check again with: just doctor"; fi
