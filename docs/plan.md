# Sandbox: K8s-first dev environments driven by devcontainer.json

## Context
You want something like Coder, but without Coder. Coder carries VM and provisioner machinery, puts some features behind a premium plan, and has licence terms you don't want to depend on. Your setup only needs Kubernetes pods, defined by each repo's `devcontainer.json`.

The goals:
1. From a **browser UI or the VS Code extension**, open any repo you have access to, at a branch **or commit**, in **VS Code Desktop over Remote-SSH**.
2. Run **many services per workspace**, each reachable at its own URL.
3. Run CI on the same infrastructure, using the same image and the same pod mapping.
4. **Scale to about 1,000 developers in parallel** without them affecting each other, given enough hardware.

`DeepSpaceCartel/devcontainer-builder` (MIT) already does the hard build work. Its `service/` and Helm chart don't depend on Coder. The Coder-specific parts are `templates/coder-kubernetes/main.tf` (about 1,500 lines, including all of the devcontainer → pod mapping) and the Coder API calls in `vscode-extension/src/coder.ts` and `clone*.ts`.

**What you chose:**
- Desktop Remote-SSH only.
- Keycloak for login, with LDAP-backed usernames.
- GitHub repo access through a GitHub App, linked once per user with "Connect GitHub".
- GitHub Actions through ARC for CI.
- A Kubernetes operator with CRDs as the control plane.
- No in-pod agent: standard sshd, a shell entrypoint and Kubernetes Secrets.

## Architecture
```
Browser ─► Sandbox web UI ─┐                              Keycloak (LDAP)
VS Code ext ───────────────┼─► Sandbox API (N replicas) ─OIDC─┘
  │ Remote-SSH             │ writes CRDs · GitHub links · SSH pubkeys · CI build broker
  ▼                        ▼
SSH gateway (sshpiper ×N) ─► Workspace CRDs ◄── Operator (leader-elected) ─► Build queue ─► builder ×N ─► BuildKit pool ─► Harbor (HA, S3)
Service proxy (×N) ─────────┐        │
 *.ws.dev.example.com       ▼        ▼ ns ws-<user>: quota · NetworkPolicy · PSA
                  pod: sshd :2222 · your services :3000,:8080… · PVC · git-token Secret
CI: GitHub ─► ARC scale sets (ns ci, CI node pool) ─► job 1 build (via API broker) ─► job 2 container: <same image>
```

There will be a new monorepo, `DeepSpaceCartel/sandbox`, containing:
- `cmd/operator` (Go)
- `cmd/api` (Go)
- `cmd/sshpiper-plugin` (Go)
- `cmd/svc-proxy` (Go)
- `pkg/podspec` (Go)
- `web/` (TypeScript)
- `vscode-extension/`, moved over from the builder repo
- `charts/sandbox`
- `actions/build`
- `actions/exec`

### 1. devcontainer-builder (changes in its own repo)
- **Build by commit SHA.** `service/src/build.ts` currently runs `clone --depth 1 --branch`. Change it to `init` + `fetch <sha>`, and add a `commit` field to the `POST /build` schema in `service/src/schemas.ts`.
- **Inject sshd at build time.** Use `devcontainer build --additional-features` with `ghcr.io/devcontainers/features/sshd`, on by default. Also add sshd to the fallback image (ADR-0013).
- **Asynchronous builds.** Add `POST /builds` returning a build id, and `GET /builds/{id}`. Keep `POST /build` as a synchronous wrapper. Add bearer-token auth.
- **Tag images by config, not by commit.** The tag becomes `cfg-<hash>`, where the hash covers `.devcontainer/**`, the Dockerfile, the Features and any files that `build.context` references. If the context is the repo root, it falls back to `sha-<commit>`. Most commits then reuse an existing image, and a workspace opens with no build at all.
- **Run more than one replica.** Today there is one replica because logs live in that pod's memory. Move logs to object storage or ship them through the event log. Then run builder replicas against a **BuildKit pool**, with consistent hashing by repo so each repo's cache stays on one BuildKit.

