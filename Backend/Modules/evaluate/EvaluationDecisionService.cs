using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

internal static class EvaluationDecisionService
{
    public static string EvaluateEvidenceOutcome(string evidence)
    {
        if (string.IsNullOrWhiteSpace(evidence)) return ManualVerdict.NeedsReview;
        if (evidence.IndexOf("SQL ERROR", System.StringComparison.OrdinalIgnoreCase) >= 0) return ManualVerdict.Fail;
        return ManualVerdict.Parse(evidence);
    }

    public static Task<string> BuildManualInstructionsAsync(ChecklistItem item, bool isDocumentationCheck = false)
        => Task.FromResult(BuildManualInstructions(item, isDocumentationCheck));

    // Builds manual verification steps tailored to a single checklist item from its
    // Id, Description and Category. No LLM/network call is made, so each item
    // deterministically gets its own item-specific guidance, not a shared template.
    public static string BuildManualInstructions(ChecklistItem item, bool isDocumentationCheck = false)
    {
        return isDocumentationCheck || IsDocumentationTopic(item)
            ? BuildDocumentationInstructions(item)
            : BuildInstanceInstructions(item);
    }

    private static string BuildInstanceInstructions(ChecklistItem item)
    {
        var description = (item.Description ?? string.Empty).Trim();
        var category = (item.Category ?? string.Empty).Trim();
        var topic = ClassifyTopic(description, category);
        var control = string.IsNullOrWhiteSpace(description) ? "this control" : $"\"{description}\"";

        var sb = new StringBuilder();
        sb.Append("Checklist: ").Append(item.Id).Append(" - ").AppendLine(description);
        if (!string.IsNullOrWhiteSpace(category))
            sb.Append("Audit area: ").AppendLine(category);
        sb.Append("Objective: Confirm that ").Append(control).AppendLine(" is correctly implemented and consistently enforced on the audited SQL Server instance, with objective evidence to support the finding.");
        sb.AppendLine();

        // Prerequisites — what the reviewer needs before starting, so the steps below
        // can be followed without guesswork.
        sb.AppendLine("## Prerequisites");
        sb.AppendLine("- Connect with SSMS or Azure Data Studio using an account that has at least VIEW SERVER STATE and VIEW DEFINITION (plus any control-specific permissions) on the databases in scope.");
        sb.Append("- Have your organisation's documented standard or policy for ").Append(control).AppendLine(" to hand, so you have a baseline to compare against.");
        sb.AppendLine("- Confirm which databases and objects are in scope for this audit before you begin.");
        sb.AppendLine();

        sb.AppendLine("## Manual Verification Steps:");
        var step = 1;
        sb.Append(step++).Append(". ").AppendLine(topic.Focus);
        foreach (var s in topic.Steps)
            sb.Append(step++).Append(". ").AppendLine(s);
        if (!string.IsNullOrWhiteSpace(topic.ExampleSql))
        {
            sb.Append(step++).AppendLine(". Run the query below in each in-scope database to gather objective evidence:");
            sb.AppendLine("```sql");
            sb.AppendLine(topic.ExampleSql.Trim());
            sb.AppendLine("```");
            sb.Append(step++).AppendLine(". Review the result set and flag every row that deviates from the documented standard.");
        }
        sb.Append(step++).Append(". Compare what you observe against your organisation's documented standard for ").Append(control).AppendLine(", noting each deviation and its scope (which objects/databases are affected).");
        sb.Append(step++).AppendLine(". Repeat across all in-scope databases — confirm the control holds everywhere, not just in a sample.");
        sb.Append(step++).AppendLine(". Record the concrete evidence you relied on (query results, setting values, object names, screenshots) so the finding can be reviewed later.");
        sb.AppendLine();

        // Evidence to capture — makes the finding auditable and repeatable.
        sb.AppendLine("## Evidence to Capture");
        sb.AppendLine("- The query output or configuration values you inspected.");
        sb.AppendLine("- The specific objects/settings that conform, and those that deviate from the standard.");
        sb.AppendLine("- A reference to the organisational standard used as the baseline for comparison.");
        sb.AppendLine();

        sb.AppendLine("## What indicates a PASS and a FAIL");
        sb.AppendLine("Pass:");
        sb.Append("- ").AppendLine(topic.PassHint);
        sb.AppendLine("- The control is applied consistently across all in-scope objects and databases, not just a sample.");
        sb.AppendLine("- You can point to concrete evidence (a query result, a setting value, or an object definition).");
        sb.AppendLine("Fail:");
        sb.Append("- ").AppendLine(topic.FailHint);
        sb.AppendLine("- The control is applied inconsistently or only partially across the in-scope scope.");
        sb.AppendLine("- No evidence of the control can be found on the instance.");
        sb.AppendLine();
        sb.AppendLine("If the evidence is mixed or incomplete, keep the item as Needs Review and gather more detail before deciding.");
        sb.AppendLine();

        sb.AppendLine("## Recommended Actions (if failed)");
        sb.Append("- ").AppendLine(topic.Remediation);
        sb.AppendLine("- Prioritise remediation by risk, and record the owner and a target completion date.");
        sb.AppendLine("- Raise the gap with the team that owns this instance and re-run this checklist item once the change has been deployed.");

        return sb.ToString().TrimEnd();
    }

