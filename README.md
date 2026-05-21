# GitHub Actions Self-Hosted Runner

Self-hosted GitHub Actions runner optimised for Android app builds. Packages the
runner agent, full Android SDK/NDK toolchain, Java 17, and Node.js 24 into a
single Docker image so CI jobs start immediately without downloading the toolchain
on every run.

## What's included

| Tool | Version |
|---|---|
| GitHub Actions runner | latest (`myoung34/github-runner`) |
| Java | Temurin 17 |
| Node.js | 24 |
| Android SDK command-line tools | 12266719 |
| Android build-tools | 35.0.0 |
| Android platform | 35 |
| Android NDK | 27.1.12297006 |

Gradle and npm caches are persisted in named Docker volumes across runs,
significantly reducing build times after the first run.

## Requirements

- Docker and Docker Compose on the host
- amd64/x86_64 Linux host (arm64 not supported by the Android SDK)
- GitHub org **owner** or **admin** access for org-level runner registration
  (regular org members cannot register org-level runners even with a PAT)

## Setup

### 1. Create a GitHub Personal Access Token

Runner registration requires a **classic** Personal Access Token. Fine-grained
PATs do not support the `admin:org` scope and cannot be used to register
org-level runners.

Go to **GitHub → Settings → Developer settings → Personal access tokens →
Tokens (classic)** and create a token with:

| Scope | Purpose |
|---|---|
| `admin:org` | Register, list, and delete **org-level** runners |
| `repo` | Register **repo-level** runners (only if `RUNNER_SCOPE=repo`) |

**Expiry**: set an expiry that matches your operational needs. The token is used
only to fetch a short-lived registration token on each container start — it is
not embedded in workflow runs. If the PAT expires, containers fail to re-register
after restart; rotate it in `.env` and restart the affected services.

#### Personal account limitation

A PAT issued by a personal GitHub account can only register org-level runners
for organisations where that account is an **owner or admin**. If your account
is a regular member of an org, the `admin:org` scope will be granted but the
runner registration API call will return 403. You must be an org owner/admin,
or ask one to generate the PAT.

There is no way to share a single PAT across organisations you do not own —
each org requires either that you hold admin rights, or that a separate PAT is
issued by an account that does.

### 2. Configure environment

```bash
cp env.example .env
# Edit .env — set ORG_NAME and GITHUB_PAT
```

For each additional org, add a distinct variable to `.env` (e.g.
`SECOND_ORG_NAME=myotherorg`) and reference it in the corresponding service
block in `docker-compose.yml`.

### 3. Configure runners

`docker-compose.yml` ships with one active service block and one commented-out
example. Rename the service and set the env vars to match your org:

```yaml
services:
  github-runner-myorg-1:
    build: .
    restart: always
    environment:
      RUNNER_SCOPE: org          # 'org' for org-level, 'repo' for repo-level
      ORG_NAME: ${ORG_NAME}      # set in .env
      GITHUB_PAT: ${GITHUB_PAT}  # set in .env
      RUNNER_NAME: amd64-${ORG_NAME}-1
      LABELS: self-hosted,linux,amd64,android
      EPHEMERAL: "true"
```

Each service registers as a separate runner. One runner handles one job at a
time — add more service blocks (with distinct `RUNNER_NAME` values) for
parallelism within the same org.

### 4. Start the runner

**Option A — use the pre-built image from GHCR (fastest)**

```bash
docker compose pull
docker compose up -d
```

The `docker-compose.yml` references `ghcr.io/pinnacledigital/github-runner:latest`,
which is built and published automatically on every push to `master`.

**Option B — build the image locally**

```bash
docker compose up -d --build
```

Both options are always available — `image:` and `build:` coexist in the
compose file. `--build` forces a local rebuild regardless of whether a pulled
image exists.

### 5. Verify registration

Go to **GitHub → Org Settings → Actions → Runners** — the runner should appear
as idle within 30 seconds.

## Using the runner in workflows

Target the runner using its labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, amd64, android]
```

## Skipping toolchain installation in workflows

The Android SDK, Java, and Node.js are pre-installed in the image. Workflows can
detect this and skip the download steps:

```yaml
- name: Setup Android SDK
  run: |
    if [ -n "${ANDROID_HOME}" ] && command -v sdkmanager &>/dev/null; then
      echo "ANDROID_HOME=${ANDROID_HOME}" >> $GITHUB_ENV
      echo "ANDROID_SDK_ROOT=${ANDROID_HOME}" >> $GITHUB_ENV
      echo "${ANDROID_HOME}/cmdline-tools/latest/bin" >> $GITHUB_PATH
      echo "${ANDROID_HOME}/platform-tools" >> $GITHUB_PATH
    else
      # fallback: download SDK (GitHub-hosted runner path)
      mkdir -p $HOME/.android/sdk/cmdline-tools
      curl -sSL https://dl.google.com/android/repository/commandlinetools-linux-12266719_latest.zip \
        -o cmdline-tools.zip
      unzip -q cmdline-tools.zip -d $HOME/.android/sdk/cmdline-tools
      mv $HOME/.android/sdk/cmdline-tools/cmdline-tools $HOME/.android/sdk/cmdline-tools/latest
      rm cmdline-tools.zip
      echo "ANDROID_HOME=$HOME/.android/sdk" >> $GITHUB_ENV
      echo "ANDROID_SDK_ROOT=$HOME/.android/sdk" >> $GITHUB_ENV
      echo "$HOME/.android/sdk/cmdline-tools/latest/bin" >> $GITHUB_PATH
      echo "$HOME/.android/sdk/platform-tools" >> $GITHUB_PATH
    fi