### 2. Operator (kubebuilder, leader election, tuned worker concurrency)
- **CRDs:**
  - `Workspace` lives in `ws-<username>`. Its `spec` holds `owner`, `repo`, `ref` (a branch or SHA), `templateRef`, `running`, `idleTimeout` and `services[]`. Its `status` holds `commit`, `image`, `phase`, `conditions`, `sshHost`, `urls[]` and `lastActivity`.
  - `WorkspaceTemplate` is cluster-scoped and holds the policy: `allowPrivileged`, `allowNodePlacement`, resource caps, `storageClass`, the fallback image and the node pool.
  - `UserQuota` is cluster-scoped: the maximum number of running workspaces, CPU, memory and storage per user, plus a **CI budget** (concurrent jobs, and CPU-hours per month).
  - `Component` is cluster-scoped. It maps a repo (with optional path globs) to an owning **team**, which is a Keycloak group. It can also be synced from the `CODEOWNERS` default owner.
  - `TeamQuota` is cluster-scoped and gives a team its CI budget, for automated runs.
- **Reconcile loop:**
  1. Resolve the ref to a SHA.
  2. Get an image from the build queue (a cache hit or a build).
  3. `GET /devcontainer`.
  4. Create a PVC (`home/`, `workspaces/`, `volumes/`) and a git-token Secret.
  5. Create a StatefulSet with one replica. Its init containers seed home and clone at the SHA. The main container runs the entrypoint script.
  6. Create a headless Service exposing 2222 plus each service port.
- **The user's namespace** gets a ResourceQuota and a LimitRange from `UserQuota`, a default-deny NetworkPolicy and Pod Security Admission labels.
- **Ongoing jobs:** refresh tokens, stop idle workspaces (scale to 0 and keep the PVC), rebuild when the config hash changes, delete workspaces stopped for more than N days (configurable), and clean up unused images.

### 3. `pkg/podspec`: one place that turns devcontainer.json into a pod
**What it is.** A pure Go function with no cluster access, so it's easy to test:
```go
Render(meta DevcontainerMetadata,   // GET /devcontainer: runtime, user uid/gid/home, mounts, runArgs, hostRequirements, customizations.kubernetes
       policy WorkspaceTemplate,    // cluster policy: privileged?, node placement?, caps, storageClass, node pool, runtimeClass
       budget Budget,               // remaining quota of the user or team
       mode  Mode)                  // Workspace | CIJob
  -> Result{ PodTemplate corev1.PodTemplateSpec, PVC *corev1.PersistentVolumeClaimSpec,
             Ports []ServicePort, Warnings []string, Rejections []string }
```

**What it maps**, ported from the Terraform locals in `main.tf`:
- `remoteUser` → `runAsUser`, `runAsGroup` and `fsGroup`.
- `mounts` → PVC subpaths or an `emptyDir`.
- The allowed `runArgs`: caps, `--init` → shared process namespace, `--shm-size` → a memory `emptyDir` at `/dev/shm`, `--add-host` → `hostAliases`.
- `hostRequirements` as minimums, and `customizations.kubernetes` (resources, storage, nodeSelector, tolerations), with each value clamped to the policy and the budget (ADR-0012, ADR-0014, ADR-0015).

Anything unsupported or not allowed comes back as a `Warning` or a `Rejection`, never silently dropped.

**Who calls it:**
1. **Operator, for workspaces.** Its output becomes the StatefulSet's pod template, the PVC and the Service ports.
2. **CI admission webhook** (part of the operator). Job pods that ARC creates in `ci` are intercepted. The webhook reads the job container's image, fetches that image's devcontainer metadata, and patches the pod with `Render(…, mode=CIJob)`: the same user, caps, shm and resources, within the runner's size-class cap. This is how CI matches the workspace exactly, even though ARC's hook template is static.
3. **API `POST /devcontainer/preview`.** The web UI and the extension show "this is how your devcontainer.json will run", with its warnings, before anything is created. `actions/build` prints the same preview into the CI log.

**Tests.** Table tests based on `docs/reference/devcontainer-json.md`, with golden YAML files per case.