    // Documentation and process controls live in repositories, pipelines and documents, never on the
    // instance, so they get artefact-oriented guidance instead of SSMS/T-SQL steps.
    private static string BuildDocumentationInstructions(ChecklistItem item)
    {
        var description = (item.Description ?? string.Empty).Trim();
        var category = (item.Category ?? string.Empty).Trim();
        var artefact = ClassifyArtefact(description, category);
        var control = string.IsNullOrWhiteSpace(description) ? "this control" : $"\"{description}\"";

        var sb = new StringBuilder();
        sb.Append("Checklist: ").Append(item.Id).Append(" - ").AppendLine(description);
        if (!string.IsNullOrWhiteSpace(category))
            sb.Append("Audit area: ").AppendLine(category);
        sb.Append("Objective: Confirm that ").Append(control)
          .AppendLine(" is evidenced by a real artefact - a repository, pipeline definition, document or record - that is current and matches what is actually in use.");
        sb.AppendLine("This control cannot be judged from the SQL Server instance; do not attempt to verify it with T-SQL.");
        sb.AppendLine();

        sb.AppendLine("## Evidence to Obtain");
        foreach (var source in artefact.Sources)
            sb.Append("- ").AppendLine(source);
        sb.AppendLine("- The name and owner of the team responsible for this artefact, so gaps can be routed to them.");
        sb.AppendLine();

        sb.AppendLine("## Manual Verification Steps:");
        var step = 1;
        sb.Append(step++).Append(". ").AppendLine(artefact.Focus);
        foreach (var s in artefact.Steps)
            sb.Append(step++).Append(". ").AppendLine(s);
        sb.Append(step++).AppendLine(". Confirm the artefact is current - check its last-modified date, version or commit history against the most recent change to the platform it describes.");
        sb.Append(step++).AppendLine(". Confirm it reflects the environment actually being audited, not a template, a draft or a superseded design.");
        sb.Append(step++).AppendLine(". Record exactly what you inspected: file paths, repository and branch or commit, document titles and versions, dates, and the people who confirmed it.");
        sb.AppendLine();

        sb.AppendLine("## Evidence to Capture");
        sb.AppendLine("- The identifier of each artefact you relied on (repository URL and commit, pipeline file path, document title and version, ticket or record ID).");
        sb.AppendLine("- The specific section, file or setting inside it that evidences the control.");
        sb.AppendLine("- Its last review/modification date, so currency can be judged.");
        sb.AppendLine();

        sb.AppendLine("## What indicates a PASS, a FAIL and NOT APPLICABLE");
        sb.AppendLine("Pass:");
        sb.Append("- ").AppendLine(artefact.PassHint);
        sb.AppendLine("- The artefact is current, accessible to the people who need it, and consistent with the environment being audited.");
        sb.AppendLine("Fail:");
        sb.Append("- ").AppendLine(artefact.FailHint);
        sb.AppendLine("- The artefact exists but is stale, incomplete, unapproved, or does not cover the environment being audited.");
        sb.AppendLine("Needs Review (only this case):");
        sb.AppendLine("- No artefact addressing this control was supplied at all, so there is nothing to judge it against.");
        sb.AppendLine("  If an artefact for this control WAS supplied, decide Pass or Fail from it - do not defer.");
        sb.AppendLine("Not Applicable:");
        sb.Append("- ").AppendLine(artefact.NotApplicableHint);
        sb.AppendLine();
        sb.AppendLine("Start your response with the verdict word - Pass, Fail or Not Applicable - followed by what you inspected and what you found.");
        sb.AppendLine("If no artefact was produced and you cannot confirm whether one exists, leave the item as Needs Review rather than guessing.");
        sb.AppendLine();

        sb.AppendLine("## Recommended Actions (if failed)");
        sb.Append("- ").AppendLine(artefact.Remediation);
        sb.AppendLine("- Assign a named owner and a review cadence so the artefact does not drift out of date again.");
        sb.AppendLine("- Store it where the team that operates this platform can find it, and link it from the platform's entry-point documentation.");

        return sb.ToString().TrimEnd();
    }

    private sealed record ArtefactGuidance(
        string Focus,
        string[] Sources,
        string[] Steps,
        string PassHint,
        string FailHint,
        string NotApplicableHint,
        string Remediation);

