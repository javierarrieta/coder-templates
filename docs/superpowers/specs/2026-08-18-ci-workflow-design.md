# Design: CI workflow + provider unit tests

Date: 2026-08-18

## Goal

Add a CI workflow that compiles and tests the `llm01_workspace_target` Rust
provider and validates the template's Terraform code, without depending on the
private `registry.l.arrieta.eu` provider registry from the GitHub runner.

## Background / constraints

- The provider lives at
  `templates/podman-template/providers/llm01_workspace_target/` and currently
  has **zero** unit tests; `cargo test` would compile but run nothing.
- `templates/podman-template/main.tf` requires the `llm01` provider from the
  private registry `registry.l.arrieta.eu/infra/llm01` (`~> 0.1`). The standard
  Terraform registry protocol path on that host returns 404, so `terraform init`
  against it in CI is unreliable; the registry is not something this repo can
  control.
- `templates/podman-template/compatibility/main.tf` uses only the public
  `kreuzwerker/docker` provider, so it can fully `init` + `validate` in CI.
- GitHub Actions only picks up workflows from `.github/workflows/` at the repo
  root.
- Both `.terraform/` and `.terraform.lock.hcl` are already gitignored in the
  template dir, so `terraform init` in CI will not pollute git.

## Design

### 1. New workflow `.github/workflows/ci.yml`

Triggers:

- push to `main`
- pull_request (any base)
- `paths` filter: provider `src/**`, template `.tf` and `.gitignore`,
  `.github/workflows/**`

#### Job `provider` (ubuntu-latest)

`defaults.run.working-directory`:
`templates/podman-template/providers/llm01_workspace_target`

Steps:

1. `actions/checkout@v4`
2. `dtolnay/rust-toolchain@stable` with `toolchain: stable` and components
   `rustfmt`, `clippy`
3. `cargo fmt --check`
4. `cargo clippy --all-targets -- -D warnings`
5. `cargo test`
6. `cargo build --release --bin terraform-provider-llm01`
7. `actions/upload-artifact@v4` — upload
   `templates/podman-template/providers/llm01_workspace_target/target/release/terraform-provider-llm01`
   as `llm01-provider-linux-amd64`

#### Job `terraform` (ubuntu-latest, `needs: provider`)

Steps:

1. `actions/checkout@v4`
2. `hashicorp/setup-terraform@v3`
3. `terraform fmt -check -recursive`
4. Validate `compatibility/`:
   - `working-directory: templates/podman-template/compatibility`
   - `terraform init -input=false`
   - `terraform validate`
5. Validate the template with a local provider mirror (offline for `llm01`):
   - `actions/download-artifact@v4` fetches `llm01-provider-linux-amd64` to
     `$HOME/.tf-mirror`
   - Lay the binary out at
     `$HOME/.tf-mirror/registry.l.arrieta.eu/infra/llm01/terraform-provider-llm01/0.1.1/linux_amd64/terraform-provider-llm01_v0.1.1`
   - `chmod +x` the binary
   - Write `~/.terraformrc`:

     ```hcl
     provider_installation {
       filesystem_mirror {
         path    = "$HOME/.tf-mirror"
         include = ["registry.l.arrieta.eu/*"]
       }
       direct {
         exclude = ["registry.l.arrieta.eu/*"]
       }
     }
     ```

   - `working-directory: templates/podman-template`
   - `terraform init -input=false`
   - `terraform validate`

The version directory `0.1.1` satisfies the `~> 0.1` constraint in `main.tf`
and matches the Cargo package version.

### 2. Provider unit tests

Add `#[cfg(test)] mod tests` at the end of
`templates/podman-template/providers/llm01_workspace_target/src/lib.rs`.

Confirmed feasible from the `tf-provider 0.2.2` crate:

- `Value<T>` is an enum (`Value::Value(T)` / `Null` / `Unknown`); the type
  aliases are `ValueString = Value<Cow<str>>`, `ValueNumber = Value<i64>`,
  `ValueBool = Value<bool>`, so test states are directly constructible.
- `Diagnostics` derives `Default`, so `&mut Diagnostics::default()` satisfies
  the `plan_update` signature.

Tests:

1. `plan_update` forces replacement when `workspace` changes.
2. `plan_update` forces replacement when `size_gb` changes.
3. `plan_update` returns no replacement paths when only `active` changes
   (start/stop must stay in-place).
4. `HelperResponse` deserialization maps `ok`, `capability`, `error`, `device`,
   and `mountpoint`, including the `#[serde(default)]` optional fields.
5. `HelperClient::new` returns an `Err` when the cert directory/files are
   missing.

### 3. Risks

- `terraform validate` on the template exercises the freshly-built provider
  binary through the Terraform protocol handshake (`tf-provider 0.2.2`). If the
  handshake misbehaves, only the template-validate step is affected; fmt,
  compatibility validation, and all Rust checks still pass.
- `hashicorp/setup-terraform@v3` defaults to the latest stable Terraform.
  Pinning a specific version is possible later if reproducibility matters.

## Out of scope

- Publishing/releasing (already handled by `publish.yml` / `build.yml`).
- The manual distribute/sign/upload steps in the provider README.
- Anything in the sibling `nixos-configurations` repo.