### 4. In the pod (no agent)
- **Entrypoint script** (`/bin/sh`, from a ConfigMap): sources the env scripts, then runs the lifecycle hooks. Marker files on the PVC make `onCreate`/`postCreate` run only once. It then `exec`s `sshd -D -p 2222`.
- **SSH trust.** sshd only accepts the gateway's key, mounted as `authorized_keys`. Users authenticate at the gateway (see section 5), so the pod never needs to know about users or their keys.
- **Git credentials.** Set through `GIT_CONFIG_COUNT/KEY/VALUE` env vars. The credential helper reads the mounted git-token Secret, so refreshes need no restart.

### 5. Many services and many developers
- **SSH: plain public-key SSH, with no Keycloak in the handshake.**
  - **Upload a key.** On their profile page, the user pastes a public key, or imports their keys from `github.com/<login>.keys` once GitHub is connected. Keycloak only protects that web page.
  - **The UI shows a ready-to-copy `~/.ssh/config` snippet:**
    ```
    Host *.sandbox
      HostName ssh.dev.example.com
      User %n   # → <user>.<workspace>
    ```
    Plain VS Code Remote-SSH then works with **no extension**. The extension just does the same steps for you: it generates or picks a key, uploads it through the API using your Keycloak session, and writes the snippet.
  - **The handshake.** The client connects as `<user>.<workspace>`. The sshpiper plugin checks the offered key against that user's stored keys, and checks that the user owns the workspace (or that it's shared with them, later). It then opens the upstream connection to the pod's `:2222` using the gateway key.
    - Deleting a key in the UI takes effect on the next connection.
    - One user can have many workspaces open at once.
  - **Possible later addition:** short-lived SSH certificates issued after a Keycloak login (`ssh-keygen -s` CA), for teams that don't want long-lived keys.
  - **Scaling.** sshpiper runs as **N stateless replicas** behind a TCP LoadBalancer, with an HPA on connection count. The plugin caches key and workspace lookups briefly, and reports when sessions open and close, which drives `lastActivity`.
- **Service URLs.**
  - Each port in `forwardPorts`/`portsAttributes`, or added later from the UI or the extension, becomes `services[]` on the Workspace.
  - The URL is `<service>--<workspace>--<user>.ws.dev.example.com`. A wildcard TLS certificate covers only one level of subdomain, so `$SERVICE.$WORKSPACE.$USER.dev.example.com` would need a certificate per user. The flat form needs only one: `*.ws.dev.example.com`.
  - **svc-proxy** (N replicas, behind the Ingress or Gateway API) checks the Keycloak session. A service is private (owner only) by default; its visibility can be set to `org` or `public`. The proxy then forwards to `<ws-svc>.<ns>:<port>`, with websocket support.
  - Port forwarding through SSH also keeps working.
- **Isolation, so 1,000 developers don't affect each other:**
  - **Per-user namespace** with a ResourceQuota and LimitRange. A workspace without limits is rejected.
  - **Default-deny NetworkPolicy.** Ingress is allowed only from the sshpiper and svc-proxy namespaces. Egress is allowed to the internet, Harbor and the API. Workspaces can't reach each other or the cluster's internal services.
  - **Pod Security `baseline`.** Privileged workspaces need `allowPrivileged` and are scheduled onto a separate tainted node pool. The same goes for heavier sandboxing, such as Kata or gVisor through `runtimeClassName`.
  - **Separate node pools,** each with its own autoscaling (Karpenter or Cluster Autoscaler): `workspaces`, `ci`, `builds` (BuildKit) and `system` (control plane, gateways). CI or build spikes can't starve the workspaces.
  - **Fair queuing.** The build queue limits concurrent builds per user and per repo. The API rate-limits per user.
- **Control-plane capacity at 1,000 workspaces:**
  - controller-runtime handles thousands of CRs if its informers are filtered to Sandbox-labelled objects.
  - Token refresh is spread across the hour, which works out to about 0.3 writes per second for 1,000 users.
  - The API and proxies are stateless and scale out. User data (GitHub links, SSH keys) lives in Postgres; Secrets don't scale well as a database at this size.
- **Fast starts:**
  - Harbor runs in HA with S3 storage and a pull-through cache.
  - **Spegel** gives peer-to-peer image caching between nodes.
  - An optional DaemonSet pre-pulls the most-used `cfg-*` images.
  - Stopped workspaces keep their PVC, so a restart only needs an image pull plus the start itself.

