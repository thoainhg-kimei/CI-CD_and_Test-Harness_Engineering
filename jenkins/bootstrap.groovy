import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.domains.Domain
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.GitSCM
import hudson.plugins.git.UserRemoteConfig
import hudson.util.Secret
import jenkins.model.Jenkins
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import hudson.model.User
import jenkins.security.ApiTokenProperty

// Idempotent bootstrap for the local Docker demo. Secrets are injected as one-time files
// in JENKINS_HOME and deleted immediately after they enter Jenkins' encrypted credential store.
def jenkins = Jenkins.get()
def home = new File(System.getenv("JENKINS_HOME") ?: "/var/jenkins_home")
def githubTokenFile = new File(home, ".bootstrap-github-token")
def webhookTokenFile = new File(home, ".bootstrap-webhook-token")

def store = SystemCredentialsProvider.getInstance().getStore()
def upsertSecret = { String id, String description, File source ->
  if (!source.isFile()) {
    return
  }
  def value = source.text.trim()
  if (!value) {
    source.delete()
    return
  }
  def existing = com.cloudbees.plugins.credentials.CredentialsProvider.lookupCredentials(
    StringCredentialsImpl.class,
    jenkins,
    null,
    null
  ).find { it.id == id }
  def credential = new StringCredentialsImpl(
    CredentialsScope.GLOBAL,
    id,
    description,
    Secret.fromString(value)
  )
  if (existing) {
    store.updateCredentials(Domain.global(), existing, credential)
  } else {
    store.addCredentials(Domain.global(), credential)
  }
  source.delete()
}

upsertSecret("github-ci-pat", "GitHub API, Models, PR and contents token", githubTokenFile)
upsertSecret("github-webhook-token", "Generic Webhook Trigger token", webhookTokenFile)

def repoUrl = System.getenv("JENKINS_REPO_URL")
def repoBranch = System.getenv("JENKINS_REPO_BRANCH") ?: "demo"
if (repoUrl) {
  def job = jenkins.getItem("eshop-jenkins")
  if (!(job instanceof WorkflowJob)) {
    job = jenkins.createProject(WorkflowJob.class, "eshop-jenkins")
  }
  def scm = new GitSCM(
    [new UserRemoteConfig(repoUrl, null, null, null)],
    [new BranchSpec("*/${repoBranch}")],
    false,
    [],
    null,
    null,
    []
  )
  def definition = new CpsScmFlowDefinition(scm, "Jenkinsfile")
  definition.setLightweight(true)
  job.setDefinition(definition)
  job.setDescription("EShop CI, GitHub Models Qodo Cover, and local AI triage")
  job.save()
}

// Optional one-time automation token request. The caller must remove the output after use.
def apiTokenRequest = new File(home, ".request-bootstrap-api-token")
if (apiTokenRequest.isFile()) {
  def admin = User.getById("admin", false)
  if (admin) {
    def property = admin.getProperty(ApiTokenProperty.class)
    def generated = property.tokenStore.generateNewToken("codex-bootstrap-${System.currentTimeMillis()}")
    admin.save()
    def output = new File(home, ".bootstrap-api-token-output")
    output.text = generated.plainValue
    output.setReadable(false, false)
    output.setWritable(false, false)
    output.setReadable(true, true)
    output.setWritable(true, true)
  }
  apiTokenRequest.delete()
}

jenkins.save()
