# Setup

Everything needed to go from a laptop to a working demo of both paths. Steps marked *once* only need doing on a fresh machine.

Tools: colima (or Docker Desktop), minikube, kubectl, Helm, the Testkube CLI, and the GitHub CLI.

## 1. Size the cluster (once)

minikube runs inside Docker, so Docker's virtual machine needs room for minikube's 4 CPUs and 8 GB, plus headroom.

With colima:

```sh
colima start --cpu 8 --memory 12
minikube start --cpus 4 --memory 8192
```

With Docker Desktop, set Settings > Resources to at least 8 CPUs and 12 GB first, then run the same `minikube start`.

If minikube already exists at a smaller size, it keeps its old size on restart. Either recreate it (`minikube delete`, then `minikube start` as above), or resize the existing container in place:

```sh
minikube stop
colima stop && colima start --cpu 8 --memory 12
docker update --cpus 4 --memory 8g --memory-swap 8g minikube
# In ~/.minikube/profiles/minikube/config.json set "Memory": 8192 and "CPUs": 4
minikube start
```

## 2. Install a Testkube runner in minikube (once)

Log in to Testkube and create a runner in the environment you will demo from:

```sh
testkube login
testkube install runner <runner-name> --create --env <environment-id> --namespace testkube
```

The demo assumes the runner is called `jf-minikube`. If yours has another name, change `testkubeHook.runner` in `chart/demo-app/values.yaml` and pick that runner when you run workflows from the dashboard.

## 3. Install Argo CD (once)

Pinned to v3.6.1:

```sh
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

Open the Argo CD UI:

```sh
kubectl -n argocd port-forward svc/argocd-server 8443:443
# https://localhost:8443  user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 4. Create the two secrets (once)

Tokens are typed at a prompt, so they never land in shell history or in this repo.

**GitHub token** for the ApplicationSet's pull request generator. Create a fine-grained personal access token with access to this repository only, and permission *Pull requests: Read-only*. Anonymous access works for a public repo but hits GitHub's rate limit when polling every 30 seconds.

```sh
read -s "GH?GitHub token: " && kubectl create secret generic github-token -n argocd --from-literal=token="$GH"; unset GH
```

**Testkube API token** for the Argo CD post-sync hook. Create an API token in the Testkube dashboard that can run workflows in the demo environment.

```sh
kubectl create namespace demo-ops
read -s "TK?Testkube API token: " && kubectl create secret generic testkube-api -n demo-ops \
  --from-literal=token="$TK" \
  --from-literal=org-id=<organization-id> \
  --from-literal=env-id=<environment-id>; unset TK
```

(`read -s "VAR?prompt"` is zsh syntax. In bash use `read -s -p "prompt" VAR`.)

## 5. Make the app image pullable (once)

GitHub Actions pushes the image to `ghcr.io/jfortunati/ephemeral-env-demo`. The package is public, so minikube pulls it without credentials. If it is private, either make it public under the package's *Package settings > Danger Zone > Change visibility*, or create an image pull secret in each target namespace and reference it from the chart.

## 6. Apply RBAC and the Testkube workflows

```sh
kubectl apply -f deploy/testkube/rbac.yaml
testkube create testworkflowtemplate -f testkube/playwright-e2e-template.yaml --update
testkube create testworkflow -f testkube/demo-app-e2e.yaml --update
testkube create testworkflow -f testkube/demo-app-ephemeral.yaml --update
```

## 7. Apply the Argo CD ApplicationSet

```sh
kubectl apply -f deploy/argocd/applicationset.yaml
kubectl get applicationset -n argocd demo-app-pull-requests
```

From now on, every open pull request gets an Argo CD Application named `demo-app-pr-<number>`.

## 8. Pre-pull images (before each demo)

Saves a minute or more on the first run:

```sh
minikube image pull mcr.microsoft.com/playwright:v1.65.1-noble
minikube image pull alpine/k8s:1.37.2
minikube image pull kubeshop/testkube-cli:2.15.2
minikube image pull ghcr.io/jfortunati/ephemeral-env-demo:main
```

## Check it works

```sh
testkube run testworkflow demo-app-ephemeral --target name=jf-minikube -f
```

The run should deploy into `tk-<execution id>`, pass the tests, and leave no `tk-` namespace behind (`kubectl get ns`).
