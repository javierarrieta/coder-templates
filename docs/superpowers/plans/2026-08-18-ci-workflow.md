# CI Workflow + Provider Unit Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CI workflow that compiles, lints, and unit-tests the `llm01_workspace_target` Rust provider and validates the template's Terraform config, delivered on a feature branch and opened as a PR.

**Architecture:** A two-job `ci.yml` at the repo root. Job `provider` runs rustfmt/clippy/test/build in the provider crate and uploads the release binary. Job `terraform` (needs provider) runs `terraform fmt -check -recursive`, validates `compatibility/` against the public registry, and validates `templates/podman-template` using a local filesystem mirror so the private `registry.l.arrieta.eu` provider is never contacted.

**Tech Stack:** GitHub Actions (`actions/checkout@v4`, `dtolnay/rust-toolchain@stable`, `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `hashicorp/setup-terraform@v3`), Rust (cargo 1.92 / stable), Terraform (latest stable via setup-terraform).

## Global Constraints

- Workflows must live at repo root `.github/workflows/` (GitHub Actions ignores nested `.github` dirs).
- GitHub runner image: `ubuntu-latest` (Ubuntu 24.04, x86_64 → provider `linux_amd64`). `zip`, `sha256sum`, `bash` preinstalled.
- Do NOT contact `registry.l.arrieta.eu` from CI; `terraform init` must resolve `llm01` (`~> 0.1`) from a local filesystem mirror at `$HOME/.tf-mirror`.
- The provider's Cargo package version is `0.1.1`; the mirror version directory MUST be `0.1.1`.
- `.terraform/` and `.terraform.lock.hcl` are already gitignored in `templates/podman-template/`; CI `terraform init` must not pollute git.
- Every `run` step that touches the provider crate uses `defaults.run.working-directory: providers/llm01_workspace_target`.
- `upload-artifact`/`download-artifact` `path` values are repo-root relative (NOT affected by `working-directory`).
- All commits for the code go on branch `ci/compile-tests-terraform` and are opened as a PR against `main`. Do NOT commit the code to `main`.

---

### Task 1: Provider unit tests + format cleanup

**Files:**
- Modify: `providers/llm01_workspace_target/src/lib.rs` (run `cargo fmt` first — the file currently has 2 import-block formatting diffs; append the `#[cfg(test)] mod tests` module at the end)

**Interfaces:**
- Produces: 5 passing tests. All tests reference only public items already exported by the crate: `HelperClient::new`, `HelperResponse`, `WorkspaceTargetResource`, `WorkspaceTargetState`, `WorkspaceTargetPrivate`, and the `tf-provider` types `ValueString = Value<Cow<str>>`, `ValueNumber = Value<i64>`, `ValueBool = Value<bool>`, `ValueEmpty`, `AttributePath::new`, `Diagnostics`.

Pre-check (already verified): `cargo clippy --all-targets -- -D warnings` is clean on the current code; `cargo fmt --check` reports exactly 2 diffs in `src/lib.rs` import blocks.

- [ ] **Step 1: Format the existing code**

Run: `cargo fmt` (from the provider directory)
Expected: exits 0, rewrites the 2 import blocks. No semantic change.

- [ ] **Step 2: Append the test module**

Append to the end of `src/lib.rs`:

```rust

#[cfg(test)]
mod tests {
    use super::*;
    use std::borrow::Cow;

    fn state(workspace: &str, size_gb: i64, active: bool) -> WorkspaceTargetState<'static> {
        WorkspaceTargetState {
            workspace: ValueString::Value(Cow::Owned(workspace.to_string())),
            size_gb: ValueNumber::Value(size_gb),
            active: ValueBool::Value(active),
        }
    }

    async fn plan_replace_paths(
        prior: WorkspaceTargetState<'static>,
        proposed: WorkspaceTargetState<'static>,
    ) -> Vec<AttributePath> {
        WorkspaceTargetResource::default()
            .plan_update(
                &mut Diagnostics::default(),
                prior,
                proposed,
                WorkspaceTargetState::default(),
                WorkspaceTargetPrivate::default(),
                ValueEmpty::default(),
            )
            .await
            .expect("plan_update should produce a plan")
            .2
    }

    #[tokio::test]
    async fn plan_update_forces_replacement_on_workspace_change() {
        let replace = plan_replace_paths(state("ws-a", 50, true), state("ws-b", 50, true)).await;
        assert_eq!(replace, vec![AttributePath::new("workspace")]);
    }

    #[tokio::test]
    async fn plan_update_forces_replacement_on_size_change() {
        let replace = plan_replace_paths(state("ws-a", 50, true), state("ws-a", 80, true)).await;
        assert_eq!(replace, vec![AttributePath::new("size_gb")]);
    }

    #[tokio::test]
    async fn plan_update_does_not_replace_on_active_only_change() {
        let replace = plan_replace_paths(state("ws-a", 50, true), state("ws-a", 50, false)).await;
        assert!(replace.is_empty());
    }

    #[test]
    fn helper_response_deserializes_with_defaults() {
        let parsed: HelperResponse =
            serde_json::from_str(r#"{"ok":true,"capability":"cap-123"}"#).unwrap();
        assert!(parsed.ok);
        assert_eq!(parsed.capability.as_deref(), Some("cap-123"));
        assert_eq!(parsed.error, None);
        assert_eq!(parsed.device, None);
        assert_eq!(parsed.mountpoint, None);
    }

    #[test]
    fn helper_client_new_errors_on_missing_cert_files() {
        let err = HelperClient::new("https://localhost:2377", "/nonexistent/certs").unwrap_err();
        assert!(err.to_string().contains("No such file"));
    }
}
```

Notes:
- `#[tokio::test]` works because the crate already enables `tokio` with `features = ["full"]` (includes `macros`).
- `plan_update` is the `Resource` trait method; `use super::*` brings `Resource` (and `tf_provider::*`) into scope.
- `AttributePath` implements `PartialEq` (verified in `tf-provider 0.2.2`), so `assert_eq!` on `Vec<AttributePath>` compiles.
- `Diagnostics` derives `Default`, so `&mut Diagnostics::default()` satisfies the signature.

- [ ] **Step 3: Run the tests**

Run: `cargo test`
Expected: compiles; `5 passed`, `0 failed`, `0 ignored`.

- [ ] **Step 4: Run formatting and lint gates**

Run: `cargo fmt --check && cargo clippy --all-targets -- -D warnings`
Expected: both exit 0.

- [ ] **Step 5: Commit on the feature branch**

```bash
git add providers/llm01_workspace_target/src/lib.rs
git commit -m "test(provider): add unit tests for plan_update, HelperResponse, HelperClient"
```

---

### Task 2: CI workflow `ci.yml`

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: artifact `llm01-provider-linux-amd64` (the release binary) uploaded by the `provider` job from `providers/llm01_workspace_target/target/release/terraform-provider-llm01`.
- Produces: `prefer` CI signal on `main` pushes and pull requests touching `.github/workflows/**` or `templates/podman-template/**`.

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
    paths:
      - ".github/workflows/**"
      - "templates/podman-template/**"
  pull_request:
    paths:
      - ".github/workflows/**"
      - "templates/podman-template/**"

jobs:
  provider:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: providers/llm01_workspace_target
    steps:
      - uses: actions/checkout@v4

      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: stable
          components: rustfmt, clippy

      - name: Format
        run: cargo fmt --check

      - name: Lint
        run: cargo clippy --all-targets -- -D warnings

      - name: Test
        run: cargo test

      - name: Build release binary
        run: cargo build --release --bin terraform-provider-llm01

      - name: Upload provider binary
        uses: actions/upload-artifact@v4
        with:
          name: llm01-provider-linux-amd64
          path: providers/llm01_workspace_target/target/release/terraform-provider-llm01

  terraform:
    runs-on: ubuntu-latest
    needs: provider
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform fmt
        run: terraform fmt -check -recursive

      - name: Validate compatibility gate (public registry)
        working-directory: templates/podman-template/compatibility
        run: |
          terraform init -input=false
          terraform validate

      - name: Download provider binary
        uses: actions/download-artifact@v4
        with:
          name: llm01-provider-linux-amd64
          path: .ci/llm01-provider

      - name: Install llm01 provider into local filesystem mirror
        shell: bash
        run: |
          set -euo pipefail
          PKG="$HOME/.tf-mirror/registry.l.arrieta.eu/infra/llm01/terraform-provider-llm01/0.1.1/linux_amd64"
          mkdir -p "$PKG"
          cp .ci/llm01-provider/terraform-provider-llm01 "$PKG/terraform-provider-llm01_v0.1.1"
          chmod +x "$PKG/terraform-provider-llm01_v0.1.1"
          (cd "$PKG" && sha256sum terraform-provider-llm01_v0.1.1 > terraform-provider-llm01_v0.1.1_SHA256SUMS)
          # Unquoted EOF: $HOME must expand at write time because Terraform
          # does NOT interpolate env vars inside its CLI config file.
          cat > "$HOME/.terraformrc" <<EOF
          provider_installation {
            filesystem_mirror {
              path    = "$HOME/.tf-mirror"
              include = ["registry.l.arrieta.eu/*"]
            }
            direct {
              exclude = ["registry.l.arrieta.eu/*"]
            }
          }
          EOF

      - name: Validate template against local mirror
        working-directory: templates/podman-template
        run: |
          terraform init -input=false
          terraform validate
```

Notes / why it's written this way:
- `on.workflow_dispatch` is intentionally NOT added — the manual `build.yml` already exists.
- `dtolnay/rust-toolchain@stable` is combined with `with.toolchain: stable`; the `stable` ref exists on that action's repo (verified 200) and it accepts the `toolchain` + `components` inputs.
- The filesystem mirror package dir name `0.1.1` satisfies `~> 0.1` and matches Cargo. The `SHA256SUMS` file lets Terraform verify the binary instead of skipping checksum validation (mirrors without checksums are skipped, which is riskier).
- The `.terraformrc` `$HOME` must be expanded by the shell (unquoted heredoc) — a literal `$HOME` in HCL is not an env-var reference.

- [ ] **Step 2: Validate YAML parses**

Run:
```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print('jobs:', list(d['jobs']))"
```
Expected: `jobs: ['provider', 'terraform']`.

- [ ] **Step 3: Commit on the feature branch**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add compile/lint/test workflow and terraform validation with local provider mirror"
```

---

### Task 3: Verify in GitHub Actions and open PR

- [ ] **Step 1: Push the feature branch and open the PR**

```bash
git push -u origin ci/compile-tests-terraform
gh pr create --fill --title "Add CI: provider build/tests + terraform validation"
```

- [ ] **Step 2: Confirm the `provider` job is green**

`gh pr checks <branch>` (or the Actions tab). Expected: `provider` job passes (`fmt`, `clippy`, `test`, `build`, upload).

- [ ] **Step 3: Confirm the `terraform` job is green**

Expected: `terraform fmt` clean, `compatibility/` init+validate passes, and the template's init+validate passes using the mirror. The job logs should never show a request to `registry.l.arrieta.eu`.

- [ ] **Step 4: If a step fails, investigate and fix**

Common failure points and known resolutions:
- `cargo fmt --check` diff in a file → run `cargo fmt` locally, amend into the relevant Task 1/2 commit (new commit, not amend history if already pushed), push again.
- `terraform validate` on the template fails with an unknown provider / missing plugin → the mirror layout is wrong; verify the `PKG` path and that the binary is `linux_amd64` and executable.
- `terraform validate` complains about checksum/lock mismatch → delete `.terraform.lock.hcl` from the template dir on the runner before `init` (it is gitignored; CI starts from a fresh checkout anyway).
- `gh pr checks` exit code for the pushed branch uses the branch's own `ci.yml`, so the PR run includes these exact checks.

## Self-Review

**Spec coverage:**
- ci.yml two jobs ✓ (Task 2)
- fmt/clippy/test/build on provider ✓ (Task 2, Task 1 prerequisites)
- terraform fmt -check -recursive ✓ (Task 2)
- compatibility full validate ✓ (Task 2)
- template full validate via local filesystem mirror, no private registry contact ✓ (Task 2)
- 5 provider unit tests ✓ (Task 1)
- PR delivery ✓ (Task 3)

**Placeholder scan:** No TBD/TODO; all code and commands inlined.

**Type consistency:** Test code uses `ValueString::Value(Cow::Owned(...))`, `ValueNumber::Value(i64)`, `ValueBool::Value(bool)` matching `tf-provider` `Value<T>` enum and the crate's type aliases. Mirror version dir `0.1.1` matches Cargo version and `~> 0.1` constraint. Artifact name `llm01-provider-linux-amd64` consistent across upload/download.