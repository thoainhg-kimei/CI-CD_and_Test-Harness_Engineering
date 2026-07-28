#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER="${1:?usage: jenkins-qodo-cover.sh <pr-number>}"
: "${GH_TOKEN:?GH_TOKEN Jenkins credential is required}"
# The Jenkins SCM checkout is authoritative. `gh repo view` may resolve a fork
# to its parent, while manual Generic Trigger variables may contain JSONPath
# placeholders rather than webhook values.
ORIGIN_URL="$(git remote get-url origin)"
GH_REPOSITORY="$(printf '%s' "$ORIGIN_URL" | sed -E 's#^https://github.com/##; s#^git@github.com:##; s#\.git$##')"
: "${GH_REPOSITORY:?Unable to determine the GitHub repository}"

ACTION_REF="${QODO_ACTION_REF:-v0.1.16}"
MODEL="${QODO_MODEL:-github/gpt-4.1}"
DESIRED_COVERAGE="${QODO_DESIRED_COVERAGE:-70}"
QODO_CACHE_DIR="${QODO_CACHE_DIR:-.cache/qodo}"
WORKSPACE="$(git rev-parse --show-toplevel)"
REPORT_DIR="$WORKSPACE/reports/qodo"
MODIFIED_JSON="$REPORT_DIR/modified-files.json"
mkdir -p "$QODO_CACHE_DIR" "$REPORT_DIR" coverage reports

export GITHUB_TOKEN="$GH_TOKEN"
export GITHUB_API_KEY="$GH_TOKEN"
export GITHUB_WORKSPACE="$WORKSPACE"

PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$GH_REPOSITORY" --json state,isDraft,headRefName,headRefOid,headRepository,headRepositoryOwner,baseRefName,files)"
HEAD_REF="$(node -e 'console.log(JSON.parse(process.argv[1]).headRefName)' "$PR_JSON")"
HEAD_OID="$(node -e 'console.log(JSON.parse(process.argv[1]).headRefOid)' "$PR_JSON")"
REPOSITORY_HEAD_OID="$(gh api "repos/${GH_REPOSITORY}/git/ref/heads/${HEAD_REF}" --jq .object.sha 2>/dev/null || true)"
node -e '
  const p=JSON.parse(process.argv[1]);
  console.log(`Qodo PR validation: repo=${process.argv[2]} head=${p.headRepository?.nameWithOwner ?? "unknown"} owner=${p.headRepositoryOwner?.login ?? "unknown"} base=${p.baseRefName} state=${p.state} draft=${p.isDraft}`);
' "$PR_JSON" "$GH_REPOSITORY"
node -e '
  const p=JSON.parse(process.argv[1]);
  const sameRepo = Boolean(process.argv[3]) && p.headRefOid === process.argv[3];
  if (p.state !== "OPEN" || p.isDraft || p.baseRefName !== "demo" || !sameRepo) process.exit(2);
' "$PR_JSON" "$GH_REPOSITORY" "$REPOSITORY_HEAD_OID" || { echo "PR must be open, non-draft, target demo, and originate in the same repository"; exit 2; }

node -e '
  const fs=require("fs"), path=require("path");
  const p=JSON.parse(process.argv[1]), root=process.argv[2];
  const files=p.files.map(x=>x.path).filter(x=>x.startsWith("backend/")).map(x=>path.join(root,x));
  fs.writeFileSync(process.argv[3], JSON.stringify(files));
' "$PR_JSON" "$WORKSPACE" "$MODIFIED_JSON"

if [ "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).length)' "$MODIFIED_JSON")" = "0" ]; then
  echo "No changed production files under backend; Qodo has nothing to cover."
  exit 0
fi

bash scripts/qodo-test-coverage.sh
cp coverage/coverage-summary.json "$REPORT_DIR/coverage-before.json"
BINARY="$QODO_CACHE_DIR/cover-agent-pro-${ACTION_REF}"
if [ ! -x "$BINARY" ]; then
  curl --fail --location --silent --show-error \
    "https://github.com/qodo-ai/qodo-ci/releases/download/${ACTION_REF}/cover-agent-pro" \
    --output "$BINARY"
  chmod +x "$BINARY"
fi

"$BINARY" \
  --mode pr \
  --project-language javascript \
  --project-root "$WORKSPACE" \
  --diff-coverage false \
  --branch demo \
  --code-coverage-report-path "$WORKSPACE/coverage/cobertura-coverage.xml" \
  --coverage-type cobertura \
  --test-command "bash scripts/qodo-test-coverage.sh" \
  --model "$MODEL" \
  --max-iterations 3 \
  --desired-coverage "$DESIRED_COVERAGE" \
  --run-each-test-separately true \
  --source-folder . \
  --test-folder tests/api/guard \
  --report-dir "$REPORT_DIR" \
  --additional-instructions "Follow Mocha, Chai and Supertest conventions. Add tests only under tests/api/guard. Never modify production code or call external services." \
  --modified-files-json "$MODIFIED_JSON"

mapfile -t CHANGED < <(git status --porcelain | sed -E 's/^...//')
TEST_CHANGED=false
for file in "${CHANGED[@]}"; do
  case "$file" in
    tests/api/guard/*) TEST_CHANGED=true ;;
    coverage/*|reports/*|*.json|*.db|*.sqlite|*.log|*.out|*.xml|*.html) ;;
    *) echo "Qodo attempted an out-of-scope change: $file"; git diff -- "$file"; exit 3 ;;
  esac
done

if [ "$TEST_CHANGED" != true ]; then
  echo "Qodo produced no guard-test changes."
  exit 0
fi

bash scripts/qodo-test-coverage.sh
cp coverage/coverage-summary.json "$REPORT_DIR/coverage-after.json"
node -e '
  const fs=require("fs");
  const before=JSON.parse(fs.readFileSync(process.argv[1])).total.lines.pct;
  const after=JSON.parse(fs.readFileSync(process.argv[2])).total.lines.pct;
  console.log(`Coverage: ${before}% -> ${after}%`);
  if (!(after > before)) process.exit(1);
' "$REPORT_DIR/coverage-before.json" "$REPORT_DIR/coverage-after.json"

git config user.name "Qodo Cover"
git config user.email "cover-bot@qodo.ai"
BRANCH="qodo-cover-${PR_NUMBER}-${BUILD_NUMBER:-$(date +%s)}"
git switch -c "$BRANCH"
git add tests/api/guard
git commit -m "test: add Qodo coverage tests"
git push "https://x-access-token:${GH_TOKEN}@github.com/${GH_REPOSITORY}.git" "$BRANCH"

PATCH_URL="$(gh pr create --repo "$GH_REPOSITORY" --base "$HEAD_REF" --head "$BRANCH" \
  --title "Qodo Cover update for PR #${PR_NUMBER}" \
  --body "AI-generated guard tests validated by Jenkins build ${BUILD_URL:-unknown}. Production files were not modified.")"
gh pr comment "$PR_NUMBER" --repo "$GH_REPOSITORY" --body "Qodo Cover generated and validated a patch PR: ${PATCH_URL}"
