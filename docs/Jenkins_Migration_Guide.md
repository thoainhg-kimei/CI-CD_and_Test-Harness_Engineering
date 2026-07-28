# Jenkins CI, AI Triage, and Qodo Cover

Jenkins replaces GitHub Actions as the CI orchestrator. GitHub remains the source repository
and PR system. This Jenkins pipeline intentionally has no Trunk.io integration.

## 1. Build and run Jenkins

Build the reproducible image with the required plugins and Linux packages:

```bash
docker build -t eshop-jenkins:latest jenkins
docker run -d --name jenkins-eshop \
  -p 8080:8080 -p 50000:50000 \
  --add-host=host.docker.internal:host-gateway \
  -v jenkins_eshop_home:/var/jenkins_home \
  eshop-jenkins:latest
```

The named volume persists Jenkins configuration and the npm, Playwright, and Qodo caches.
Do not disable Jenkins authentication when port 8080 is reachable outside the development
machine.

The image contains Node 20.19.5, GitHub CLI, Python, SQLite, jq, process tools, and
Chromium's system libraries. The pipeline downloads Chromium into its persistent cache; no
manual Jenkins tool registration is required.

Ollama must listen on the Docker host at port 11434:

```bash
ollama pull qwen2.5-coder:7b
curl http://localhost:11434/api/tags
```

## 2. Credentials

Create these Jenkins **Secret text** credentials:

- `github-ci-pat`: fine-grained GitHub PAT with repository Contents and Pull requests
  read/write plus GitHub Models read access.
- `github-webhook-token`: random token used to authenticate Generic Webhook Trigger.

No Trunk organization, plugin, or API-token credential is required.

## 3. Pipeline job and webhook

Create one **Pipeline → Pipeline script from SCM** job. Select Git, supply the repository
URL, select a branch containing the new Jenkinsfile, and leave Script Path as `Jenkinsfile`.

Configure a GitHub webhook with JSON payloads and this URL:

```text
http://<jenkins-host>:8080/generic-webhook-trigger/invoke?token=<webhook-token>
```

Subscribe to pushes and pull-request events. Jenkins runs Qodo on `opened`, `reopened`,
`synchronize`, and `ready_for_review`, matching `.github/workflows/qodo-cover.yml`. Qodo is
accepted only for an open, non-draft, same-repository PR targeting `demo`; no label is
required.

Manual builds expose these modes:

- `CI`: run all test suites.
- `QODO`: provide `PR_NUMBER`.
- `TRIAGE`: optionally provide `PR_NUMBER` and a Jenkins `TARGET_BUILD_URL`.
- `AUTO`: classify webhook values; a manual AUTO build defaults to CI.

Commits containing `[skip ci]` are ignored so coverage-badge commits cannot create a loop.

## 4. Pipeline behavior

- Guard plus coverage is blocking.
- Spec is expected bug evidence and makes the build `UNSTABLE`.
- The flaky test runs ten times with one JUnit file per run and is also allowed to be
  `UNSTABLE`.
- Web and admin Playwright run in parallel against one readiness-checked backend.
- Mobile Jest is blocking.
- Jenkins publishes JUnit trends, Cobertura, browser/mobile output, stage logs, and AI
  reports.
- A blocking failure invokes local Ollama triage and comments on the PR when a PR number is
  available.

Because the applications use fixed localhost ports, CI executions are serialized on this
single Docker agent; `inversePrecedence` favors the newest queued revision. Qodo has a
separate model lock. Each build cleans its recorded backend PID and SQLite files and always
performs final cleanup.

## 5. AI triage

On a blocking failure, `scripts/ai-triage-local.js` submits captured stage logs, build
metadata, coverage summary, and flaky evidence to the frozen prompt and local Ollama model.
The Markdown report is archived and optionally posted with `github-ci-pat`. Triage is
non-blocking and never modifies source files.

For a manual rerun, select `TRIAGE`; if `TARGET_BUILD_URL` is set, Jenkins downloads its
`consoleText`. The target URL must be readable from the agent.

## 6. Qodo Cover

On each eligible PR event, `scripts/jenkins-qodo-cover.sh`:

1. Reads PR metadata and changed backend files through GitHub CLI.
2. Creates a baseline using `scripts/qodo-test-coverage.sh`.
3. Runs the pinned Qodo Cover `v0.1.16` binary with GitHub Models `github/gpt-4.1`, target
   coverage 70%, and at most three iterations. The Jenkins GitHub credential is exposed to
   Qodo as `GITHUB_API_KEY`.
4. Rejects modifications outside `tests/api/guard`.
5. Reruns guard coverage and requires an actual coverage increase.
6. Pushes only guard tests to `qodo-cover-<pr>-<build>` and opens a patch PR against the
   original PR branch.

Databases, JSON, logs, XML, HTML, coverage output, and production changes are never committed.
The Qodo stage uses a global Jenkins lock so only one model run is active.

## 7. Rollout and rollback

Keep `.github/workflows/` enabled during the parity trial. Verify representative push, PR,
blocking failure, unstable test, badge, and Qodo-label runs. Then disable GitHub workflow
triggers, but retain their files until the rollback window closes.
