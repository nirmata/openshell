# Run OpenShell sandboxes from Kubernetes

This runbook installs the Nirmata build of OpenShell on a Kubernetes cluster
and runs agent sandboxes declared as Kubernetes resources. It takes about 15
minutes on a cluster that meets the requirements.

The in-cluster runbook, `tasks/scripts/demo-k8s-controller-in-cluster.sh`,
runs the same steps against each release.

## How it fits together

- The **gateway** runs in namespace `openshell` and creates sandboxes as pods
  through Agent Sandbox.
- The **controller** runs in namespace `openshell-system`. It watches one
  namespace, `agents` in this runbook, and applies the `OpenShellSandbox`,
  `OpenShellSandboxTemplate`, and `OpenShellProvider` resources there to
  gateway workspace `agents`.
- The gateway lists the controller as the **workspace manager** of `agents`.
  Only the manager can change the sandboxes, templates, and providers in that
  workspace, so Kubernetes stays the source of truth.

## Before you start

You need:

- A Kubernetes cluster whose network plugin enforces NetworkPolicy, such as
  Cilium or Calico.
- [Agent Sandbox](https://github.com/kubernetes-sigs/agent-sandbox) v1.0.12 or
  later:

  ```shell
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.12/sandbox.yaml
  kubectl -n agent-sandbox-system rollout status deployment
  ```

- kubectl, Helm 3.8 or later, and the
  [OpenShell CLI](https://github.com/ai-openshell/openshell#install).

Set the release to install. Releases are listed under
[Tags](https://github.com/nirmata/openshell/tags), and their charts and images
are public:

```shell
VERSION=0.1.11-nirmata.rc3
```

## Install the gateway

List the identity that the controller connects with as the manager of
workspace `agents`. This runbook uses the client certificate that the chart
generates, `CN=openshell-client`:

```shell
cat > gateway-values.yaml <<'EOF'
gatewayConfig:
  openshell.gateway:
    workspace_managers:
      agents: ["mtls:openshell-client"]
EOF
helm install openshell oci://ghcr.io/nirmata/charts/openshell --version "$VERSION" \
  -f gateway-values.yaml --namespace openshell --create-namespace --wait --timeout 8m
```

The chart stores that certificate in Secret `openshell-client-tls`. For
production, issue the controller its own certificate from the gateway's client
CA, list its CN here instead, and make it an admin of the workspace.

## Connect the CLI

The gateway has no external address, so reach it through a port-forward. Run
this in a second terminal and leave it running:

```shell
kubectl -n openshell port-forward svc/openshell 18080:8080
```

Back in the first terminal, register the gateway as `k8s` with the chart's
client certificate, and create the workspace:

```shell
MTLS=~/.config/openshell/gateways/k8s/mtls
mkdir -p "$MTLS"
for f in ca.crt tls.crt tls.key; do
  kubectl -n openshell get secret openshell-client-tls \
    -o "jsonpath={.data.${f//./\\.}}" | base64 -d > "$MTLS/$f"
done
OPENSHELL_LOCAL_TLS_DIR=/nonexistent \
  openshell gateway add https://127.0.0.1:18080 --local --name k8s
openshell -g k8s status
openshell -g k8s workspace create --name agents
```

`status` shows `Status: Connected`. `OPENSHELL_LOCAL_TLS_DIR=/nonexistent`
stops the CLI from replacing the files you just copied with the certificate of
a gateway installed on your machine.

## Install the controller

Run the controller in its own namespace. If it ran in `agents`, deleting that
namespace would delete the controller before it could clean up the gateway
sandboxes.

```shell
kubectl create namespace agents
kubectl create namespace openshell-system
kubectl -n openshell-system create secret generic gateway-tls \
  --from-file="$MTLS/ca.crt" --from-file="$MTLS/tls.crt" --from-file="$MTLS/tls.key"
helm install openshell-controller oci://ghcr.io/nirmata/charts/openshell-k8s-controller \
  --version "$VERSION" --namespace openshell-system --wait \
  --set watchNamespace=agents \
  --set gateway.url=https://openshell.openshell.svc:8080 \
  --set gateway.workspace=agents \
  --set gateway.tls.secretName=gateway-tls
kubectl -n openshell-system logs deployment/openshell-controller-openshell-k8s-controller
```

The chart also installs the three CRDs. The log shows `acquired Lease` once
the controller is running.

## Declare a sandbox

A provider supplies credentials, a template supplies the image and
environment, and a sandbox uses both. The gateway needs the GitHub provider
profile before it accepts a `github` provider, so import it first:

```shell
curl -fsSLO "https://raw.githubusercontent.com/nirmata/openshell/v$VERSION/providers/github.yaml"
openshell -g k8s provider profile import -f github.yaml --workspace agents
kubectl -n agents create secret generic github-token --from-literal=token=YOUR_TOKEN
kubectl apply -f - <<'EOF'
apiVersion: openshell.ai/v1alpha1
kind: OpenShellProvider
metadata:
  name: github
  namespace: agents
spec:
  type: github
  credentials:
    - name: GITHUB_TOKEN
      secretKeyRef:
        name: github-token
        key: token
---
apiVersion: openshell.ai/v1alpha1
kind: OpenShellSandboxTemplate
metadata:
  name: demo-agent
  namespace: agents
spec:
  image: nvcr.io/nvidia/base/ubuntu:24.04
  environment:
    AGENT_RELEASE: "1"
---
apiVersion: openshell.ai/v1alpha1
kind: OpenShellSandbox
metadata:
  name: support-agent
  namespace: agents
spec:
  templateRef:
    name: demo-agent
  providers: [github]
EOF
kubectl -n agents wait --for=condition=Ready osprov/github ossbxt/demo-agent --timeout=120s
kubectl -n agents wait --for=condition=Ready ossbx/support-agent --timeout=400s
kubectl -n agents get osprov,ossbxt,ossbx
```

The token stays in the Kubernetes Secret; no resource's spec or status
contains it. The controller sends it to the gateway, which stores it and adds
it to the sandbox's outbound requests.

Run a command in the sandbox:

```shell
NAME=$(kubectl -n agents get ossbx support-agent -o jsonpath='{.status.sandboxName}')
openshell -g k8s sandbox exec "$NAME" --workspace agents --no-tty -- echo hello
```

## Change a sandbox

You can change `policy`, `providers`, and `stopped` on a running sandbox. The
controller applies the change to the gateway and records it in
`status.applied`:

```shell
kubectl -n agents patch ossbx support-agent --type=merge -p '{"spec":{"stopped":true}}'
kubectl -n agents get ossbx support-agent -o jsonpath='{.status.gatewayPhase}{"\n"}'
kubectl -n agents patch ossbx support-agent --type=merge -p '{"spec":{"stopped":false}}'
```

`gatewayPhase` reports `Stopped`, then `Ready` again after you clear
`stopped`.

`templateRef`, `workload`, `command`, `restartPolicy`, and `serviceExposures`
can't change. To run a different workload, create a new sandbox. Changing a
template publishes a new revision: new sandboxes use it, and running sandboxes
keep the revision they started with.

## Deliver sandboxes with Argo CD

Argo CD syncs, diffs, and prunes these resources like any other. Add a health
check to ConfigMap `argocd-cm` in namespace `argocd`, so that Argo CD waits
for the controller:

```yaml
data:
  resource.customizations.health.openshell.ai_OpenShellSandbox: |
    hs = { status = "Progressing", message = "Waiting for the controller" }
    if obj.status ~= nil and obj.status.observedGeneration == obj.metadata.generation then
      for _, condition in ipairs(obj.status.conditions or {}) do
        if condition.type == "Ready" then
          hs.message = condition.message
          if condition.status == "True" then
            hs.status = "Healthy"
          elseif obj.status.phase == "Blocked" then
            hs.status = "Degraded"
          end
        end
      end
    end
    return hs
```

Then point an Application with destination namespace `agents` at the Git path
or chart that holds your resources. With
`syncPolicy: { automated: { prune: true, selfHeal: true } }`:

- The Application is `Healthy` once every sandbox is `Ready`, and `Degraded`
  while one is blocked.
- An edit made outside Git makes the Application `OutOfSync`, and Argo CD
  restores the declared spec.
- Removing a sandbox from Git deletes it. Its finalizer holds the resource
  until the gateway sandbox is gone.

## Troubleshoot

Start with the resource's status and the controller log:

```shell
kubectl -n agents get ossbx support-agent -o jsonpath='{.status.phase} {.status.reason}{"\n"}'
kubectl -n openshell-system logs deployment/openshell-controller-openshell-k8s-controller
```

`Progressing` means the controller is retrying by itself. `Blocked` means you
need to act:

| Reason | What to do |
|---|---|
| `TemplateNotFound` | Create the template that `templateRef.name` names, in the sandbox's namespace. |
| `TemplateNamespaceNotAllowed` | Templates must be in the sandbox's namespace. Remove `templateRef.namespace`. |
| `ProviderNotFound` | Create the `OpenShellProvider`, or the gateway provider, that `providers` names. |
| `SecretNotFound` | Create the Secret and key that the provider's `secretKeyRef` names. |
| `PolicyInvalid` | Fix `spec.policy`; the gateway rejected it. |
| `UpdateRejected` | The gateway refused a change to `policy` or `providers`. Correct the spec. |
| `CreateRejected`, `PublishRejected`, `ProviderRejected` | Check that `workspace_managers` lists the controller's certificate CN for this workspace. |
| `NameCollision` | A gateway object with this name exists, and the controller didn't create it. Rename the resource. |
| `IdentityMismatch` | The gateway sandbox with this name was replaced outside the controller. Delete and recreate the resource. |

## Uninstall

Delete the resources first, so that the controller removes the gateway
objects:

```shell
kubectl delete namespace agents
helm uninstall openshell-controller -n openshell-system
helm uninstall openshell -n openshell
openshell gateway remove k8s
```

Helm keeps the CRDs. Deleting them also deletes every remaining resource of
these kinds:

```shell
kubectl delete crd openshellsandboxes.openshell.ai \
  openshellsandboxtemplates.openshell.ai openshellproviders.openshell.ai
```
