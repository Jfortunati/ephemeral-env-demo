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

# Open the demo menu
[private]
default:
    @just --choose --unsorted

# ===== Before the call =====================================================

# Check that everything the demo needs is in place (changes nothing)
[group('1. Before the call')]
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

# Print every URL the demo uses, and start the Argo CD UI port-forward
[group('1. Before the call')]
links:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    if ! port_forward_running argocd; then
      port_forward argocd argocd argocd-server 8443 443 >/dev/null
    fi
    pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    echo
    printf '%sTestkube%s\n' "$BOLD" "$RESET"
    info "Dashboard                 $TK_DASHBOARD"
    info "demo-app-ephemeral        $(tk_workflow_url demo-app-ephemeral)"
    info "demo-app-e2e              $(tk_workflow_url demo-app-e2e)"
    printf '%sArgo CD%s\n' "$BOLD" "$RESET"
    info "UI                        https://localhost:8443   (accept the self-signed certificate)"
    if [[ -n "$pw" ]] && printf %s "$pw" | pbcopy 2>/dev/null; then
      info "Login                     admin  (password copied to the clipboard)"
    else
      info "Login                     admin  (password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
    fi
    printf '%sGitHub%s\n' "$BOLD" "$RESET"
    info "Repository                https://github.com/$GH_REPO"
    info "Actions (image builds)    https://github.com/$GH_REPO/actions"
    info "Pull requests             https://github.com/$GH_REPO/pulls"

# ===== Path 2: Testkube deploys and tests ==================================

# Second pane: watch tk- namespaces appear and disappear (Ctrl-C to stop)
[group('2. Path 2: Testkube deploys and tests')]
watch-tk:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    show "kubectl get ns -w | grep tk-"
    kubectl get ns -w | grep --line-buffered -E '^(NAME|tk-)'

# Show how to run demo-app-ephemeral from the dashboard (or `just run-ephemeral cli` to run it here)
[group('2. Path 2: Testkube deploys and tests')]
run-ephemeral mode="": (_ephemeral "main" mode)

# Same, on the branch with a failing test, to show teardown still runs (`cli` to run it here)
[group('2. Path 2: Testkube deploys and tests')]
run-failing mode="": (_ephemeral "demo/failing-test" mode)

[private]
_ephemeral revision mode:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    rev="{{ revision }}"; mode="{{ mode }}"
    cli=(testkube run testworkflow demo-app-ephemeral --config imageTag=main --config "gitRevision=$rev" --target "name=$RUNNER" -f)
    if [[ "$rev" == "main" ]]; then
      cue="Walk through Provision (namespace, chart, image and revision in the log), the test results, then Teardown. The tk- namespace disappears in the watch-tk pane."
    else
      cue="One test fails and its screenshot is under Artifacts. Point at Teardown: it still ran, and the tk- namespace is gone from the watch-tk pane."
    fi
    case "$mode" in
      "")
        printf '%sRun this from the Testkube dashboard:%s\n' "$BOLD" "$RESET"
        info "Workflow       $(tk_workflow_url demo-app-ephemeral)"
        info "Click Run, then set:"
        info "  Runner       $RUNNER"
        info "  imageTag     main"
        info "  gitRevision  $rev"
        echo
        printf '%sBackup, from this terminal:%s just %s cli\n' "$DIM" "$RESET" "$([[ $rev == main ]] && echo run-ephemeral || echo run-failing)"
        next "While it runs (about 2 minutes), show the tk- namespace appear in the second pane (just watch-tk). $cue" ;;
      cli)
        run "${cli[@]}" || true
        next "$cue Same run in the dashboard: $(tk_workflow_url demo-app-ephemeral)" ;;
      *)
        die "Unknown option '$mode'. Use nothing (dashboard) or: cli" ;;
    esac

# ===== Path 1: Argo CD deploys, Testkube tests =============================