- name: Install Android SDK components
  run: |
    if sdkmanager --list_installed 2>/dev/null | grep -q "platforms;android-35"; then
      echo "SDK components already installed, skipping"
    else
      yes | sdkmanager --licenses > /dev/null 2>&1 || true
      sdkmanager "platform-tools" "build-tools;35.0.0" "platforms;android-35"
    fi
```

## runner-check action

This repo ships a reusable GitHub Actions composite action that checks whether
a self-hosted runner matching a given label set is currently online and idle,
then outputs the appropriate `runs-on` value. Workflows use it to prefer
self-hosted runners while falling back to GitHub-hosted runners automatically
when none are available.

### Usage

Add a `check-runner` job at the top of your workflow. All subsequent jobs
consume its output via `fromJSON()`:

```yaml
jobs:
  check-runner:
    name: Resolve runner
    runs-on: ubuntu-latest
    outputs:
      runner: ${{ steps.check.outputs.runner }}
      match_status: ${{ steps.check.outputs.match_status }}
    steps:
      - name: Check runner availability
        id: check
        uses: pinnacledigital/github-runner@v1
        with:
          labels: ${{ vars.RUNNER_LABELS || '["ubuntu-latest"]' }}
          token: ${{ secrets.ORG_RUNNER_PAT || github.token }}
          scope: org           # omit if runners are repo-level
          wait_if_busy: ${{ vars.RUNNER_WAIT_IF_BUSY || 'false' }}

  build:
    needs: check-runner
    runs-on: ${{ fromJSON(needs.check-runner.outputs.runner) }}
    steps:
      - uses: actions/checkout@v6
      # ...
```

Set `RUNNER_LABELS` as a repository or organisation variable (JSON array
string) to match the labels configured on your self-hosted runner:

```
RUNNER_LABELS = ["self-hosted","linux","amd64","android"]
```

When `RUNNER_LABELS` is not set, or no matching runner is online and idle,
all jobs run on `ubuntu-latest`.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `labels` | yes | — | Preferred runner labels as a JSON array string, e.g. `'["self-hosted","android"]'` |
| `fallback` | no | `["ubuntu-latest"]` | Labels to use when no matching runner is found or available |
| `token` | no | `github.token` | Token used to query the runners API. The default `github.token` can only reach repo-level runners. Pass a classic PAT with `admin:org` scope to detect org-level runners. |
| `wait_if_busy` | no | `false` | When `true`, returns the requested labels even if all matching runners are busy, letting GitHub queue the job until one is free. When `false`, falls back immediately to `fallback` if no idle runner is found. |
| `scope` | no | `auto` | Controls which API endpoint is queried. `auto` tries org-level first then falls back to repo-level. `org` queries org-level only and fails with an error if unreachable (use with a PAT). `repo` queries repo-level only and works with the default `github.token`. |

### Outputs

| Output | Description |
|---|---|
| `runner` | Resolved labels JSON array string — pass to `fromJSON()` in `runs-on` |
| `match_status` | Outcome of the runner lookup: `matched` (online and idle), `busy` (online but all occupied), `offline` (no matching runner registered or online), `unavailable` (API could not be reached) |

### How it works

The `check-runner` job always runs on `ubuntu-latest` (guaranteed available).
It queries the GitHub REST API for runners matching the requested label set,
looking for a runner that is `online`, not `busy`, and possesses **all** of
the requested labels. The API endpoint queried depends on `scope`:

- `scope: auto` — tries `/orgs/{org}/actions/runners` first; falls back to
  `/repos/{owner}/{repo}/actions/runners` if the org endpoint is unreachable
- `scope: org` — queries org-level only; emits an error and exits non-zero
  if the API is unreachable (surfaces misconfigured tokens immediately)
- `scope: repo` — queries repo-level only; avoids the extra org API call
  when runners are registered at the repository level

If a matching runner is found and idle, `runner` outputs the requested labels.
If the runner is busy and `wait_if_busy: true`, `runner` still outputs the
requested labels so GitHub queues the job on the self-hosted runner. Otherwise
`runner` outputs the fallback labels. The API call takes ~10 seconds; GitHub
bills it as one minute at the Ubuntu rate (×1).

**Permissions**: `scope: repo` works with the default `github.token` (no
additional permissions needed). `scope: org` or `scope: auto` reaching the
org endpoint requires a classic PAT with `admin:org` scope passed via
`token`.

### Reference styles

All three forms resolve to the same action:

```yaml
uses: pinnacledigital/github-runner@v1                                      # recommended
uses: pinnacledigital/github-runner@master                                  # latest unreleased
uses: pinnacledigital/github-runner/.github/actions/runner-check@v1         # explicit path (symlink)
```

### Testing

```bash
bash test/runner-check.sh
```

Runs 11 shell unit tests covering the jq matching logic against mock API
responses. Requires only `bash` and `jq` — no Docker or GitHub access needed.

## Token rotation

Registration tokens expire after 1 hour. The `token-entrypoint.sh` wrapper calls
the GitHub API on every container start to fetch a fresh token before registration,
so ephemeral runners (`EPHEMERAL: "true"`) re-register successfully after each job
without any manual intervention.

The PAT in `.env` is the only long-lived credential. If it expires or is revoked,
runners will fail to re-register on next start. Rotate it by updating `.env` and
running `docker compose up -d` to restart affected services.

## Updating the toolchain

To update SDK versions, edit the `Dockerfile` and rebuild:

```bash
docker compose build --no-cache
docker compose up -d
```