### 6. Sandbox API and web UI (`dev.example.com`)
- **Login and GitHub.** Keycloak OIDC; the username comes from `preferred_username`. "Connect GitHub" stores the GitHub App user refresh token, encrypted in Postgres.
- **Workspaces.** List repos, branches and commits. Create, stop, start and delete Workspaces, and manage their services and visibility. Manage SSH keys.
- **Open in VS Code.** A button linking to `vscode://deepspacecartel.sandbox/open?ws=<name>`.
- **CI build broker.** `POST /ci/build` accepts a GitHub Actions OIDC token, checks the `repository` claim against the GitHub App installation, and enqueues the build. Repos then need no builder secret.

### 7. VS Code extension
Port it from `vscode-extension/`, keeping `git.ts`, `status.ts` and `scheduler.ts` and replacing `coder.ts` and the Coder parts of `cloneCommand.ts`.
- **Sign in.** Keycloak through an `AuthenticationProvider`, using PKCE.
- **SSH key.** Generates an ed25519 key (or picks an existing one), uploads the public key, and adds an `Include` with `Host *.sandbox` → `ssh.dev.example.com`.
- **Open.** Handles `vscode://…/open` and opens `vscode-remote://ssh-remote+<user>.<ws>.sandbox/workspaces/<repo>`.
- **Commands and views.** *New workspace* (repo → branch or commit), *My workspaces*, *Services* (open a URL or change its visibility), *Stop*, and the existing *rebuild available* status.

### 8. CI through ARC, in detail
**Infrastructure, installed by `charts/sandbox` under `ci.enabled`:**
- ARC `gha-runner-scale-set-controller`, plus one **runner scale set per size class**: `sandbox-small` (2 CPU / 4 Gi), `sandbox-large` (8 / 32) and an optional `sandbox-privileged`.
  - They run in namespace `ci`, on the `ci` node pool, with `minRunners: 0` and a `maxRunners` cap for each class.
- **`containerMode: kubernetes`.** The runner pod launches the job's `container:` as a separate pod through runner-container-hooks.
  - The job's work directory sits on an **ephemeral PVC** (`workVolumeClaimTemplate`) that the runner and the job pod share.
  - **Hook pod template** (`ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE`): the operator generates it from `pkg/podspec` and the WorkspaceTemplate for that size class. It sets resources, nodeSelector and tolerations, securityContext and runtimeClass.
- **Isolation.** Default-deny NetworkPolicy in `ci`, with egress only to the internet, Harbor and the API. Each job gets a fresh pod and PVC. CI runs at a lower PriorityClass than workspaces, on its own node pool.

**Workflow, in the repo's `.github/workflows/ci.yaml`:**
```yaml
permissions: { id-token: write, contents: read }
jobs:
  devcontainer:
    runs-on: sandbox-small
    outputs: { image: ${{ steps.b.outputs.image }}, metadata: ${{ steps.b.outputs.metadata }} }
    steps:
      - id: b
        uses: deepspacecartel/sandbox/actions/build@v1   # OIDC → POST /ci/build {repo, sha}
  test:
    needs: devcontainer
    runs-on: sandbox-large            # pick the size class
    container:
      image: ${{ needs.devcontainer.outputs.image }}   # same cfg-<hash> image as dev workspaces
    steps:
      - uses: actions/checkout@v4
      - uses: deepspacecartel/sandbox/actions/exec@v1
        with:
          metadata: ${{ needs.devcontainer.outputs.metadata }}
          hooks: onCreate,updateContent,postCreate      # postStart/postAttach skipped by default
      - run: make test                # env from containerEnv/remoteEnv is already applied
```