# Open a pull request with a small visible change to the app
[group('3. Path 1: Argo CD deploys, Testkube tests')]
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
    next "GitHub Actions builds the image (about 1.5 minutes): https://github.com/$GH_REPO/actions . Within 30 seconds the Argo CD app demo-app-pr-$n appears: https://localhost:8443/applications/argocd/demo-app-pr-$n . Then: just pr-app"

# Second pane: watch pr- namespaces appear and disappear (Ctrl-C to stop)
[group('3. Path 1: Argo CD deploys, Testkube tests')]
watch-pr:
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    show "kubectl get ns -w | grep pr-"
    kubectl get ns -w | grep --line-buffered -E '^(NAME|pr-)'

# Open the pull request's app on localhost:8080, waiting until it is ready (default: last pr-open)
[group('3. Path 1: Argo CD deploys, Testkube tests')]
pr-app number="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    n=$(resolve_pr "{{ number }}"); ns="pr-$n"
    show "kubectl -n $ns rollout status deploy/demo-app"
    start=$SECONDS; last=""
    until kubectl -n "$ns" rollout status deploy/demo-app --timeout=5s >/dev/null 2>&1; do
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
    ok "http://localhost:8080"
    next "Open http://localhost:8080 . The banner shows $ns, pull request #$n and the commit. Then: just pr-tests"

# Follow the Argo CD hook that runs the Testkube tests for the pull request (default: last pr-open)
[group('3. Path 1: Argo CD deploys, Testkube tests')]
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
        [[ -n "$id" ]] && info "$(tk_execution_url demo-app-e2e "$id")"
        next "Open the Testkube execution above: it is tagged pr=$n and sha=$sha7. In Argo CD, demo-app-pr-$n shows the sync as $phase."
        exit 0
      fi
      ((said)) || { doing "Waiting for Argo CD to start the test hook (it runs once the app is healthy)"; said=1; }
      (( SECONDS - start > 900 )) && die "No test hook after 15 minutes. Check the Argo CD app demo-app-pr-$n."
      sleep 5
    done
    show "kubectl -n demo-ops logs -f job/$job"
    until kubectl -n demo-ops logs -f "job/$job" 2>/dev/null; do sleep 3; done
    # The log stream ends a moment before the job records its result.
    result=""
    for _ in $(seq 1 30); do
      result=$(kubectl -n demo-ops get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null || true)
      [[ -n "$result" ]] && break
      sleep 1
    done
    if [[ "$(kubectl -n demo-ops get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
      next "Open the Testkube link above: the demo-app-e2e execution is tagged pr=$n and sha=$sha7. In Argo CD, demo-app-pr-$n shows the sync as Succeeded. Then: just pr-close"
    else
      next "Open the Testkube link above to show the failing test. In Argo CD, demo-app-pr-$n shows the sync as Failed, with the hook as the failed step."
    fi

# Close the pull request; Argo CD then deletes its environment (default: last pr-open)
[group('3. Path 1: Argo CD deploys, Testkube tests')]
pr-close number="":
    #!/usr/bin/env bash
    source scripts/demo-lib.sh
    n=$(resolve_pr "{{ number }}")
    labels=$(gh pr view "$n" --repo "$GH_REPO" --json labels --jq '[.labels[].name] | join(" ")') || die "Could not read pull request #$n from GitHub."
    [[ " $labels " == *" $LIVE_LABEL "* ]] || die "Pull request #$n was not opened by just pr-open, so it may be a fallback. Close it by hand if you mean to: gh pr close $n"
    stop_port_forward app
    run gh pr close "$n" --repo "$GH_REPO" --delete-branch
    [[ "$(cat "$STATE_DIR/last-pr" 2>/dev/null)" == "$n" ]] && rm -f "$STATE_DIR/last-pr"
    next "Argo CD deletes demo-app-pr-$n within 30 seconds. Namespace pr-$n takes about 3 minutes to finish terminating; watch it in the second pane (just watch-pr)."

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
