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
| Android SDK command-line tools | 20.0 |
| Android build-tools | 35.0.0, 36.0.0 |
| Android platforms | 35, 36 |
| Android NDK | 27.1.12297006 |

The repository builds two images:

| Image | Dockerfile | Use it for |
|---|---|---|
| Base | `Dockerfile` | Everything above. Enough to build APKs. |
| Android emulator | `Dockerfile.android` | The base image plus the libraries the Android emulator needs. Use it for emulator-based jobs such as [Maestro](https://maestro.dev) UI tests. See [Android emulator support (KVM)](#android-emulator-support-kvm). |

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
    image: ghcr.io/pinnacledigital/github-runner:latest
    # Emulator image: swap in this image and the commented build block below
    # image: ghcr.io/pinnacledigital/github-runner-android-emulator:latest
    build: .
    # build:
    #   context: .
    #   dockerfile: Dockerfile.android
    restart: always
    environment:
      RUNNER_SCOPE: org          # 'org' for org-level, 'repo' for repo-level
      ORG_NAME: ${ORG_NAME}      # set in .env
      GITHUB_PAT: ${GITHUB_PAT}  # set in .env
      RUNNER_NAME: amd64-${ORG_NAME}-1
      LABELS: self-hosted,linux,amd64,android
      EPHEMERAL: "true"
    devices:
      - /dev/kvm                 # emulator: KVM access (unused by the base image)
```

The service uses the base image by default. For emulator-based jobs (such as
Maestro UI tests), switch to the emulator image: swap the `image:` line and the
`build:` block for the commented alternatives. The `devices` line maps KVM into
the container for the emulator and is harmless otherwise; see
[Android emulator support (KVM)](#android-emulator-support-kvm).

Each service registers as a separate runner. One runner handles one job at a
time — add more service blocks (with distinct `RUNNER_NAME` values) for
parallelism within the same org.

### 4. Start the runner

Both images are published to GHCR automatically on every push to `master`:

| Image | Use it for |
|---|---|
| `ghcr.io/pinnacledigital/github-runner` | APK builds (default in `docker-compose.yml`) |
| `ghcr.io/pinnacledigital/github-runner-android-emulator` | Emulator-based jobs; the base image plus the emulator libraries |

Both carry the same tags: `latest`, the branch name, version tags and
`sha-<short>`.

**Use the published image (fastest)**

```bash
docker compose pull
docker compose up -d
```

**Build locally**

```bash
docker compose up -d --build
```

`image:` and `build:` coexist in the compose file, so `--build` builds from
`Dockerfile` (or `Dockerfile.android` if you switched to the commented block)
and tags the result with the `image:` name. The emulator image is built `FROM`
the base image, so a local emulator build first pulls
`ghcr.io/pinnacledigital/github-runner:latest` (or build the base first with
`docker build -t ghcr.io/pinnacledigital/github-runner:latest .`).

### 5. Verify registration

Go to **GitHub → Org Settings → Actions → Runners** — the runner should appear
as idle within 30 seconds.

## Android emulator support (KVM)

APK builds only need the toolchain in the base image. Emulator-based jobs, such
as Maestro UI tests that boot an Android emulator, additionally need hardware
virtualization (KVM) and a set of display/audio libraries. Without them the
emulator either refuses to start or hangs silently during boot.

### What the compose changes do

The only compose change the emulator needs is mapping the host's KVM device
into the container:

```yaml
devices:
  - /dev/kvm
```

A device is a runtime property of the container, so it cannot be baked into an
image. Mapping it is sufficient: neither `privileged: true` nor a larger
`shm_size` is required. This was tested with the E2E Maestro workflow (API 34
x86_64 `google_apis` emulator, 4 cores, 4 GB RAM) with `privileged` off and
`/dev/shm` left at Docker's 64 MB default; the emulator booted and the flow
passed on the self-hosted runner. Each configuration was run once. A
browser-based or otherwise shared-memory-heavy job on the same runner may still
want `shm_size` raised.

The runner process runs as root inside the container, so no extra group
membership is needed to open `/dev/kvm`. If you change the image to run as a
non-root user, also add the host's `kvm` group with `group_add: ["<GID>"]`
(find it with `getent group kvm`).

### What `Dockerfile.android` adds

`Dockerfile.android` is `FROM` the base image and installs only what the
emulator needs on top of it:

- Headless X11/GL/audio libraries (`libx11-xcb1`, `libxkbcommon0`, `libgl1`,
  `libegl1`, `libpulse0`, `libnss3`, and related). The emulator's software
  renderer (`-gpu swiftshader_indirect`) loads these at startup and aborts
  without them, with no clear error in the job log.
- `$ANDROID_HOME/emulator` on `PATH`.

It leaves the entrypoint (`token-entrypoint.sh`) and command untouched, so token
rotation and ephemeral re-registration behave the same as in the base image. The
emulator binary and system image themselves are downloaded by the workflow (for
example by `reactivecircus/android-emulator-runner`).

### Host requirements

- A **Linux** host whose CPU supports virtualization (`vmx`/`svm` in
  `/proc/cpuinfo`) with `/dev/kvm` present. Docker Desktop on macOS and Windows
  does not provide `/dev/kvm`, so the emulator image cannot run emulators there.
- An x86_64 CPU; the workflow's emulator must be an x86_64 system image.

### Verify KVM inside the container

```bash
docker compose exec github-runner-myorg-1 sh -c 'test -r /dev/kvm -a -w /dev/kvm && echo KVM OK'
```

Workflows can probe it the same way before choosing a runner; a job can fall
back to a GitHub-hosted runner when `/dev/kvm` is not accessible.

### Troubleshooting

- **Runner never takes the emulator job and the workflow falls back to
  `ubuntu-latest`:** no runner with the requested labels is online. Check
  `docker compose ps` and `docker compose logs`.
- **Containers keep restarting after `.env` changes:** containers keep the
  environment they were created with. Run
  `docker compose up -d --force-recreate` rather than `docker compose restart`.
- **Containers crash-loop with `Runner.Listener: No such file or directory`:**
  a runner self-update (the runner updates itself when its version is behind)
  was interrupted and left a broken install, and `restart: always` reuses that
  container. Rebuild the base image from a current `myoung34/github-runner`
  (`docker pull myoung34/github-runner:latest`, then
  `docker compose build --no-cache`) and recreate the containers.

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

### Input handling

Inputs are normalized before use, so a value pasted into a GitHub form or saved from a Windows editor behaves like the clean value:
leading and trailing whitespace (spaces, tabs, CR, LF) and a UTF-8 byte order mark are removed from every input, including the token.
`labels` and `fallback` must be JSON arrays of strings; they are validated and written as compact one-line JSON, and anything else
fails the step with an error that names the input. A blank `fallback`, `wait_if_busy` or `scope` means its default
(`["ubuntu-latest"]`, `false`, `auto`); blank `labels` is an error.

(Why: a repository variable saved as `["self-hosted","linux","x64"]` followed by CRLF used to make the step write extra lines to
`$GITHUB_OUTPUT`, which GitHub rejects with `Invalid format ''` after the runner had already been matched.)

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

To update SDK versions, edit the `Dockerfile` and rebuild. `Dockerfile.android`
inherits the SDK from the base image, so it only needs editing when the emulator
dependencies change:

```bash
docker compose build --no-cache
docker compose up -d
```

### Automatic rebuilds on new base-image releases

Published images record the upstream runner version they were built on, in the
label `io.github.pinnacledigital.upstream.runner-version` (and the base image
digest in `...upstream.image-digest`). `docker-publish.yml` resolves the upstream
`myoung34/github-runner:latest` image once, builds on exactly that digest, and
writes both labels. The `github-runner-android-emulator` image inherits them. To see them:

```bash
docker image inspect ghcr.io/pinnacledigital/github-runner:latest \
  --format '{{index .Config.Labels "io.github.pinnacledigital.upstream.runner-version"}}'
```

The `Monitor base image release` workflow
(`.github/workflows/monitor-base-image.yml`) runs every 3 days and on demand. It
compares the latest release of
[`myoung34/docker-github-actions-runner`](https://github.com/myoung34/docker-github-actions-runner)
with the label on our published image. If they differ, and Docker Hub's `:latest`
has been rebuilt since that release, it dispatches `docker-publish.yml`, which
rebuilds the base image and then the `github-runner-android-emulator` image on top
of it.

- **Why it matters:** runners self-update when their version is behind the
  latest release, and an interrupted self-update inside a container leaves it
  crash-looping. Rebuilding on the current base avoids that.
- **No separate state:** the published image's label is the record of what has
  been built. If a rebuild fails or has not finished, the label stays stale and
  the next run tries again. An image published before the label existed counts as
  out of date, so the first run after adding it triggers one rebuild.
- **Manual run:** *Actions → Monitor base image release → Run workflow*. Tick
  **force** to rebuild even if the published image is already current.
- **After a rebuild,** pull and recreate the runner containers to pick up the
  new images: `docker compose pull && docker compose up -d --force-recreate`.
- **GitHub disables scheduled workflows** after 60 days without repository
  activity; re-enable it from the Actions tab if that happens.

### Runner selection for this repository's own workflows

`docker-publish.yml` and `monitor-base-image.yml` dogfood the resolver action in
this repo (`uses: ./`). Each starts with a small job on a GitHub-hosted runner
that picks an idle self-hosted runner if there is one, and otherwise falls back
to `ubuntu-latest` immediately (`wait_if_busy: 'false'`; it never queues behind
a busy runner). The emulator-image build resolves again right before it starts,
because the runner is ephemeral and the first job may have used it.

- **Labels** default to `["self-hosted","linux","amd64"]`; override with the
  `RUNNER_LABELS` repository variable.
- **Org-level runners need a token that can list them.** Add an `ORG_RUNNER_PAT`
  secret (classic PAT with `admin:org`). Without it the resolver cannot see
  org-level runners and always falls back to `ubuntu-latest`, which is safe but
  never uses your runners.
- **This is a public repository.** GitHub's runner groups do not allow public
  repositories by default, so enable **Allow public repositories** for the
  runner group, or a job that resolves to your runner will sit queued instead of
  falling back. Only run trusted code there: both workflows trigger on `push`,
  `schedule` and `workflow_dispatch`, never on `pull_request`, so forks cannot
  run code on the runner. Keep it that way.
