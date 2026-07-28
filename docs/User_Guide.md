# CI/CD & Test Harness User Guide

> The current Jenkins replacement setup, webhook, AI triage, and Qodo instructions are in
> [`Jenkins_Migration_Guide.md`](./Jenkins_Migration_Guide.md). That guide supersedes the
> older local trial commands in section 3. The Jenkins pipeline does not use Trunk.io.

## 1. Prerequisites
- Node.js 20
- Docker Desktop (for Jenkins)
- ngrok (for webhooks)
- GitHub CLI (`gh`)

## 2. Running GitHub Actions
The GitHub Actions workflow is defined in `.github/workflows/ci.yml`. It triggers automatically on:
- `push` to any branch
- `pull_request` to any branch
- `workflow_dispatch` (manual trigger)

You can view runs via the GitHub web interface under the "Actions" tab, or via the GitHub CLI:
```bash
gh run list --workflow "CI/CD Pipeline"
gh run view <run-id>
```
To inspect artifacts like the JUnit report for the backend-spec job, download it directly from the run summary.

## 3. Running Jenkins
Jenkins serves as the traditional CI orchestrator. For a local trial demo (no GitHub
webhook needed — you trigger builds manually), the fastest verified path is a **custom
image with plugins baked in**, so there's no slow first-run "install plugins" wizard.

**3.1 Build a custom image with the plugins this Jenkinsfile needs:**

`plugins.txt`:
```
git
workflow-aggregator
nodejs
junit
coverage
timestamper
```
> `timestamper` is easy to miss: the Jenkinsfile's `options { timestamps() }` fails the
> pipeline at parse time with "Invalid option type" if it's absent.

`Dockerfile`:
```dockerfile
FROM jenkins/jenkins:lts-jdk21
USER root
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
```

```bash
docker build -t eshop-jenkins-demo:latest .
```

**3.2 Run it, skipping the setup wizard** (fine for a local trial; add real security before
exposing this beyond localhost):
```bash
docker run -d --name jenkins-demo \
  -p 8081:8080 -p 50001:50000 \
  -v jenkins_demo_home:/var/jenkins_home \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
  eshop-jenkins-demo:latest
```
Jenkins is then reachable, unauthenticated, at `http://localhost:8081`.

**3.3 Register the `node20` NodeJS tool** (required by `tools { nodejs 'node20' }`).
Easiest via **Manage Jenkins → Tools → NodeJS installations → Add NodeJS**, name exactly
`node20`, version 20.x. (It can also be scripted through **Manage Jenkins → Script Console**,
but the NodeJS plugin's classes live under `jenkins.plugins.nodejs.tools.*` — not the older
`hudson.plugins.nodejs.tools.*` path shown in most tutorials — and must be loaded via
`Jenkins.get().pluginManager.uberClassLoader`, not a plain `import`, or it won't resolve.)

**3.4 Pre-install Playwright's OS-level browser dependencies once, as root.**
The Jenkinsfile deliberately does *not* run `playwright install --with-deps`: the pipeline
executes as the unprivileged `jenkins` user, which has no `sudo` on this agent (unlike a
GH Actions hosted runner, which does). Install the shared libraries chromium needs directly
on the agent/container instead — a one-time step, not part of every build:
```bash
docker exec -u root jenkins-demo bash -c \
  'export PATH=/var/jenkins_home/tools/jenkins.plugins.nodejs.tools.NodeJSInstallation/node20/bin:$PATH && \
   cd /var/jenkins_home/workspace/eshop-demo/frontend-web && npx playwright install --with-deps chromium'
```
(Requires the workspace to already exist from a prior checkout, and the `node20` tool to
already be unpacked.) After this, the pipeline's own `npx playwright install chromium` step
(no `--with-deps`, no root needed) just downloads the browser binary into the `jenkins` user's
own cache — the OS libraries are already satisfied system-wide.

**3.5 Create the Pipeline job:**
1. **New Item → Pipeline**.
2. Pipeline → **Pipeline script from SCM** → SCM: **Git**.
3. **Repository URL**: this repo's GitHub URL. **Credentials**: add a GitHub PAT (Jenkins
   has no equivalent of GHA's auto-injected `GITHUB_TOKEN` — this is a real asymmetry worth
   noting in any CI comparison).
4. **Branch Specifier**: `*/demo` — the Jenkinsfile lives on the `demo` branch, not `main`.
5. **Script Path**: `Jenkinsfile` (default, no change needed).
6. **Build Now**, then watch **Stage View** and the console log.

**Optional — GitHub webhook trigger** (only needed if you want pushes to auto-trigger,
not for a manual trial run): expose Jenkins with `ngrok http 8081` and register
`https://<ngrok-id>.ngrok-free.app/github-webhook/` under the GitHub repo's webhook settings.

You can view the JUnit trend and Coverage report directly in the Jenkins UI after a build.

## 4. Test suites
The testing harness consists of various layers, isolated by `DB_PATH`:
- **Guard Suite (`test:guard`)**: Asserts the ACTUAL behavior of the API. This is a must-pass gate in CI that catches regressions. It runs fast.
- **Spec Suite (`test:spec`)**: Asserts the intended SPEC behavior. It is intentionally allowed to fail (`continue-on-error`) since the repository contains 12 documented bugs. The red test output serves as bug evidence.
- **Flaky Suite (`test:flaky`)**: Contains intentional timing-based flakiness for study.
- **Frontend Smoke Tests**: Playwright for web and admin; Jest for mobile.

