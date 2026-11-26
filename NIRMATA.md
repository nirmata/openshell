# Nirmata build of OpenShell

This fork adds declarative sandboxes for Kubernetes: the `OpenShellSandbox`,
`OpenShellSandboxTemplate`, and `OpenShellProvider` resources in
`openshell.ai/v1alpha1`, a controller that applies them to a gateway
workspace, and the gateway changes the controller depends on. Everything else
is upstream [OpenShell](https://github.com/ai-openshell/openshell).

The resources are experimental, and their fields can change.

## Install

The controller needs this fork's gateway, which adds workspace managers and
sandbox deletes pinned to an ID. The sandbox and supervisor images are
upstream's, for the commit this fork is based on.

```shell
helm install openshell oci://ghcr.io/nirmata/charts/openshell --version VERSION \
  --namespace openshell --create-namespace
helm install openshell-controller oci://ghcr.io/nirmata/charts/openshell-k8s-controller \
  --version VERSION --namespace openshell-system --create-namespace \
  --set watchNamespace=agents \
  --set gateway.url=https://openshell.openshell.svc:8080 \
  --set gateway.workspace=agents \
  --set gateway.tls.secretName=openshell-controller-tls
```

[examples/kubernetes-sandbox-crd](examples/kubernetes-sandbox-crd/README.md)
walks through the whole setup, and
[deploy/helm/openshell-k8s-controller](deploy/helm/openshell-k8s-controller/README.md)
lists the controller chart's values.

## Patches

`nirmata/main` is upstream `main` plus these changes, in this order. Keep each
one a single commit so the branch rebases cleanly.

| Change | Area |
|---|---|
| Per-workspace managers for sandboxes, templates, and providers | Gateway |
| The Kubernetes controller | Controller |
| Controller image and Helm chart | Packaging |
| Kubernetes sandbox walkthrough | Docs |
| Sandbox deletes pinned to an expected sandbox ID | Gateway, proto |
| Policy, providers, and `stopped` editable in place | Controller |
| Raw manifests removed in favor of the chart | Packaging |
| In-cluster runbook against a gateway built from the checkout | Tests |
| Nirmata images, charts, and release workflow | Fork only |
| Gateway image built with vendored Z3 | Packaging |
| Argo CD delivery check in the runbook | Tests |

## Release

Push a tag such as `v0.1.11-nirmata.1` on `nirmata/main`.
`.github/workflows/nirmata-release.yml` builds the gateway and controller
images for amd64 and arm64, pushes them to `ghcr.io/nirmata/openshell`, and
pushes both charts to `oci://ghcr.io/nirmata/charts`.

Before tagging, run the in-cluster runbook, which builds the gateway and
controller from the checkout:

```shell
E2E_ARGOCD=1 bash tasks/scripts/demo-k8s-controller-in-cluster.sh
```

## Sync with upstream

`main` mirrors upstream `main`; don't commit to it.

```shell
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout nirmata/main && git rebase main
cargo test -p openshell-k8s-controller
E2E_ARGOCD=1 bash tasks/scripts/demo-k8s-controller-in-cluster.sh
git push --force-with-lease origin nirmata/main
```

Regenerate `Cargo.lock` with `cargo build` if the rebase conflicts on it.
