# Manual prerequisites (phase −2)

These steps need your own accounts and credentials, so they're done by hand.
Claude doesn't create accounts or handle secret values. Everything goes into one
1Password vault, `Sandbox Dev`, with the item and field names that
[`.env.1password`](../../.env.1password) expects.

## 1. Hetzner Cloud project
- [ ] Create a new project, **`sandbox-dev`**. It must be separate from the Coder project.
- [ ] Security → API tokens → create a token with **Read & Write** permissions.
- [ ] 1Password item **`Hetzner sandbox-dev`**, field `token`.

## 2. DNS subzone `sandbox.deepspacecartel.com`
- [ ] Route53 → create a public hosted zone `sandbox.deepspacecartel.com`.
- [ ] In the `deepspacecartel.com` zone, add an **NS** record for `sandbox` with the new zone's 4 name servers.
- [ ] IAM → create a user `sandbox-dns` with a policy that allows only this zone:
  - `route53:ChangeResourceRecordSets` and `route53:ListResourceRecordSets` on `arn:aws:route53:::hostedzone/<ZONE_ID>`
  - `route53:GetChange` on `arn:aws:route53:::change/*`
  - `route53:ListHostedZonesByName` and `route53:ListHostedZones` on `*` (cert-manager needs these)
- [ ] 1Password item **`Route53 sandbox zone`**, with fields `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `zone_id`.
- [ ] Check it: `dig NS sandbox.deepspacecartel.com +short` returns the new name servers.

## 3. Terraform state bucket
- [ ] Create an S3 (or OVH S3-compatible) bucket, for example `sandbox-dev-tfstate`, with versioning on.
- [ ] Create credentials that can access **only this bucket**. Don't reuse the Coder state bucket credentials.
- [ ] 1Password item **`Terraform state`**, with fields `bucket`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. If you use OVH, add `endpoint` and `region` too.

## 4. GitHub test org and App
- [ ] Create a new org, for example **`dsc-sandbox-test`**.
- [ ] Org settings → Developer settings → GitHub Apps → create **"Sandbox (test)"**:
  - Callback URL: `https://dev.<env>.sandbox.deepspacecartel.com/auth/github/callback`. You can change it later; add one per environment.
  - Turn on "Request user authorization (OAuth) during installation" and "Expire user authorization tokens".
  - Webhook: off for now.
  - Repository permissions:
    - Contents: Read & write
    - Metadata: Read
    - Actions: Read
    - Administration: Read & write (for ARC runner registration)
  - Organization permissions:
    - Self-hosted runners: Read & write
  - Install it on the test org, with access to all repositories.
- [ ] Generate a private key and a client secret.
- [ ] 1Password item **`GitHub App sandbox-test`**, with fields `org`, `app_id`, `client_id`, `client_secret`, `private_key` (the PEM) and `webhook_secret` (any random string).
- [ ] Create 4 sample repos in the org. Claude can fill in their contents later:
  - `plain`: no devcontainer
  - `dockerfile`: a devcontainer built from a Dockerfile
  - `features`: a devcontainer with Features and `customizations.kubernetes`
  - `ci`: a 2-job CI workflow
- [ ] Create a bot user, for example `dsc-sandbox-bot`, as an org member. It's for testing "automated" CI attribution.

## 5. 1Password service account
- [ ] 1Password → Developer → Service accounts → create **`sandbox-claude`** with **read-only access to the `Sandbox Dev` vault only**.
- [ ] In the Coder workspace for this repo, run this once:
  ```bash
  mkdir -p ~/.config/sandbox && chmod 700 ~/.config/sandbox
  read -rs OP_TOKEN && printf %s "$OP_TOKEN" > ~/.config/sandbox/op-token && chmod 600 ~/.config/sandbox/op-token
  bash .devcontainer/postCreateCommand.sh && exec bash
  op vault list   # should list only "Sandbox Dev"
  ```

## 6. Coder workspace
- [ ] Create a workspace from this repo with the existing `kubernetes-devcontainer` template.
- [ ] Leave the workspace service account **unset**, so the workspace gets no RBAC on the Coder cluster.
