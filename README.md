# Ephemeral environment testing demo

One small web app and one Playwright test suite, deployed and tested in short-lived Kubernetes environments two ways:

1. **Argo CD deploys, Testkube tests.** Each open pull request gets its own namespace (`pr-<number>`), deployed by an Argo CD ApplicationSet. An Argo CD post-sync hook starts a Testkube workflow that runs the Playwright tests against that namespace. Closing the pull request removes the namespace.
2. **Testkube deploys and tests.** One Testkube workflow installs the app from the Helm chart into a fresh namespace, runs the same tests, and removes the namespace whether or not the tests passed.

| Path | Contents |
| --- | --- |
| `app/` | Express app, static UI, Dockerfile |
| `chart/demo-app/` | Helm chart used by both Argo CD and Testkube |
| `tests/e2e/` | Playwright tests |
| `testkube/` | Testkube workflows and the shared Playwright template |
| `deploy/argocd/` | Argo CD ApplicationSet |
| `deploy/testkube/` | RBAC for the provisioning workflow |
| `.github/workflows/` | Image build |
| `docs/` | Setup and demo runbook |
| `justfile`, `scripts/` | Demo commands: run `just` for a menu |
| `Brewfile` | Tools, installed with `brew bundle` |

## Demo commands

```sh
brew bundle      # install the tools
just doctor      # check everything the demo needs
just             # pick demo steps from a menu
```

See [docs/DEMO-RUNBOOK.md](docs/DEMO-RUNBOOK.md) for what each step shows.

## Run locally

```sh
docker build -t demo-app:local app
docker run -p 8080:8080 -e ENV_NAME=local demo-app:local

cd tests/e2e
npm ci
npx playwright install chromium
BASE_URL=http://localhost:8080 npx playwright test
```
