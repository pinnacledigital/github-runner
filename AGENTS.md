# GitHub Actions Self-Hosted Runner (Enhanced & Optimized)

This repository provides a robust, auto-scaling friendly GitHub Actions self-hosted runner. It features a decoupled architecture separating lifecycle management from build toolchains.

## Architecture

- **Base Image (Dockerfile):** Handles runner lifecycle, including registration and token rotation. Inherits from myoung34/github-runner.
- **Specialized Images (e.g., Dockerfile.android):** Inherit from the base image and add specific build tools (Android SDK, Java, Node.js).
- **Rotation Wrapper (token-entrypoint.sh):** A sophisticated entrypoint that manages registration tokens and supports multiple authentication methods.

## Features

- **Authentication Methods:**
    - **GitHub Apps (Recommended):** Uses APP_ID and APP_PRIVATE_KEY to generate short-lived installation tokens.
    - **JIT Configuration:** Supports Just-In-Time configuration (JIT_CONFIG) for seamless ephemeral scaling.
    - **PAT Rotation:** Supports Personal Access Tokens for org and repo level registration.
    - **Static Tokens:** Supports pre-generated RUNNER_TOKEN.
- **Security:**
    - Automatically scrubs sensitive environment variables (GITHUB_PAT, APP_PRIVATE_KEY, JIT_CONFIG) after registration.
    - Uses non-persistent registration tokens.
- **Optimized for Android:** Pre-packages SDK, NDK, and common build tools in the android flavor.
- **CI/CD Workflow:** Automatically builds and pushes images to GHCR, ensuring the base image is built before specialized ones.

## Quality Assurance

### Testing
The project includes a suite of shell unit tests to verify core logic without requiring a full Docker environment.
- **Action Logic:** `bash test/runner-check.sh` (Tests the `jq` matching logic in the `runner-check` action).
- **Registration Logic:** `bash test/token-rotation.sh` (Tests `token-entrypoint.sh` caching and lifecycle management).

### Linting & Formatting
Consistent style and catch common shell script errors are enforced via:
- **ShellCheck:** Static analysis for shell scripts.
- **shfmt:** Shell script formatter (configured for 2-space indentation).
- **EditorConfig:** IDE-level consistency via `.editorconfig`.
- **Pre-commit Hooks:** Run these checks automatically before every commit.

#### Setting up Pre-commit Locally
1. Install the framework: `brew install pre-commit` (or `pip install pre-commit`).
2. Install the hooks: `pre-commit install`.
3. (Optional) Run against all files: `pre-commit run --all-files`.

A dedicated CI workflow (`lint.yml`) also runs these checks on every PR.


| Variable | Description |
|---|---|
| RUNNER_SCOPE | org or repo. |
| ORG_NAME | Required for org scope. |
| GITHUB_PAT | Classic PAT for registration. |
| APP_ID / APP_PRIVATE_KEY | For GitHub App authentication. |
| JIT_CONFIG | Full encoded JIT configuration string. |
| EPHEMERAL | Set to "true" for single-job runners. |

## Development Conventions

- **Adding New Flavors:** Create a new Dockerfile.<name> inheriting from the base image and add it to the matrix in .github/workflows/docker-publish.yml.
- **Token Caching:** Registration tokens are cached in /var/run/github-runner/token.cache to survive container restarts within the 1-hour validity window.
