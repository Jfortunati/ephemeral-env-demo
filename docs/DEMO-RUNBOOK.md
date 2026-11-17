# Demo runbook

Two ways to test in a short-lived environment, using the same app, Helm chart and Playwright tests.

Every terminal step has a `just` command. Run `just` to pick from a menu, or `just --list` to see them all. Each command prints the real commands it runs and ends with a `→ Next:` line saying what to show next.

## Before the demo

- [ ] `just doctor` reports *All ready*. It checks the cluster, the logins, the Testkube runner, Argo CD, the secrets, the Testkube workflows, the pre-pulled images, leftover namespaces and the fallback runs, and prints the fix for anything missing. It changes nothing.
- [ ] `just links` prints every URL (Testkube, Argo CD, GitHub), starts the Argo CD UI port-forward, and copies the Argo CD admin password to the clipboard.
- [ ] Open tabs: the Testkube dashboard, the Argo CD UI, the GitHub repository, and a terminal split in two panes (the second pane runs `just watch-tk` or `just watch-pr`).

## Path 2: Testkube deploys and tests

One Testkube workflow creates the environment, tests it and removes it.

1. In the Testkube dashboard, open the workflow **demo-app-ephemeral**.
2. Show its definition: three steps (Provision environment, Run end-to-end tests, Tear down environment), the `tk-{{ execution.id }}` namespace, and `condition: always` on teardown.
3. Optionally show `deploy/testkube/rbac.yaml` in GitHub: the workflow runs under its own service account, limited to the resource types the chart contains.
4. Click **Run**, choose the runner **jf-minikube**, keep the defaults (image tag `main`, Git revision `main`). `just run-ephemeral` prints the link and these settings; `just run-ephemeral cli` runs the same thing from the terminal as a backup.
5. While it runs, the second pane (`just watch-tk`) shows the namespace appear.
6. Walk through the steps as they finish:
   - **Provision environment**: the log lists the namespace, chart version, image and Git revision. This is the record of exactly what was tested.
   - **Run end-to-end tests**: the test cases, the Playwright report and (on failure) screenshots and traces under Artifacts.
   - **Tear down environment**: the namespace is deleted. The `kubectl get ns -w` window shows it terminate.

**Showing cleanup on failure:** run it again with Git revision `demo/failing-test` (`just run-failing`). That branch expects a page title the app doesn't have, so one test fails, a screenshot is saved, and teardown still removes the namespace.

## Path 1: Argo CD deploys, Testkube tests

Each open pull request gets its own namespace, `pr-<number>`.

1. **Open a pull request.** `just pr-open` adds a timestamp to one seed item in `app/server.js` on a new branch and opens a pull request against `main`, labeled `demo-live`. It works in a temporary checkout, so your own checkout is untouched.
2. **Image build.** In GitHub's *Actions* tab, *Build app image* runs and pushes `ghcr.io/jfortunati/ephemeral-env-demo:sha-<commit>`. About 1.5 minutes.
3. **Argo CD picks it up.** Within 30 seconds an Application `demo-app-pr-<number>` appears in the Argo CD UI. If it appears before the image build finishes, the pod waits on the image for a moment, then starts once the image exists.
4. **Show the environment.** `just pr-app` waits until the app is ready (saying whether it is waiting on Argo CD or on the image build), then port-forwards it. Open http://localhost:8080. The banner shows `pr-<number>`, the pull request number and the commit.
5. **Tests start automatically.** `just pr-tests` waits for the hook and follows its log. When the app is healthy, Argo CD runs the post-sync hook job `e2e-pr-<number>-<commit>` in the `demo-ops` namespace (`kubectl logs -n demo-ops job/e2e-pr-<number>-<commit>`). Its log prints a link to the Testkube execution and the final result. Old hook jobs delete themselves after an hour. In Testkube, the **demo-app-e2e** execution is tagged `pr=<number>` and `sha=<commit>`; the banner test checks that the right environment was tested.
6. **Close the pull request.** `just pr-close`. Argo CD notices within 30 seconds and deletes the Application. The namespace takes a little longer to finish terminating; allow about 3 minutes before `kubectl get ns` no longer shows `pr-<number>`. The second pane (`just watch-pr`) shows it happen.

`pr-app`, `pr-tests` and `pr-close` default to the last pull request `just pr-open` created. Pass a number to use another, e.g. `just pr-tests 1` for a fallback pull request. `pr-close` refuses to close a pull request without the `demo-live` label, so the fallbacks stay open.

**Showing a failing pull request:** pull request *Expect a new page title* (branch `demo/failing-test`) changes a test without changing the app. Its tests fail in Testkube, and the Argo CD Application shows the sync as failed, with the hook job as the failed step.

## Fallback

If anything stalls live, show finished runs instead:

- Testkube: the latest passing and failing **demo-app-ephemeral** executions, and a **demo-app-e2e** execution tagged with a pull request.
- Argo CD: keep the passing and failing pull requests open, so their Applications and `pr-<number>` namespaces are already there to show.

## Reset after the demo

`just reset` closes every pull request labeled `demo-live` and deletes its branch, stops the port-forwards these commands started, and lists any leftover `pr-` or `tk-` namespaces. The fallback pull requests have no label, so they stay open. `just reset keep-argocd` leaves the Argo CD UI port-forward running.

Namespaces of just-closed pull requests take about 3 minutes to go; `just doctor` afterwards confirms they are gone.
