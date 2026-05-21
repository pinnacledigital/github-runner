# GitHub Actions Self-Hosted Runner (Android Optimized)

Self-hosted GitHub Actions runner optimized for Android app builds. It packages the runner agent, full Android SDK/NDK toolchain, Java 17, and Node.js 24 into a single Docker image.

## Project Overview

- **Main Technologies:** Docker, Bash, GitHub Actions, Android SDK/NDK, Java 17, Node.js 24.
- **Core Components:**
    - `Dockerfile`: Bases on `myoung34/github-runner:latest`. Installs Android toolchain and custom entrypoint.
    - `token-entrypoint.sh`: Handles automated runner registration and token rotation using a GitHub Personal Access Token (PAT).
    - `runner-check` action (`action.yml`): A composite action that checks for online/idle self-hosted runners, allowing workflows to dynamically fallback to GitHub-hosted runners if needed.
    - `docker-compose.yml`: Manages runner instances with persisted caches for Gradle and npm.

## Building and Running

- **Start Runner (Pre-built):** `docker compose pull && docker compose up -d`
- **Build and Start Locally:** `docker compose up -d --build`
- **Stop Runner:** `docker compose down`
- **Update Toolchain:** Edit `Dockerfile` and run `docker compose build --no-cache`.
- **Run Action Tests:** `bash test/runner-check.sh` (Tests the `jq` logic in the `runner-check` action against mock API responses).

## Configuration

- **Environment Variables:** Copy `env.example` to `.env`.
    - `ORG_NAME`: The GitHub organization for org-level runners.
    - `GITHUB_PAT`: A classic Personal Access Token with `admin:org` scope.
- **Service Configuration:** Configure runner services in `docker-compose.yml`. Each service block represents one parallel runner.
- **Runner Labels:** Default labels include `self-hosted,linux,amd64,android`.

## Development Conventions

- **Ephemeral Runners:** Set `EPHEMERAL: "true"` in `docker-compose.yml` to ensure runners are cleaned up after every job. `token-entrypoint.sh` ensures fresh registration tokens are fetched.
- **Cache Persistence:** Gradle and npm caches are stored in named Docker volumes (`gradle-cache`, `npm-cache`) to speed up builds.
- **Dynamic Runner Selection:** Workflows should use the `runner-check` action to check for available self-hosted runners before starting build jobs.
- **Toolchain Maintenance:** The image pre-installs the SDK. Workflows can skip toolchain installation steps by checking for existing `ANDROID_HOME` or `sdkmanager`.