**`actions/build`** (JavaScript, running on the runner pod):
1. Gets a GitHub OIDC token.
2. Calls `POST /ci/build` and polls `GET /builds/{id}`, streaming the build log into the job log.
3. Outputs `image` (`cfg-<hash>`, so it's often a cache hit in under a second) and `metadata`: the JSON from `GET /devcontainer`, holding env scripts, lifecycle scripts, `remoteUser` and `workspaceFolder`.

**`actions/exec`** (composite or JavaScript, running in the job container):
1. Writes `containerEnv`/`remoteEnv` to `$GITHUB_ENV`.
2. Runs the chosen hooks in devcontainer order, as `remoteUser`, in `$GITHUB_WORKSPACE`.
3. Fails the step if a hook fails.

The hook logic is shared with the workspace entrypoint script, as one script published in both places.

**Who pays for a CI job: the user or the component owner.**
- **Deciding at job start.** In `POST /ci/build`, the broker reads the GitHub OIDC claims: `event_name`, `actor`, `triggering_actor`, `ref` and `repository`.
  - **Billed to the user** when a person triggered the job: a `push` or `pull_request` by a person, `workflow_dispatch` or a re-run. The `triggering_actor` GitHub login is mapped to the Keycloak user through the stored "Connect GitHub" link.
  - **Billed to the component owner** for `schedule`, `release`, tag pushes and refs that match a configurable list (for example `release/*` and `milestone/*`), and when the actor is a bot (`*[bot]`, `github-actions`). The same applies when the actor has no linked Sandbox account.
  - The owner comes from the `Component` that matches the repo.
- **Enforcing the budget at start.** The broker refuses the build step with a clear message, such as "CI budget exhausted for alice" or "for team payments", when that owner's concurrent jobs or monthly CPU-hours are used up.
  - Every job runs `actions/build` first, so this is a single gate.
  - Hard per-namespace quotas aren't possible here, because ARC puts every job pod in the runner's namespace.
- **Labelling the pods.** The broker returns a `billingId`. The admission webhook from section 3 finds the matching EphemeralRunner through `workflowRunId` and the job, then labels the runner pod and the job pod with `sandbox.dev/billed-to=user:alice` or `team:payments`, plus `sandbox.dev/repo` and `sandbox.dev/run`.
- **Metering.** A usage collector in the operator turns kube-state-metrics and cAdvisor data, grouped by `billed-to`, into CPU-seconds and memory-GiB-seconds. Usage is stored per owner per day in Postgres.
  - Workspaces are metered the same way, through the `ws-<user>` namespace.
  - The web UI shows "My usage" (workspaces and CI) and "Team usage" (automated CI). OpenCost can be pointed at the same labels.

**Known limits:**
- No Docker daemon inside jobs. Use `services:` for databases. Image builds go through the builder.
- Docker Compose devcontainers aren't supported, which matches what workspaces support.
- JavaScript actions in the job container need the runner's bundled node. Check that it works with Alpine images early, in phase 6.

## Before phase 0: a workbench and disposable environments for Claude
**The goal.** Claude writes code in a **Coder workspace on your existing Coder cluster**, and builds, deploys and tests Sandbox against **separate, disposable clusters in a new Hetzner project**. Several Claude sessions can each have their own environment at the same time, and nothing Claude does can touch the Coder cluster, the main DNS zone or real GitHub repos.

### A. What you do once, by hand (Claude can't enter credentials)
1. **New Hetzner Cloud project** `sandbox-dev`, with a read/write API token. Only this project is in reach, so a mistake costs at most a deleted test cluster.
2. **DNS subzone.** A Route53 hosted zone for `sandbox.deepspacecartel.com`, delegated from the root zone with an NS record, plus an IAM user whose policy covers **only that zone**. This user is used both for DNS-01 certificates and for the records.
3. **GitHub test org,** for example `dsc-sandbox-test`, containing:
   - A **GitHub App** "Sandbox (test)", with contents, metadata, actions and administration for runner groups.
   - A few sample repos: a plain one with no devcontainer, one with a Dockerfile devcontainer, one with Features and `customizations.kubernetes`, and one with a 2-job CI workflow.
   - A bot user for "automated" runs.
4. **1Password.** A vault `Sandbox Dev` holding the items above, plus a **service account** with read access to that vault only. The token goes into the Coder workspace once, as `OP_SERVICE_ACCOUNT_TOKEN` in the persistent home directory, so `op run --env-file=.env.1password` works the same way it does in the existing Coder infrastructure.
5. **Terraform state.** A separate S3 bucket, or an OVH bucket with its own credentials, for `sandbox-dev/*.tfstate`. Don't reuse the Coder state bucket, so these credentials can't read the Coder state.

You don't need to change the existing Coder infrastructure. The Coder template already builds whatever `devcontainer.json` the new repo has. Leave `workspace_service_account_name` unset for this workspace, so Claude has **no RBAC on the Coder cluster**.

### B. What Claude sets up first in the new repo `DeepSpaceCartel/sandbox`
1. **`.devcontainer/devcontainer.json`.** Tools: Go, kubebuilder, helm, kubectl, talosctl, terraform, the `op` CLI, gh, Node (for `web/` and the extension), docker buildx (client only, using remote BuildKit), the claude-code Feature and k9s. Size it with `customizations.kubernetes` (for example 4 CPU / 8 Gi). It reuses the layout of the builder repo's `.devcontainer/`.
2. **`CLAUDE.md` and `.agents/skills`.** Bring over the builder repo's `disposable-k8s-test-fixtures`, `helm-chart-authoring` and `buildkit-remote-driver` skills through `skills-lock.json`, and the existing `terraform-*` skills. Write the environment rules down in `CLAUDE.md`.
3. **`infra/`.** Terraform modelled on the existing Coder cluster setup, with one state per environment, keyed by `ENV`:
   - **`infra/cluster`** uses `hcloud-k8s/kubernetes/hcloud` 5.6.1 (Talos and Cilium, same as the Coder cluster).
     - The cluster is named `sbx-${ENV}`, with a small control plane.
     - Its autoscaled node pools are `system`, `workspaces`, `ci` and `builds`, each tainted and labelled. This lets the isolation tests run on real separate pools.
     - Cilium is used for NetworkPolicy enforcement and Hubble.
   - **`infra/platform`** sets up:
     - cert-manager with a Route53 DNS-01 ClusterIssuer (the same pattern as `platform/coder.tf`).
     - A Gateway with a wildcard certificate (the same pattern as `platform/gateway.tf`), plus a TCP LoadBalancer for SSH.
     - **Keycloak** with a seeded **test LDAP** (lldap) and a few users and groups, to cover the enterprise case.
     - **CloudNativePG** for Postgres, **Harbor**, the **BuildKit pool**, **devcontainer-builder** (from its chart, pinned or from a branch image), the **ARC controller** registered against the test org, kube-state-metrics, and a small Grafana/VictoriaMetrics setup for the load tests.
   - **DNS** is per environment, under `${ENV}.sandbox.deepspacecartel.com`: `dev.`, `id.dev.`, `ssh.dev.`, `docker.dev.` and `*.ws.dev.`. Parallel environments never clash.
4. **Environment lifecycle commands** in the `Makefile`, each wrapped in `op run`:
   - `make env-up ENV=<name>` runs cluster → platform, about 10–15 minutes.
   - `make env-down ENV=<name>` runs a teardown script (based on `platform/teardown.sh`, which clears autoscaler nodes first), then platform → cluster.
   - `make env-list` lists environments.
   - `make deploy ENV=<name>` builds the Sandbox images through that environment's BuildKit, pushes them to its Harbor, and runs `helm upgrade` on `charts/sandbox`. This is the inner loop, done in minutes, without Terraform.
   - `make e2e ENV=<name>` runs the e2e suite against that environment.
   - The default `ENV` comes from the git branch or worktree, so parallel Claude sessions each get their own environment.
5. **Cleaning up and capping costs.**
   - Every Hetzner resource is labelled `env=<name>`, `owner=claude|alex` and `expires=<date>`.
   - A scheduled GitHub Action in the sandbox repo runs `env-down` on expired environments, unless they're labelled `pinned=true`.
   - Autoscaler maximums for each pool are set per environment: small by default, raised only for the load test environment.
6. **Claude's permissions.**
   - `.claude/settings.json` allows `make env-*`, `make deploy` and `make e2e`, plus `kubectl`, `helm`, `talosctl` and `terraform plan|apply|destroy` under `infra/`.
   - `KUBECONFIG` is only ever pointed at `sbx-*` clusters.
   - Claude asks first before anything in the `pinned` environment, or before raising node-pool maximums.

### C. Things to settle while building the environments
- **Kube and Talos API firewall.** The Coder cluster uses `firewall_use_current_ipv4`, which admits only the IP that ran the apply. A Coder workspace's outbound IP changes as the Coder cluster's nodes autoscale. **Recommendation:** for these disposable dev clusters, open the Kube and Talos APIs to the internet; both still require client certificates. The alternative is to send Coder workspace traffic out through a fixed IP: either the bastion, or a Cilium egress gateway on the Coder cluster.
- **Image source.** Each environment gets its own Harbor (so tests can create and destroy it), with a pull-through cache to Docker Hub and GHCR. Builder images are pulled from GHCR.

## Phased roadmap
| Phase | What gets built | Done when |
|---|---|---|
| −2 | You: Hetzner project, DNS subzone and IAM, GitHub test org and App, 1Password vault and service account, state bucket | The items are in the `Sandbox Dev` vault |
| −1 | Claude: the `sandbox` repo with devcontainer, `CLAUDE.md`, `infra/`, Makefile environment commands, reaper | In a Coder workspace on that repo, `make env-up ENV=a` and `make env-up ENV=b` both work side by side, and `make env-down` removes everything in Hetzner and Route53 |
| 0 | Builder: SHA builds, sshd Feature, async builds, `cfg-<hash>` tags, API auth | A new commit with no config change reuses the image; an exact SHA builds |
| 1 | Operator, CRDs, `pkg/podspec`, entrypoint, namespace guardrails | `kubectl apply` a Workspace gives the repo at that SHA, with quota and NetworkPolicy applied |
| 2 | sshpiper plugin and gateway | `ssh <user>.<ws>@ssh.dev.example.com` works and Remote-SSH works by hand; two workspaces for one user work side by side |
| 3 | API with Postgres: Keycloak, Connect GitHub, git-token refresh | `git push` works without a stored PAT |
| 4 | svc-proxy and service URLs | Two services in one workspace each get a private URL; a second user is denied |
| 5 | Web UI and VS Code extension | Browser → repo@commit → Open in VS Code lands in the folder |
| 6 | CI: broker, `actions/build` and `actions/exec`, ARC scale sets, admission webhook, attribution and metering | The sample workflow runs in the same `cfg-*` image; a manual run is billed to the user and a scheduled run to the team |
| 7 | Scale: builder replicas, BuildKit pool, Harbor HA, Spegel, idle stop and cleanup | The load test (see Verification) passes |

## Verification
- **Unit tests:** `pkg/podspec` table tests, operator envtest (reconcile, quotas, token refresh, idle stop), sshpiper plugin routing and key checks, svc-proxy authorization, and the extension's ssh config writer.
- **End-to-end on kind**, reusing the builder's `charts/test-git-server`, `charts/test-registry` and `charts/test-namespace` plus BuildKit and a dev Keycloak:
  - A workspace at a SHA, checked with `git rev-parse HEAD`.
  - Stop and start, checking that `~` survived.
  - Two services, each reachable at its URL.
  - User B can't reach user A's pod, its SSH or its URL.
  - The CI workflow runs.
  - A `workflow_dispatch` run is labelled `user:<you>` and a `schedule` run is labelled `team:<owner>`, and both show up in usage.
  - A run past its budget is refused at the build step.
  - An SSH key uploaded in the UI works with plain `ssh`, and stops working once it's deleted.
- **Isolation tests:** a workspace that uses up its CPU and memory quota must not slow down another user's workspace on the same node pool, and a NetworkPolicy probe from one workspace to another must fail.
- **Load test on a real cluster:**
  - A script creates 1,000 Workspaces, with 200 starting at the same time, plus 100 parallel CI jobs.
  - Targets: 95th-percentile time to Running under 60 s on a cached image, with no errors from the operator or the API server, and SSH connect under 2 s.
- **Manual:** browser → Open in VS Code → edit, commit and push → open a service URL.

## Open items
- Whether there is one cluster or separate dev and prod clusters (Harbor and builders are per cluster).
- Whether to use sandboxed runtimes (Kata or gVisor) for every workspace, or only for privileged ones.
