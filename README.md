# GitHub Actions Self-Hosted Runner (Enhanced)

A robust, auto-scaling friendly GitHub Actions self-hosted runner. This repository
features a decoupled architecture that separates the core runner lifecycle
from specialized build toolchains (like Android).

## Features & Flavors

The project is split into two main Docker images:

- **Base Image (`latest`):** A lightweight foundation that handles registration,
  token rotation, and health monitoring. Use this for general-purpose jobs.
- **Android Image (`android`):** Inherits from the base image and adds a full
  Android SDK/NDK toolchain, Java 17, and Node.js 24.

### What's included (Android flavor)

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

## Setup

### 1. Choose Authentication Method

You can register runners using three different methods, configured via environment variables in `.env`:

#### A. GitHub App (Recommended)
More secure and scalable than PATs. Create a GitHub App with **Organization/Repository Self-hosted runners: write** permissions.
- `APP_ID`: Your GitHub App ID
- `APP_PRIVATE_KEY`: The contents of your private key file

#### B. Just-In-Time (JIT) Configuration
The most modern approach for ephemeral runners. Pass a pre-generated JIT config string.
- `JIT_CONFIG`: The encoded configuration string from the GitHub API.

#### C. Personal Access Token (Classic)
- `GITHUB_PAT`: A classic PAT with `admin:org` (for org-level) or `repo` (for repo-level) scope.

### 2. Configure environment

```bash
cp env.example .env
# Edit .env and set your chosen authentication variables
```

### 3. Configure runners

`docker-compose.yml` uses the `android` flavor by default. Change the `image`
tag to `latest` if you only need the base runner.

```yaml
services:
  github-runner-myorg-1:
    image: ghcr.io/pinnacledigital/github-runner:android
    restart: always
    environment:
      RUNNER_SCOPE: org
      ORG_NAME: ${ORG_NAME}
      GITHUB_PAT: ${GITHUB_PAT} # or APP_ID/APP_PRIVATE_KEY
      RUNNER_NAME: amd64-android-1
      LABELS: self-hosted,linux,amd64,android
      EPHEMERAL: "true"
```

### 4. Start the runner

```bash
docker compose pull
docker compose up -d
```

## Using the runner in workflows

Target the runner using its labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, amd64, android]
```

## runner-check action

This repo ships a reusable composite action that checks if a self-hosted runner
is currently online and idle, falling back to GitHub-hosted runners if not.

```yaml
jobs:
  check-runner:
    runs-on: ubuntu-latest
    outputs:
      runner: ${{ steps.check.outputs.runner }}
    steps:
      - id: check
        uses: pinnacledigital/github-runner@v1
        with:
          labels: '["self-hosted","android"]'

  build:
    needs: check-runner
    runs-on: ${{ fromJSON(needs.check-runner.outputs.runner) }}
    steps:
      - uses: actions/checkout@v6
      # ...
```

## Quality Assurance

### Testing
- **Action Logic:** `bash test/runner-check.sh`
- **Registration Logic:** `bash test/token-rotation.sh`

### Linting
We use **ShellCheck** and **shfmt** to maintain script quality. A pre-commit hook is available:
1. `brew install pre-commit`
2. `pre-commit install`

## Health Monitoring

The base image includes a Docker `HEALTHCHECK` that monitors the `Runner.Listener`
process. Use `docker ps` to verify the `(healthy)` status of your runners.

## Token Rotation & Security

The `token-entrypoint.sh` wrapper fetches a fresh registration token on every
container start.
- **Security:** Sensitive variables (`GITHUB_PAT`, `APP_PRIVATE_KEY`, `JIT_CONFIG`)
  are `unset` immediately after registration to prevent them from leaking into
  logs or being accessible to build steps.
- **Caching:** Registration tokens are cached locally to survive container
  restarts within their 1-hour validity window.
