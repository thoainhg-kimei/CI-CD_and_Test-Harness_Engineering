// Jenkins replacement for the repository's GitHub Actions workflows.
// GitHub remains the SCM/PR system; Jenkins owns CI, AI triage and Qodo Cover.
pipeline {
  agent any

  parameters {
    choice(name: 'RUN_MODE', choices: ['AUTO', 'CI', 'QODO', 'TRIAGE'], description: 'AUTO classifies a GitHub webhook; other values are manual modes.')
    string(name: 'PR_NUMBER', defaultValue: '', description: 'Required for manual QODO; optional for TRIAGE.')
    string(name: 'TARGET_BUILD_URL', defaultValue: '', description: 'Optional Jenkins consoleText URL for manual TRIAGE.')
  }

  triggers {
    GenericTrigger(
      genericVariables: [
        [key: 'GH_EVENT', value: '$.hook.event', defaultValue: ''],
        [key: 'GH_ACTION', value: '$.action', defaultValue: ''],
        [key: 'GH_REF', value: '$.ref', defaultValue: ''],
        [key: 'GH_AFTER', value: '$.after', defaultValue: ''],
        [key: 'GH_COMMIT_MESSAGE', value: '$.head_commit.message', defaultValue: ''],
        [key: 'GH_PR_NUMBER', value: '$.number', defaultValue: ''],
        [key: 'GH_PR_HEAD_REF', value: '$.pull_request.head.ref', defaultValue: ''],
        [key: 'GH_PR_HEAD_REPO', value: '$.pull_request.head.repo.full_name', defaultValue: ''],
        [key: 'GH_PR_BASE_REF', value: '$.pull_request.base.ref', defaultValue: ''],
        [key: 'GH_PR_STATE', value: '$.pull_request.state', defaultValue: ''],
        [key: 'GH_PR_DRAFT', value: '$.pull_request.draft', defaultValue: ''],
        [key: 'GH_LABEL', value: '$.label.name', defaultValue: ''],
        [key: 'GH_REPOSITORY', value: '$.repository.full_name', defaultValue: '']
      ],
      causeString: 'GitHub webhook: $GH_ACTION $GH_REF PR #$GH_PR_NUMBER',
      tokenCredentialId: 'github-webhook-token',
      printContributedVariables: false,
      printPostContent: false,
      silentResponse: false
    )
  }

  environment {
    DB_PATH = 'backend/test.sqlite'
    PORT = '3000'
    OLLAMA_HOST = 'http://host.docker.internal:11434'
    OLLAMA_MODEL = 'qwen2.5-coder:7b'
    QODO_CACHE_DIR = "${JENKINS_HOME}/caches/qodo"
    NPM_CONFIG_CACHE = "${JENKINS_HOME}/caches/npm"
    PLAYWRIGHT_BROWSERS_PATH = "${JENKINS_HOME}/caches/ms-playwright"
  }

  options {
    skipDefaultCheckout(true)
    timestamps()
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '15'))
    preserveStashes(buildCount: 2)
  }

  stages {
    stage('Classify event') {
      steps {
        script {
          env.EFFECTIVE_PR = params.PR_NUMBER?.trim() ?: (env.GH_PR_NUMBER ?: '')
          env.IS_PR_EVENT = env.GH_PR_NUMBER ? 'true' : 'false'
          env.SKIP_PIPELINE = (env.GH_COMMIT_MESSAGE ?: '').contains('[skip ci]') ? 'true' : 'false'

          if (params.RUN_MODE != 'AUTO') {
            env.RUN_KIND = params.RUN_MODE
          } else if (env.SKIP_PIPELINE == 'true') {
            env.RUN_KIND = 'SKIP'
          } else if (env.GH_PR_NUMBER &&
              ['opened', 'reopened', 'synchronize', 'ready_for_review'].contains(env.GH_ACTION)) {
            def validQodo = env.GH_PR_BASE_REF == 'demo' &&
              env.GH_PR_STATE == 'open' &&
              env.GH_PR_DRAFT != 'true' &&
              env.GH_PR_HEAD_REPO == env.GH_REPOSITORY
            // ci.yml and qodo-cover.yml are separate GitHub workflows, so eligible PR
            // events normally execute both behaviors in this single Jenkins pipeline.
            // ready_for_review is explicit only in qodo-cover.yml, not ci.yml.
            if (env.GH_ACTION == 'ready_for_review') {
              env.RUN_KIND = validQodo ? 'QODO' : 'SKIP'
            } else {
              env.RUN_KIND = validQodo ? 'CI_QODO' : 'CI'
            }
          } else if (env.GH_PR_NUMBER) {
            // qodo-cover.yml does not subscribe to labeled/closed/converted-to-draft events,
            // and ci.yml's default pull_request trigger does not subscribe to them either.
            env.RUN_KIND = 'SKIP'
          } else {
            env.RUN_KIND = 'CI'
          }

          env.BUILD_KEY = env.EFFECTIVE_PR ? "pr-${env.EFFECTIVE_PR}" :
            ((env.GH_REF ?: env.BRANCH_NAME ?: 'manual').replaceAll('[^A-Za-z0-9_.-]', '-'))
          currentBuild.description = "${env.RUN_KIND} ${env.BUILD_KEY}"
          echo "Run kind: ${env.RUN_KIND}; key: ${env.BUILD_KEY}"
        }
      }
    }

    stage('Checkout requested revision') {
      when { expression { env.RUN_KIND != 'SKIP' && env.RUN_KIND != 'TRIAGE' } }
      steps {
        deleteDir()
        checkout scm
        withCredentials([string(credentialsId: 'github-ci-pat', variable: 'GH_TOKEN')]) {
          sh '''
            set -eu
            if [ -n "${EFFECTIVE_PR:-}" ]; then
              gh pr checkout "$EFFECTIVE_PR" --force
            elif [ -n "${GH_AFTER:-}" ]; then
              git fetch origin "$GH_AFTER"
              git checkout --detach "$GH_AFTER"
            fi
            git submodule update --init --recursive
          '''
        }
      }
    }

    stage('CI') {
      when { expression { env.RUN_KIND == 'CI' || env.RUN_KIND == 'CI_QODO' } }
      // The applications use fixed localhost ports, so CI executions on this single
      // Docker agent must not overlap. inversePrecedence drops older queued revisions.
      options { lock(resource: 'eshop-ci-agent', inversePrecedence: true) }
      stages {
        stage('Clean workspace state') {
          steps {
            sh '''
              set +e
              if [ -f .jenkins/backend.pid ]; then kill "$(cat .jenkins/backend.pid)" 2>/dev/null; fi
              set -e
              rm -rf reports coverage .nyc_output playwright-report test-results .jenkins
              rm -f backend/test.sqlite
              mkdir -p reports/flaky logs/jenkins .jenkins
            '''
          }
        }

        stage('Install dependencies') {
          steps {
            sh '''
              set -o pipefail
              npm ci --prefer-offline 2>&1 | tee logs/jenkins/install-root.log
              (cd backend && npm ci --prefer-offline) 2>&1 | tee logs/jenkins/install-backend.log
            '''
          }
        }

        stage('Backend tests') {
          stages {
            stage('Guard + coverage') {
              steps {
                sh 'set -o pipefail; npm run test:coverage 2>&1 | tee logs/jenkins/guard.log'
              }
            }
            stage('Spec (allowed-fail)') {
              steps {
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                  sh 'set -o pipefail; npm run test:spec 2>&1 | tee logs/jenkins/spec.log'
                }
              }
            }
            stage('Flaky x10 (allowed-fail)') {
              steps {
                script {
                  def failed = false
                  for (int i = 1; i <= 10; i++) {
                    def rc = sh(
                      returnStatus: true,
                      script: """set -o pipefail
                        npm run test:flaky -- --reporter-options mochaFile=reports/flaky/run-${i}.xml \
                          2>&1 | tee logs/jenkins/flaky-${i}.log
                      """
                    )
                    failed = failed || rc != 0
                  }
                  if (failed) {
                    catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                      error('At least one flaky evidence run failed')
                    }
                  }
                }
              }
            }
          }
        }

        stage('Frontend smoke tests') {
          stages {
            stage('Start smoke backend') {
              steps {
                sh '''
                  set -eu
                  DB_PATH=backend/test.sqlite PORT=3000 node backend/server.js > logs/jenkins/backend-smoke.log 2>&1 &
                  echo $! > .jenkins/backend.pid
                  ready=false
                  for i in $(seq 1 30); do
                    if curl --silent --output /dev/null http://127.0.0.1:3000/; then ready=true; break; fi
                    if ! kill -0 "$(cat .jenkins/backend.pid)" 2>/dev/null; then
                      cat logs/jenkins/backend-smoke.log
                      exit 1
                    fi
                    sleep 1
                  done
                  if [ "$ready" != true ]; then
                    echo "Backend did not become ready within 30 seconds"
                    exit 1
                  fi
                '''
              }
            }
            stage('Smoke suites') {
          parallel {
            stage('Web Playwright') {
              steps { script { runPlaywright('frontend-web', 'web') } }
            }
            stage('Admin Playwright') {
              steps { script { runPlaywright('frontend-admin', 'admin') } }
            }
            stage('Mobile Jest') {
              steps {
                dir('frontend-mobile') {
                  sh '''
                    set -o pipefail
                    npm ci --legacy-peer-deps --prefer-offline 2>&1 | tee ../logs/jenkins/mobile-install.log
                    npm run test:ci 2>&1 | tee ../logs/jenkins/mobile.log
                  '''
                }
              }
            }
          }
            }
          }
        }

        stage('Coverage badge') {
          when { expression { currentBuild.currentResult != 'FAILURE' } }
          steps {
            withCredentials([string(credentialsId: 'github-ci-pat', variable: 'GH_TOKEN')]) {
              sh '''
                set -eu
                npx make-coverage-badge
                if git diff --quiet -- coverage/badge.svg; then
                  echo "Coverage badge unchanged"
                  exit 0
                fi
                git config user.name "Jenkins CI"
                git config user.email "jenkins-ci@users.noreply.github.com"
                REPOSITORY="${GH_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
                REF_VALUE="${GH_REF:-}"
                GIT_BRANCH_VALUE="${GIT_BRANCH:-}"
                TARGET_BRANCH="${GH_PR_HEAD_REF:-${REF_VALUE#refs/heads/}}"
                TARGET_BRANCH="${TARGET_BRANCH:-${BRANCH_NAME:-}}"
                TARGET_BRANCH="${TARGET_BRANCH:-${GIT_BRANCH_VALUE#origin/}}"
                if [ -z "$TARGET_BRANCH" ]; then
                  echo "Cannot determine a safe badge target branch; leaving badge as an artifact."
                  exit 0
                fi
                git add coverage/badge.svg
                git commit -m "chore: update coverage badge [skip ci]"
                git push "https://x-access-token:${GH_TOKEN}@github.com/${REPOSITORY}.git" HEAD:"${TARGET_BRANCH}"
              '''
            }
          }
        }
      }
    }

    stage('Qodo Cover') {
      when { expression { env.RUN_KIND == 'QODO' || env.RUN_KIND == 'CI_QODO' } }
      options { lock(resource: 'qodo-cover-github-models', inversePrecedence: true) }
      steps {
        withCredentials([string(credentialsId: 'github-ci-pat', variable: 'GH_TOKEN')]) {
          sh '''
            set -o pipefail
            npm ci --prefer-offline
                (cd backend && npm ci --prefer-offline)
            bash scripts/jenkins-qodo-cover.sh "$EFFECTIVE_PR" 2>&1 | tee logs/qodo-cover.log
          '''
        }
      }
    }

    stage('Manual AI triage') {
      when { expression { env.RUN_KIND == 'TRIAGE' } }
      steps {
        checkout scm
        withCredentials([string(credentialsId: 'github-ci-pat', variable: 'GH_TOKEN')]) {
          sh '''
            set -eu
            mkdir -p logs reports/ai
            if [ -n "${TARGET_BUILD_URL:-}" ]; then
              curl --fail --silent --show-error "${TARGET_BUILD_URL%/}/consoleText" > logs/jenkins-target.log
            else
              cp logs/ci_fail_trim.log logs/jenkins-target.log
            fi
            node scripts/ai-triage-local.js logs/jenkins-target.log reports/ai/triage.md
            if [ -n "${EFFECTIVE_PR:-}" ]; then
              gh pr comment "$EFFECTIVE_PR" --body-file reports/ai/triage.md
            fi
          '''
        }
      }
    }
  }

  post {
    failure {
      script {
        catchError(buildResult: 'FAILURE', stageResult: 'UNSTABLE') {
          withCredentials([string(credentialsId: 'github-ci-pat', variable: 'GH_TOKEN')]) {
            sh '''
              set +x
              mkdir -p reports/ai logs/jenkins
              find logs/jenkins -type f -name '*.log' -print -exec tail -n 500 {} \\; > logs/jenkins/console.log
              node scripts/ai-triage-local.js logs/jenkins/console.log reports/ai/triage.md || exit 0
              if [ -n "${EFFECTIVE_PR:-}" ]; then
                gh pr comment "$EFFECTIVE_PR" --body-file reports/ai/triage.md || true
              fi
            '''
          }
        }
      }
    }
    always {
      sh '''
        set +e
        if [ -f .jenkins/backend.pid ]; then kill "$(cat .jenkins/backend.pid)" 2>/dev/null; fi
        rm -f backend/test.sqlite
      '''
      junit allowEmptyResults: true, keepLongStdio: true, testResults: 'reports/**/*.xml'
      script {
        if (fileExists('coverage/cobertura-coverage.xml')) {
          recordCoverage enabledForFailure: true, tools: [[parser: 'COBERTURA', pattern: 'coverage/cobertura-coverage.xml']]
        }
      }
      archiveArtifacts allowEmptyArchive: true, artifacts: 'reports/**,coverage/**,logs/**,playwright-report/**,test-results/**'
    }
  }
}

void runPlaywright(String app, String reportName) {
  dir(app) {
    sh """set -o pipefail
      npm ci --legacy-peer-deps --prefer-offline 2>&1 | tee ../logs/jenkins/${reportName}-install.log
      npx playwright install chromium
    """
  }
  dir(app) {
    sh """set -o pipefail
      CI=true PLAYWRIGHT_JUNIT_OUTPUT_NAME=../reports/playwright-${reportName}.xml \
        npx playwright test --reporter=junit,list 2>&1 | tee ../logs/jenkins/playwright-${reportName}.log
    """
  }
}