    private static ArtefactGuidance ClassifyArtefact(string description, string category)
    {
        var text = (description + " " + category).ToLowerInvariant();
        bool Has(params string[] keys) => keys.Any(k => text.Contains(k));
        var control = string.IsNullOrWhiteSpace(description) ? "this control" : $"\"{description}\"";

        if (Has("source-control", "source control", "branching", "pull request", "commit message", "secret-scanning", "secret scanning", "repository"))
            return new ArtefactGuidance(
                "Open the repository that holds the database schema, code and ETL assets for this platform.",
                new[]
                {
                    "The repository URL (Azure DevOps, GitHub or equivalent) and the branch that represents production.",
                    "Repository settings: branch policies/protection rules, required reviewers, and security/secret-scanning configuration.",
                    "Recent commit and pull-request history for the production branch.",
                },
                new[]
                {
                    "Confirm the assets this item names are actually in the repository (SQL project/DACPAC, migration scripts, ETL package or pipeline definitions) and not only on a server or a share.",
                    "Inspect the branch policy on the production branch: whether reviews are required, how many approvers, and whether the policy is enforced rather than advisory.",
                    "Sample the last 20-30 commits or pull requests and check they follow the stated convention (descriptive messages, linked work items, reviewed before merge).",
                    "Check repository security settings for secret scanning / push protection, and confirm no credentials are committed in configuration files.",
                },
                $"The repository contains the assets {control} requires, and the repository settings enforce the practice rather than relying on convention.",
                $"The assets are outside source control, or the policy that would enforce {control} is absent, disabled, or routinely bypassed.",
                "There is no application or database codebase for this platform to place under source control - record what is deployed and how, so the exclusion is justified.",
                "Bring the missing assets into the repository and enforce the practice through branch policies rather than team convention.");

        // "deploy" alone is deliberately absent: the audit area "Solution & Deployment Architecture"
        // contains it, which routed every architecture item here instead of to its own branch.
        if (Has("pipeline", "automated build", "automated deployment", "dacpac", "rollback", "pre/post-deployment", "pre-deployment", "post-deployment", "ci/cd", "release process"))
            return new ArtefactGuidance(
                "Open the CI/CD pipeline definitions that build and deploy this database, and the record of their recent runs.",
                new[]
                {
                    "Pipeline definition files (for example azure-pipelines.yml, .github/workflows/*.yml, a Jenkinsfile, or a classic pipeline export).",
                    "The run history for those pipelines, showing which environments were deployed and when.",
                    "Any documented rollback or recovery procedure, and evidence it has been exercised.",
                },
                new[]
                {
                    "Read the pipeline definition and identify each stage, the environment it targets, and what it actually deploys.",
                    "Confirm the promotion path this item requires exists in the definition (for example Dev then Test then Prod) and that later stages are gated by approvals rather than run ad hoc.",
                    "Check whether the deployment step is automated from the repository, or whether a human still runs scripts by hand.",
                    "For rollback and pre/post-deployment scripts, confirm the procedure is in the definition or a linked runbook, and look for a run or a test that proves it works.",
                },
                $"A pipeline definition implements {control}, and its run history shows it is the route changes actually take.",
                $"No pipeline implements {control}, or one exists but is bypassed, disabled, or has never successfully run for this database.",
                "This platform has no deployable database artefacts and no release process to automate - record how changes reach the instance instead.",
                "Add the missing stage, gate or script to the pipeline definition and prove it end to end in a non-production environment.");

        if (Has("environment", "dev / test / prod", "dev/test/prod", "parity", "representative"))
            return new ArtefactGuidance(
                "Compare the environments this platform uses and the configuration that defines them.",
                new[]
                {
                    "The inventory of environments (names, servers/instances, subscriptions or resource groups).",
                    "Environment configuration: variable groups, parameter files, IaC templates, or the settings held per environment in the pipeline.",
                    "Any documented statement of how non-production data is sized, refreshed or masked.",
                },
                new[]
                {
                    "List the environments that exist and confirm they are genuinely separate instances/databases, not schemas or naming conventions inside one server.",
                    "Diff the configuration held for each environment and note every setting that differs without a stated reason.",
                    "Where the item concerns representativeness, compare data volume, schema version and workload shape between non-production and production.",
                },
                $"Distinct environments exist and their configuration evidences {control}.",
                $"Environments are shared, missing, or their configuration diverges in ways that invalidate {control}.",
                "Only a single environment exists by design (for example a standalone analytical sandbox) and no promotion path is intended.",
                "Separate the environments or align their configuration, and hold the differences in source-controlled, per-environment configuration.");

        if (Has("maintenance window", "patching", "patch", "cumulative update"))
            return new ArtefactGuidance(
                "Obtain the maintenance and patching policy for this platform, and the record of it being applied.",
                new[]
                {
                    "The documented maintenance windows per environment, and how they are announced.",
                    "The patching approach: who decides, how updates are tested before production, and the rollback position.",
                    "The record of recent maintenance - what was applied, when, and to which environment.",
                },
                new[]
                {
                    "Confirm the maintenance window is written down per environment rather than agreed informally.",
                    "Read the patching process end to end and confirm it names who approves, how long changes soak in a lower environment, and what happens for security-rated updates.",
                    "Check the recorded patch level against what the instance actually reports, and confirm the last maintenance entry is recent enough to show the process is live.",
                },
                $"A current, approved document evidences {control}, and the maintenance record shows it is followed in practice.",
                $"No maintenance window or patching approach is documented, it is a draft with no owner, or the recorded patch history contradicts it.",
                "The platform is fully vendor-managed (PaaS) so patching is Microsoft's responsibility - record that as the basis.",
                "Document the windows and the patching process, get it approved, and keep a dated record of each maintenance event.");

        if (Has("architecture", "topology", "diagram", "deployment model", "capacity", "scale approach"))
            return new ArtefactGuidance(
                "Obtain the architecture documentation for this platform and compare it against what is actually deployed.",
                new[]
                {
                    "The architecture overview document or diagram, with its version and date.",
                    "Any design decision record or rationale explaining why this deployment model/tier/topology was chosen.",
                    "A current inventory of the instances, databases, pools and dependencies in scope.",
                },
                new[]
                {
                    "Read the document and write down what it claims: the deployment model, the instances and databases, and the components they depend on.",
                    "Compare each claim against the audited environment and note every difference.",
                    "Confirm the rationale is recorded - a diagram with no stated reasoning does not evidence a deliberate decision.",
                },
                $"A current document evidences {control} and matches the deployed environment.",
                $"No such document exists, it has no recorded rationale, or it no longer matches what is deployed.",
                "The item describes a platform construct that does not exist in this deployment (for example an Azure service tier on an on-premises instance).",
                "Produce or refresh the document, record the decision rationale, and put it under the same review cadence as the platform itself.");

        if (Has("runbook", "procedure", "escalation", "on-call", "on call", "onboarding", "glossary", "terminology", "self-documenting", "maintainable", "bus factor", "knowledge"))
            return new ArtefactGuidance(
                "Obtain the operational documentation for this platform and judge whether someone outside the build team could use it.",
                new[]
                {
                    "The runbook, operations manual or wiki space covering this platform.",
                    "Escalation and on-call definitions, including named roles or rotas.",
                    "Onboarding material, glossaries and any recorded handover notes.",
                },
                new[]
                {
                    "Locate the document this item names and read the section that would actually be used in the scenario it covers.",
                    "Judge whether the steps are executable by a competent engineer who did not build the system - concrete commands, paths and thresholds rather than intent.",
                    "Check when it was last reviewed and whether it still matches the current schema, jobs and endpoints.",
                    "Confirm the people named in it are current and that the team can reach the document without asking the original author.",
                },
                $"The documentation exists, is current, and is specific enough that {control} genuinely holds.",
                $"The documentation is missing, is a stub or template, is out of date, or depends on one person's knowledge.",
                "The activity this documentation would cover does not exist for this platform, so there is nothing to document.",
                "Write or update the document with concrete, executable detail, name its owner, and set a review cadence tied to schema and process changes.");

        if (Has("rto", "rpo", "disaster", "failover", "dr ", " dr", "restore", "retention", "backup", "freshness"))
            return new ArtefactGuidance(
                "Obtain the recovery and continuity documentation, plus the records of any test that exercised it.",
                new[]
                {
                    "The documented RTO/RPO targets and the DR runbook or continuity plan.",
                    "Records of the most recent failover or restore test: date, scope, outcome, and who ran it.",
                    "Retention and data-freshness commitments agreed with the business.",
                },
                new[]
                {
                    "Confirm the target or commitment this item names is written down and signed off, not assumed.",
                    "Find the evidence that it has been tested or measured - a test report, ticket, or monitoring record - and check the date.",
                    "Compare the documented target against the platform's actual configuration and note any gap.",
                },
                $"The target is documented, agreed, and there is dated evidence that {control} has been verified.",
                $"The target is undocumented or untested, or the last test is older than the stated cadence.",
                "The platform is explicitly out of scope for recovery commitments (for example a disposable sandbox with no restore obligation).",
                "Document and agree the target, schedule the test at the required cadence, and retain the test report as evidence.");

        if (Has("compliance", "regulat", "gdpr", "personal data", "residency", "agreement", "dpa", "breach", "consent", "segregation of duties", "retention polic", "cross-border"))
            return new ArtefactGuidance(
                "Obtain the compliance documentation that governs this platform and the records that evidence it is followed.",
                new[]
                {
                    "The compliance matrix, data inventory or register that covers this platform.",
                    "Signed agreements, policies or approvals relevant to the obligation (for example a DPA, a retention policy, an incident-notification process).",
                    "Evidence the obligation is operated: approvals, review records, or the control mapped to a system setting.",
                },
                new[]
                {
                    "Confirm the obligation this item names is identified and recorded against this platform specifically, not only at organisation level.",
                    "Read the controlling document and confirm it is approved and in force, with a date and an owner.",
                    "Look for evidence the obligation is operated in practice, not only stated on paper.",
                },
                $"The obligation is documented, approved and evidenced in operation for this platform, satisfying {control}.",
                $"The obligation is unidentified, undocumented, expired, or documented but demonstrably not operated.",
                "The regulated data category or regime this item concerns is not present in this platform - record the basis for that conclusion.",
                "Identify and document the obligation against this platform, secure the required approval, and record how it is evidenced on an ongoing basis.");

        if (Has("lineage", "catalog", "steward", "ownership", "metadata", "business definition", "source-to-target", "source to target", "mapping"))
            return new ArtefactGuidance(
                "Obtain the governance artefacts that describe what the data means, where it comes from and who owns it.",
                new[]
                {
                    "Source-to-target mappings or lineage documentation for the in-scope tables and loads.",
                    "The data catalog or glossary, and whether this platform's assets are registered in it.",
                    "The ownership/stewardship register naming who is accountable for each domain.",
                },
                new[]
                {
                    "Sample a few in-scope tables and confirm the artefact actually covers them, rather than covering the platform in the abstract.",
                    "Check the named owners or stewards are current people in current roles.",
                    "Confirm consumers can reach the artefact themselves - discoverability is part of the control.",
                },
                $"The artefact covers the in-scope assets, names current owners, and is reachable by its consumers, satisfying {control}.",
                $"The artefact is absent, covers only part of the estate, names people who have left, or is held privately by one team.",
                "The data domain this item governs is not present in this platform.",
                "Complete the artefact for the in-scope assets, assign current named owners, and publish it where consumers can find it.");

        if (Has("secret", "key vault", "connection string", "credential"))
            return new ArtefactGuidance(
                "Inspect where this platform's connection strings and credentials are actually held.",
                new[]
                {
                    "Application and ETL configuration files, pipeline variable definitions, and any IaC templates.",
                    "The secret store in use (for example Key Vault) and which of this platform's secrets it holds.",
                    "Repository secret-scanning results, if available.",
                },
                new[]
                {
                    "Search the repository and pipeline definitions for embedded passwords, connection strings and keys.",
                    "For each credential the platform needs, confirm it resolves from a secret store at runtime rather than from a checked-in file.",
                    "Confirm access to the secret store is itself restricted, and note anything still held in plain configuration.",
                },
                $"Credentials resolve from a managed secret store and no secret is present in code or configuration, satisfying {control}.",
                $"One or more credentials are held in configuration files, pipeline plain text, or committed source.",
                "The platform uses only integrated/managed identity authentication and holds no credentials to store.",
                "Move the exposed secrets into the secret store, rotate anything that was committed, and reference them from configuration at runtime.");

        if (Has("cost", "sizing", "reserved", "savings", "growth projection", "auto-scal", "scaled down", "serverless", "tier"))
            return new ArtefactGuidance(
                "Obtain the sizing and cost analysis that justifies how this platform is provisioned.",
                new[]
                {
                    "The workload analysis or sizing calculation behind the current tier/compute choice.",
                    "Cost reports, reservation or savings-plan evaluations, and any growth projection.",
                    "The policy or schedule governing non-production environments.",
                },
                new[]
                {
                    "Confirm the decision this item concerns is backed by recorded analysis rather than by a default or a guess.",
                    "Check the analysis is recent enough to still be valid against current usage.",
                    "Compare what the analysis recommends against how the platform is actually provisioned today.",
                },
                $"Recorded, current analysis evidences {control} and matches how the platform is provisioned.",
                $"No analysis exists, it is stale, or the provisioning no longer follows it.",
                "The platform runs on fixed infrastructure with no sizing or purchasing decision to make.",
                "Produce the analysis, act on its recommendation, and re-run it on a set cadence as the workload grows.");

        if (Has("data quality", " dq", "dq ", "remediation workflow", "sla"))
            return new ArtefactGuidance(
                "Obtain the data quality framework documentation and the records of it operating.",
                new[]
                {
                    "The data quality framework: the defined rules, their owners, and how quality is scored.",
                    "The remediation workflow - how an alert becomes an investigation, a fix and a verification.",
                    "Agreed data quality or freshness SLAs per data product or mart.",
                },
                new[]
                {
                    "Confirm the rules, ownership and scoring this item names are written down and agreed, not implicit in ETL code.",
                    "Trace one recent data quality issue end to end and confirm it followed the documented workflow.",
                    "Check the SLA is agreed with the consuming business area and is measured.",
                },
                $"The framework is documented, owned and demonstrably operated, satisfying {control}.",
                $"Quality rules live only inside code, no workflow is defined, or the documented process is not followed in practice.",
                "No data products or marts are served from this platform, so there is no quality commitment to define.",
                "Formalise the rules, owners, scoring and workflow in a single document, and measure against the agreed SLA.");

        if (Has("dashboard", "alert", "baseline", "monitor", "observab"))
            return new ArtefactGuidance(
                "Obtain the monitoring artefacts and confirm the people who need them can use them.",
                new[]
                {
                    "The dashboard or workbook covering this platform, and who has access to it.",
                    "The alert rule definitions and their thresholds.",
                    "Captured baselines and any documented escalation path for critical alerts.",
                },
                new[]
                {
                    "Open the dashboard as a non-DBA operations user would, and confirm it is reachable and legible to them.",
                    "Review the alert rules and thresholds, and check the recent alert volume for evidence of tuning or fatigue.",
                    "Confirm the escalation path names current roles and has been used at least once.",
                },
                $"The artefact exists, is accessible to its intended audience, and evidences {control}.",
                $"The artefact is missing, restricted to the team that built it, untuned, or has no defined escalation.",
                "This platform has no monitoring obligation defined for the audience the item names.",
                "Publish the dashboard to the operations audience, tune the thresholds against observed behaviour, and document the escalation path.");

        if (Has("test", "validation", "regression", "performance test"))
            return new ArtefactGuidance(
                "Obtain the test assets for this database and the record of them running.",
                new[]
                {
                    "Test projects, scripts or notebooks held alongside the database code.",
                    "The pipeline stage that executes them, and its recent run results.",
                    "Any documented acceptance criteria the tests assert against.",
                },
                new[]
                {
                    "Confirm the tests this item names exist as assets, not as a manual checklist someone works through.",
                    "Confirm they run automatically as part of the release, and check the last few results.",
                    "Read a sample and judge whether they would actually catch the failure the control is meant to prevent.",
                },
                $"Automated tests exist, run as part of the release, and meaningfully assert {control}.",
                $"No tests exist, they are run manually and inconsistently, or they pass without asserting anything meaningful.",
                "No schema or load changes are made to this platform, so there is no release to test.",
                "Add the missing tests to the repository, wire them into the release pipeline, and fail the release when they fail.");

        // Default: still item-specific because it references this item's own description and area.
        var areaHint = string.IsNullOrWhiteSpace(category)
            ? "the documentation set for this platform"
            : $"the documentation, records or repository assets covering '{category}'";
        return new ArtefactGuidance(
            $"Identify the document, record, repository asset or pipeline definition that would evidence {control}, and obtain it.",
            new[]
            {
                $"Locate {areaHint}.",
                "The owner of that artefact, and the date it was last reviewed.",
            },
            new[]
            {
                $"Read the artefact and find the specific statement, setting or section that evidences {control}.",
                "Confirm it describes the environment being audited, and that the people it names are current.",
            },
            $"A current, owned artefact evidences {control} for this platform.",
            $"No artefact evidences {control}, or the one that exists is stale, generic, or contradicted by the deployed environment.",
            $"The activity or construct {control} concerns does not exist in this platform, so there is nothing to evidence.",
            $"Produce the artefact that evidences {control}, assign it an owner, and review it on a set cadence.");
    }