Frameworks in use: `mocha + chai + supertest` (backend API), `Playwright` (web + admin), `Jest + RNTL` (mobile).

## 5. AI-triage workflow
When a CI pipeline fails, triage can be assisted with AI (ChatGPT or Claude) using a frozen structured prompt:
1. Extract the failing log from CI (e.g., `gh run view <run-id> --log-failed > logs/flaky_fail.log`).
2. Open the AI interface and paste the frozen system prompt from `docs/ai-triage-prompt.md`.
3. Paste the contents of `flaky_fail.log` at the designated `===LOG START===` block.
4. The AI will output a 3-level hypothesis tree, 3 next-checks, a confidence score, and an AI disclosure statement.

## 6. Failure Modes
- **FM-1 — Hallucinated stack traces on oversized logs.** When a pasted CI log exceeds the model's context window, ChatGPT/Claude may truncate silently and fabricate file names or line numbers not present in the input. *Mitigation:* paste only the failing block (`gh run view --log-failed`), and enforce the prompt rule "write NOT IN LOG when a fact is absent"; cross-check every cited `file:line` against the repo before acting.
- **FM-2 — Blind to private-network bottlenecks.** The AI cannot see inside the local Jenkins Docker subnet, so it misattributes a webhook/ngrok timeout or a container DNS failure to a code bug. *Mitigation:* feed it the Jenkins system log too, and treat any "network" L1 hypothesis as requiring a human `docker logs jenkins` / `curl` check, never an auto-fix.
- **FM-3 — Confident wrong root cause on flaky non-determinism.** Given one failing run, the model may declare a deterministic bug when the true cause is timing variance across runs. *Mitigation:* always supply the 10-run pass/fail table, not a single log; require the CONFIDENCE line + supporting log line so low-evidence claims are visible.

*(AI Disclosures AI-03/04: Failure Modes were identified from observed behavior during our own triage runs; each mitigation is verified against our actual pipeline, not assumed.)*

## 7. Troubleshooting
- **Webhook not firing:** Check your `ngrok` URL; the free tier URL changes every time you restart ngrok. Update the GitHub webhook settings.
- **Allowed-fail vs must-pass:** If the entire GitHub Actions pipeline fails because of `backend-spec`, ensure the job contains `continue-on-error: true`.
- **Coverage badge not updating:** Coverage is only updated from the main branch. Check if the latest run generated the Cobertura report properly in the `backend-guard` step.
- **Network timeouts in Jenkins:** If Jenkins cannot reach GitHub, ensure the container has DNS resolution. You may need to restart Docker Desktop.
- **`install-plugin ... -restart` kills the container instead of restarting Jenkins:** the
  official `jenkins/jenkins` Docker image has no process supervisor to respawn the JVM after
  a safe-restart, so the container just exits. Fix: `docker start jenkins-demo` afterward, or
  install plugins at image-build time (§3.1) instead of at runtime.
- **CLI `create-job`/`build` fails with "Jenkins URL is not configured" or "Unexpected
  request origin":** set the root URL under **Manage Jenkins → System → Jenkins URL** to
  match exactly the host:port the CLI call is made against (e.g. `http://localhost:8080/`
  if running `jenkins-cli.jar` from inside the container, not the host-mapped `8081`).
- **Pipeline fails at parse time with "Invalid option type 'timestamps'":** the
  **Timestamper** plugin isn't installed — add it to `plugins.txt` (§3.1).
- **Guard crashes with `SQLITE_CONSTRAINT: UNIQUE constraint failed: coupons.code`
  instead of just failing tests:** Jenkins reuses the *same workspace* across builds
  (unlike a GHA runner, which is always fresh), so a leftover `backend/test.sqlite` — or
  worse, one left with the wrong file owner by an earlier manual debugging session — makes
  `initDatabase()`'s reseed collide with old rows and crash instead of cleanly resetting.
  Fixed by a `Clean workspace state` stage (`pkill -f "node backend/server.js"` +
  `rm -f backend/test.sqlite`) before every build, plus the same cleanup in `post.always`.
- **Vite dev server crashes with `SyntaxError: ... does not provide an export named
  'styleText'` under the Playwright `webServer`:** the `node20` tool was pinned to an
  old Node patch version (20.11.1) that predates a `node:util` export Vite/rolldown now
  require (need ≥20.19). Re-registering the tool with a newer 20.x version fixes it —
  this is a config mistake on the Jenkins side, not a real GHA-vs-Jenkins difference,
  since `actions/setup-node` with `node-version: 20` always resolves to a current 20.x.
- **`frontend-mobile`'s `npm install` fails with `ERESOLVE` (react vs jest-expo peer
  range):** a genuine, pre-existing peer-dependency conflict in that app's own
  package.json/lockfile, unrelated to Jenkins. Use `npm install --legacy-peer-deps`,
  same as the `npm install`-over-`npm ci` swap for the other frontend apps.
- **A real SUT/frontend bug fails a smoke test and you don't want it to block the whole
  pipeline:** wrap the *entire* step sequence for that stage (install *and* test) in one
  `catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE')` block — wrapping only the
  test step still lets an earlier failing install step (e.g. an ERESOLVE conflict) fail
  the build hard. A build that finishes **UNSTABLE** (not FAILURE) with a full JUnit
  report is the signal this is working as intended.
