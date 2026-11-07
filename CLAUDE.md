# CLAUDE.md

## What this repo is
**Sandbox** is a Kubernetes-first platform for dev environments. Each workspace is a pod built from a repo's `devcontainer.json`. VS Code Desktop connects over Remote-SSH, and CI runs through ARC using the same images. It's inspired by Coder, but has no Coder dependency, no VMs and no provisioner.

The full design and roadmap are in [docs/plan.md](docs/plan.md). Read it before you start any phase. Image builds are done by [DeepSpaceCartel/devcontainer-builder](https://github.com/DeepSpaceCartel/devcontainer-builder), which lives in its own repo; changes to the builder go there.

## Where things run
- **The workbench** is the Coder workspace on the Coder cluster. It's where code is written and tools are run. Never change anything on the Coder cluster from here. This workspace has no RBAC there on purpose.
- **Test environments** are disposable Talos clusters named `sbx-<ENV>`, in the Hetzner project **`sandbox-dev`**. Each one has its DNS under `<ENV>.sandbox.deepspacecartel.com`.
  - `KUBECONFIG` and `TALOSCONFIG` must point only at `sbx-*` clusters. Check `kubectl config current-context` before anything that changes state.
  - The default `ENV` comes from the git branch or worktree, so parallel sessions get separate environments. Never reuse another session's `ENV`.
  - Environments labelled `pinned=true` are off-limits unless the user says otherwise. Ask before raising node-pool maximums.

## Credentials
- All secrets come from the 1Password vault `Sandbox Dev`, through `op run --env-file=.env.1password -- <cmd>`. `.env.1password` holds only `op://` references, never values.
- Never print, log or commit secret values. Never put them in command arguments or URLs: use env vars or files that only the owner can read.
- The manual prerequisites are in [docs/setup/manual-prerequisites.md](docs/setup/manual-prerequisites.md). Claude doesn't create accounts or tokens.

## Commands
The Makefile targets are scaffolded in phase −1. Until a target is implemented, it fails with "not implemented".
```sh
make env-up   ENV=<name>   # infra/cluster → infra/platform (Terraform, ~10–15 min)
make env-down ENV=<name>   # teardown script (clears autoscaler nodes) → platform → cluster
make env-list              # Hetzner resources labelled with an env
make deploy   ENV=<name>   # build images via the env's BuildKit → its Harbor → helm upgrade charts/sandbox
make e2e      ENV=<name>   # e2e suite against that env
```

## Conventions
- **Go** for `cmd/*` and `pkg/*`. The operator uses kubebuilder and controller-runtime. **TypeScript** for `web/`, `vscode-extension/` and the JavaScript actions.
- **Terraform** for `infra/`, following the existing Coder cluster setup: separate cluster and platform stacks, the `hcloud-k8s/kubernetes/hcloud` module, a Route53 DNS-01 ClusterIssuer, and one Gateway with a wildcard cert. Apply cluster → platform, and destroy in reverse.
- **Tests run against real infrastructure**, using the builder repo's `disposable-k8s-test-fixtures` pattern: real Helm-deployed fixtures, one namespace per test worker, and real teardown. Unit tests (`pkg/podspec` golden tests, envtest) must run without a cluster.
- **ADRs** go in `docs/decisions/NNNN-*.md`, in the same format the builder repo uses.
