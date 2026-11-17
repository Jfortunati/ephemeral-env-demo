# Demo runbook

Two ways to test in a short-lived environment, using the same app, Helm chart and Playwright tests.

## Before the demo

- [ ] `minikube status` shows everything Running; `kubectl get pods -n testkube` shows the runner Running.
- [ ] Pre-pull images (SETUP.md step 8).
- [ ] Open tabs: the Testkube dashboard, the Argo CD UI (`kubectl -n argocd port-forward svc/argocd-server 8443:443`), the GitHub repository, and a terminal.
- [ ] No leftover pull request environments: `kubectl get ns | grep -E '^(pr|tk)-'` shows only the pull requests you intend to keep open.
- [ ] Fallback runs exist (see the end of this page).

## Path 2: Testkube deploys and tests

One Testkube workflow creates the environment, tests it and removes it.

1. In the Testkube dashboard, open the workflow **demo-app-ephemeral**.
2. Show its definition: three steps (Provision environment, Run end-to-end tests, Tear down environment), the `tk-{{ execution.id }}` namespace, and `condition: always` on teardown.
3. Optionally show `deploy/testkube/rbac.yaml` in GitHub: the workflow runs under its own service account, limited to the resource types the chart contains.
4. Click **Run**, choose the runner **jf-minikube**, keep the defaults (image tag `main`, Git revision `main`).
5. While it runs, in the terminal: `kubectl get ns -w | grep tk-` shows the namespace appear.
6. Walk through the steps as they finish:
   - **Provision environment**: the log lists the namespace, chart version, image and Git revision. This is the record of exactly what was tested.
   - **Run end-to-end tests**: the test cases, the Playwright report and (on failure) screenshots and traces under Artifacts.
   - **Tear down environment**: the namespace is deleted. The `kubectl get ns -w` window shows it terminate.

**Showing cleanup on failure:** run it again with Git revision `demo/failing-test`. That branch expects a page title the app doesn't have, so one test fails, a screenshot is saved, and teardown still removes the namespace.

## Path 1: Argo CD deploys, Testkube tests

Each open pull request gets its own namespace, `pr-<number>`.

1. **Open a pull request.** Make a small change on a new branch, e.g. edit a seed item in `app/server.js`, and open a pull request against `main`.
2. **Image build.** In GitHub's *Actions* tab, *Build app image* runs and pushes `ghcr.io/jfortunati/ephemeral-env-demo:sha-<commit>`. About 1.5 minutes.
3. **Argo CD picks it up.** Within 30 seconds an Application `demo-app-pr-<number>` appears in the Argo CD UI. If it appears before the image build finishes, the pod waits on the image for a moment, then starts once the image exists.
4. **Show the environment.** In a terminal:
   ```sh
   kubectl -n pr-<number> port-forward svc/demo-app 8080:8080
   ```
   Open http://localhost:8080. The banner shows `pr-<number>`, the pull request number and the commit.
5. **Tests start automatically.** When the app is healthy, Argo CD runs the post-sync hook job `e2e-pr-<number>-<commit>` in the `demo-ops` namespace (`kubectl logs -n demo-ops job/e2e-pr-<number>-<commit>`). Its log prints a link to the Testkube execution and the final result. Old hook jobs delete themselves after an hour. In Testkube, the **demo-app-e2e** execution is tagged `pr=<number>` and `sha=<commit>`; the banner test checks that the right environment was tested.
6. **Close the pull request.** Argo CD notices within 30 seconds and deletes the Application. The namespace takes a little longer to finish terminating; allow about 3 minutes before `kubectl get ns` no longer shows `pr-<number>`. `kubectl get ns -w | grep pr-` shows it happen.

**Showing a failing pull request:** pull request *Expect a new page title* (branch `demo/failing-test`) changes a test without changing the app. Its tests fail in Testkube, and the Argo CD Application shows the sync as failed, with the hook job as the failed step.

## Fallback

If anything stalls live, show finished runs instead:

- Testkube: the latest passing and failing **demo-app-ephemeral** executions, and a **demo-app-e2e** execution tagged with a pull request.
- Argo CD: keep the passing and failing pull requests open, so their Applications and `pr-<number>` namespaces are already there to show.

## Reset after the demo

```sh
gh pr close <number>                            # removes pr-<number> within about 3 minutes
kubectl get ns | grep -E '^(pr|tk)-'            # should list only pull requests still open
```
