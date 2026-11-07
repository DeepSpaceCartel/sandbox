# Sandbox

Kubernetes-first dev environments driven by `devcontainer.json`:
- Open any repo you have access to, at a branch or commit, in VS Code Desktop over Remote-SSH.
- Run as many services per workspace as you need, each at its own URL.
- Run CI through GitHub Actions (ARC) in the very same image.

**Status:** planning done; bootstrapping the workbench (phase −1).

- Design and roadmap: [docs/plan.md](docs/plan.md)
- Before the first environment: [docs/setup/manual-prerequisites.md](docs/setup/manual-prerequisites.md)
- Working on this repo, for people and Claude: [CLAUDE.md](CLAUDE.md)

Images are built by [devcontainer-builder](https://github.com/DeepSpaceCartel/devcontainer-builder).