    // Safety net for callers that cannot supply the mapping's IsDocumentationCheck flag.
    private static bool IsDocumentationTopic(ChecklistItem item)
    {
        var text = ((item.Description ?? string.Empty) + " " + (item.Category ?? string.Empty)).ToLowerInvariant();
        string[] markers =
        {
            "documented", "documentation", "document exists", "runbook", "diagram", "glossary",
            "source-controlled", "source control", "branching strategy", "pull request",
            "commit message", "pipeline", "onboarding", "escalation path", "steward",
            "agreement", "policies defined", "policy defined", "strategy defined",
        };
        return markers.Any(m => text.Contains(m));
    }

    private sealed record TopicGuidance(
        string Focus,
        string[] Steps,
        string ExampleSql,
        string PassHint,
        string FailHint,
        string Remediation);

    private static TopicGuidance ClassifyTopic(string description, string category)
    {
        var text = (description + " " + category).ToLowerInvariant();
        bool Has(params string[] keys) => keys.Any(k => text.Contains(k));
        var control = string.IsNullOrWhiteSpace(description) ? "this control" : $"\"{description}\"";

        if (Has("select *", "select star", "explicit column"))
            return new TopicGuidance(
                "Look for `SELECT *` in production stored procedures, views and functions; production code should list explicit columns (EXISTS(SELECT *) is acceptable).",
                new[]
                {
                    "Search module definitions for `SELECT *` across the in-scope databases (Programmability nodes, or the query below).",
                    "For each hit, confirm whether it returns a result set (a real violation) or is an acceptable EXISTS(SELECT *) predicate.",
                },
                @"SELECT OBJECT_SCHEMA_NAME(o.object_id) AS [schema], OBJECT_NAME(o.object_id) AS [object], o.type_desc
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
WHERE o.is_ms_shipped = 0 AND m.definition LIKE '%SELECT%*%'
ORDER BY [schema], [object];",
                "Production modules use explicit column lists; any `SELECT *` is limited to acceptable cases.",
                "One or more production modules use `SELECT *` to return data.",
                "Replace `SELECT *` with explicit column lists in the flagged modules.");

        if (Has("schema-qualif", "schema qualif", "dbo.", "two-part", "two part"))
            return new TopicGuidance(
                "Check that object references in code use two-part, schema-qualified names (e.g. dbo.Orders) rather than unqualified names (Orders).",
                new[]
                {
                    "Query sys.sql_expression_dependencies for references whose referenced_schema_name is NULL (unqualified).",
                    "Manually review modules that build dynamic SQL (EXEC / sp_executesql); those references are not in dependency metadata.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + '.' + QUOTENAME(OBJECT_NAME(d.referencing_id)) AS referencing_object,
       d.referenced_entity_name
FROM sys.sql_expression_dependencies d
WHERE d.referenced_id IS NOT NULL AND d.referenced_schema_name IS NULL
ORDER BY referencing_object;",
                "Production modules reference objects with schema-qualified names; no unqualified references remain.",
                "One or more references omit the schema (e.g. FROM Orders instead of FROM dbo.Orders).",
                "Update the flagged modules to use schema-qualified (two-part) object names.");

        if (Has("set nocount", "nocount", "set option"))
            return new TopicGuidance(
                "Verify that stored procedures start with SET NOCOUNT ON and use appropriate SET options (ANSI_NULLS, QUOTED_IDENTIFIER ON).",
                new[]
                {
                    "Query sys.sql_modules for procedures whose definition lacks SET NOCOUNT ON and check uses_ansi_nulls / uses_quoted_identifier.",
                    "Spot-check a few flagged procedures in Object Explorer to confirm the SET options are genuinely missing.",
                },
                @"SELECT QUOTENAME(SCHEMA_NAME(p.schema_id)) + '.' + QUOTENAME(p.name) AS procedure_name,
       m.uses_ansi_nulls, m.uses_quoted_identifier,
       CASE WHEN UPPER(m.definition) LIKE '%SET NOCOUNT ON%' THEN 1 ELSE 0 END AS has_set_nocount_on
FROM sys.procedures p
JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE p.is_ms_shipped = 0
ORDER BY procedure_name;",
                "In-scope procedures use SET NOCOUNT ON together with ANSI_NULLS and QUOTED_IDENTIFIER ON.",
                "One or more procedures omit SET NOCOUNT ON or a required SET option.",
                "Add SET NOCOUNT ON and the required SET options to the flagged procedures.");

        if (Has("deprecated", "ntext", "old-style join", "old style join", "image type"))
            return new TopicGuidance(
                "Look for deprecated features and syntax: TEXT/NTEXT/IMAGE data types, old-style outer joins (*= and =*), and other deprecated constructs.",
                new[]
                {
                    "Scan module definitions for old-style joins and deprecated type usage.",
                    "Check column data types via sys.columns / sys.types for TEXT, NTEXT and IMAGE.",
                },
                @"SELECT OBJECT_SCHEMA_NAME(object_id) AS [schema], OBJECT_NAME(object_id) AS [object]
FROM sys.sql_modules
WHERE definition LIKE '%*=%' OR definition LIKE '%=*%'
   OR definition LIKE '% TEXT%' OR definition LIKE '%NTEXT%' OR definition LIKE '% IMAGE%'
ORDER BY [schema], [object];",
                "No deprecated types or syntax remain in production code or column definitions.",
                "Deprecated types (TEXT/NTEXT/IMAGE) or old-style joins are present.",
                "Migrate deprecated types to VARCHAR(MAX)/NVARCHAR(MAX)/VARBINARY(MAX) and modernise the join syntax.");

        if (Has("naming", "formatting"))
            return new TopicGuidance(
                "Review object and column names for consistency with the documented naming/formatting convention across schemas, tables, procedures and columns.",
                new[]
                {
                    "List objects and columns and compare their names against the agreed convention.",
                    "Note any objects that deviate (casing, prefixes, abbreviations) as evidence.",
                },
                @"SELECT o.type_desc, QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name) AS object_name
FROM sys.objects o
WHERE o.is_ms_shipped = 0
ORDER BY o.type_desc, object_name;",
                "Object and column names follow the documented convention consistently.",
                "Multiple objects deviate from the naming/formatting standard.",
                "Rename or refactor the non-conforming objects to match the documented convention.");

        if (Has("comment", "commented", "business rule"))
            return new TopicGuidance(
                "Confirm that complex modules contain explanatory comments and that business rules are documented in or alongside the code.",
                new[]
                {
                    "Open the longest / most complex modules and confirm meaningful comments explain the logic.",
                    "Check that business rules are captured in comments or linked documentation.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + '.' + QUOTENAME(OBJECT_NAME(object_id)) AS module,
       LEN(definition) AS definition_length
FROM sys.sql_modules
ORDER BY definition_length DESC;",
                "Complex modules are commented and business rules are documented.",
                "Complex logic lacks comments or documented business rules.",
                "Add explanatory comments to the flagged modules and document the relevant business rules.");

        if (Has("index", "fragmentation"))
            return new TopicGuidance(
                "Inspect indexing: appropriate indexes exist, fragmentation is controlled, and there are no obviously unused or duplicate indexes.",
                new[]
                {
                    "Review indexes on the key tables and check fragmentation for the larger indexes.",
                    "Look for missing-index suggestions and unused indexes via the relevant DMVs.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + '.' + QUOTENAME(OBJECT_NAME(i.object_id)) AS [table],
       i.name AS index_name, i.type_desc
FROM sys.indexes i
WHERE i.object_id > 100 AND i.type_desc <> 'HEAP'
ORDER BY [table], index_name;",
                "Indexing is appropriate, maintained, and free of significant fragmentation or redundant indexes.",
                "Key tables lack appropriate indexes, or fragmentation/duplicate indexes are unmanaged.",
                "Add, rebuild, or remove indexes as indicated and schedule regular index maintenance.");

        if (Has("deadlock"))
            return new TopicGuidance(
                "Confirm deadlocks are being captured (system_health Extended Events session or a dedicated XE session) and are reviewed/resolved.",
                new[]
                {
                    "Verify the system_health Extended Events session is running.",
                    "Query recent deadlock reports and confirm they are triaged.",
                },
                @"SELECT XEvent.value('(@timestamp)[1]', 'datetime2') AS deadlock_time
FROM (
    SELECT CAST(target_data AS XML) AS TargetData
    FROM sys.dm_xe_session_targets st
    JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
    WHERE s.name = 'system_health' AND st.target_name = 'ring_buffer'
) AS Data
CROSS APPLY TargetData.nodes('//RingBufferTarget/event[@name=""xml_deadlock_report""]') AS X(XEvent);",
                "Deadlocks are captured and there is evidence they are reviewed and resolved.",
                "Deadlock capture is not configured, or captured deadlocks are not acted upon.",
                "Enable deadlock capture (Extended Events) and establish a triage process for reported deadlocks.");

        if (Has("query store"))
            return new TopicGuidance(
                "Check that Query Store is enabled and appropriately configured on the in-scope databases.",
                new[]
                {
                    "Review Query Store options (state, capture mode, retention) for each database.",
                    "Confirm the actual state is READ_WRITE where the standard expects it.",
                },
                @"SELECT actual_state_desc, query_capture_mode_desc, max_storage_size_mb, stale_query_threshold_days
FROM sys.database_query_store_options;",
                "Query Store is ON (READ_WRITE) and configured per the standard.",
                "Query Store is OFF, unexpectedly READ_ONLY, or misconfigured.",
                "Enable and configure Query Store (capture mode, retention, storage) per the standard.");

        if (Has("backup", "retention", "restore", "recovery"))
            return new TopicGuidance(
                "Verify backups exist, run on the expected schedule, and that retention meets policy for the in-scope databases.",
                new[]
                {
                    "Review recent backup history for full/diff/log backups per database.",
                    "Confirm the most recent successful backups are within the required RPO and retention window.",
                },
                @"SELECT bs.database_name, bs.type, MAX(bs.backup_finish_date) AS last_backup
FROM msdb.dbo.backupset bs
GROUP BY bs.database_name, bs.type
ORDER BY bs.database_name, bs.type;",
                "Backups run on schedule and retention meets the documented policy.",
                "Backups are missing, stale, or retention is shorter than policy.",
                "Fix or schedule the required backups and align retention with policy.");

        if (Has("job", "agent", "scheduler", "etl"))
            return new TopicGuidance(
                "Inspect SQL Server Agent jobs: they exist, are owned appropriately, are scheduled, and their failures are captured/alerted.",
                new[]
                {
                    "Review the relevant Agent jobs, their owners and schedules.",
                    "Check recent job outcomes and confirm failures raise alerts to the responsible team.",
                },
                @"SELECT j.name AS job_name, SUSER_SNAME(j.owner_sid) AS owner, j.enabled
FROM msdb.dbo.sysjobs j
ORDER BY j.name;",
                "Relevant jobs exist, are owned, scheduled, and failures are alerted.",
                "Jobs are missing, unowned, disabled, or failures go unnoticed.",
                "Create/own/schedule the required jobs and configure failure notifications.");

        if (Has("permission", "role", "login", "privilege", "access control", "least privilege"))
            return new TopicGuidance(
                "Review logins, database users, role memberships and granted permissions to confirm least-privilege access.",
                new[]
                {
                    "Enumerate server logins and their fixed-server-role memberships (especially sysadmin).",
                    "Review database role memberships and explicit permission grants for over-privilege.",
                },
                @"SELECT sp.name AS principal, sp.type_desc, sp.is_disabled
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G') AND sp.name NOT LIKE '##%'
ORDER BY sp.type_desc, principal;",
                "Access follows least privilege; elevated roles are justified and documented.",
                "Excessive privileges (e.g. broad sysadmin/db_owner) exist without justification.",
                "Remove or reduce unjustified privileges and document any required elevated access.");

        if (Has("encrypt", "tde", "at rest", "always encrypted"))
            return new TopicGuidance(
                "Confirm encryption (TDE, column encryption, or Always Encrypted) is enabled where the standard requires it.",
                new[]
                {
                    "Check database encryption state for TDE across the in-scope databases.",
                    "Where column-level protection is required, confirm the relevant columns are encrypted.",
                },
                @"SELECT DB_NAME(database_id) AS [database], encryption_state, encryption_state_desc
FROM sys.dm_database_encryption_keys;",
                "Encryption is enabled and configured where required by the standard.",
                "Required encryption (TDE/column) is missing or disabled.",
                "Enable the required encryption and manage the associated keys per policy.");

        if (Has("mask", "subsetting", "sensitive", "non-prod", "non prod"))
            return new TopicGuidance(
                "Confirm sensitive data is masked and/or subset in non-production environments.",
                new[]
                {
                    "Identify columns holding sensitive data and confirm masking/subsetting is applied in non-prod.",
                    "Check for Dynamic Data Masking definitions where used.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(mc.object_id)) + '.' + QUOTENAME(OBJECT_NAME(mc.object_id)) AS [table],
       c.name AS column_name, mc.masking_function
FROM sys.masked_columns mc
JOIN sys.columns c ON c.object_id = mc.object_id AND c.column_id = mc.column_id
ORDER BY [table], column_name;",
                "Sensitive data is masked or subset in non-production as required.",
                "Sensitive data is exposed unmasked in non-production.",
                "Apply masking/subsetting to the sensitive columns used in non-production.");

        // Default: still item-specific because it references this item's own description/category.
        var areaHint = string.IsNullOrWhiteSpace(category)
            ? "the relevant system catalog views / DMVs or Object Explorer node for this control"
            : $"the objects and settings related to '{category}' (via Object Explorer or the relevant catalog views / DMVs)";
        return new TopicGuidance(
            $"Identify the specific object, setting, job or process implied by {control} and inspect its current configuration on the instance.",
            new[]
            {
                $"Locate {areaHint}.",
                $"Capture the current configuration or definition that evidences whether {control} is met.",
            },
            string.Empty,
            $"{control} is implemented and configured as your organisation's standard requires.",
            $"{control} is missing, disabled, or configured differently from the standard.",
            $"Implement or correct {control} per your organisation's standard and capture documented evidence.");
    }
}
