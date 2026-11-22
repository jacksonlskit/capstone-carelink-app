# Create-Capstone-CareLink-App

CareLink Health (capstone Use Case B): Spring PetClinic Cloud (api-gateway, customers, vets and visits services) on Amazon EKS. Infrastructure, including Argo CD itself, lives in the `capstone-carelink-infra` repo.

## Delivery pipeline

```
feature/* ──PR──▶ main ──cd.yaml──▶ env/staging ──Argo CD──▶ staging cluster
   │                │                    │
   CI gates         review               └─ approval ─▶ env/production ──Argo CD──▶ production cluster
```

1. **Feature branch → pull request.** `ci.yaml` runs on every PR to `main`: Maven build and tests, Trivy dependency scan (fails on HIGH/CRITICAL), container build and Trivy image scan (fails on CRITICAL), and a Helm chart lint/render for staging and production. The `build` job aggregates these and is the required status check; `main` also needs one approving review and accepts no direct pushes.
2. **Merge → staging.** `cd.yaml` builds the four images, scans each one with Trivy (fails on CRITICAL, as in CI), pushes only scanned images to the staging ECR repositories tagged with the commit SHA (tags are immutable), and runs `scripts/promote.sh staging <sha>`. That commits the chart plus the image tag to the branch `env/staging`. Argo CD in the staging cluster syncs it, and `scripts/wait-for-argocd.sh` waits until Argo CD reports the app *Synced* and *Healthy*; otherwise the job fails.
3. **Approval → production.** The `production` job uses the GitHub environment `production`, which requires the DevOps owner's approval and accepts runs from `main` only. After approval it copies the exact images that passed staging into the production ECR repositories (nothing is rebuilt), records the deployment on `env/production` with the production deploy key (see below), and waits for Argo CD in the production cluster.

Each environment uses its own IAM role through GitHub OIDC (`vars.AWS_ROLE_ARN` per GitHub environment); there are no stored AWS keys.

### When a security gate fails
The PR's `build` check turns red, so the PR cannot be merged. Fix the finding (upgrade the dependency or base image) and push again. Only accept a finding in `.trivyignore` with a comment explaining why and an expiry, reviewed in the PR.

### Where things are
| What | Where |
|---|---|
| Helm chart (what runs in the cluster) | `charts/carelink` (`values.yaml` + `values-<env>.yaml`) |
| What is deployed right now | branch `env/staging`, `env/production`: one commit per deployment |
| Deployment history | `git log origin/env/production` |
| Argo CD Applications | `carelink-staging`, `carelink-production` (namespace `argocd`, created by Terraform in the infra repo) |

`env/*` branches are written only by the pipeline. Change the app through a PR to `main`.
- **`env/production` is locked by GitHub.** The ruleset `app-env-production-lock` (infra repo, `oicd-bootstrap/main.tf`) refuses every push except one made with the production deploy key. Its private half exists only as the `production` environment secret `ENV_PRODUCTION_DEPLOY_KEY`, which GitHub gives only to the production job, after approval, for runs from `main`. A direct push, even by a repository admin, is refused with `GH013`.
- **`env/staging` is not locked** (staging has no approval step to protect); there, it is a team rule.

### Rollback
Argo CD's `selfHeal` undoes manual `kubectl` changes, so Git is the only way to change what runs. Two ways, both through the pipeline:
- **Revert the bad commit on `main` through a PR.** Always works: the merge deploys the reverted code to staging, then to production after approval.
- **Faster: re-run the CD run of the last good commit** (Actions → CD → that run → Re-run all jobs). A re-run uses that commit's code *and its own `cd.yaml`*, so this only works for runs of `b08dc0f` (22 Nov 2026) or later; older runs push `env/production` with `GITHUB_TOKEN`, which the ruleset refuses. GitHub allows re-runs for 30 days.

Actions → CD → **Run workflow** is not a rollback: it deploys the current head of `main` again.

### Argo CD UI
Not exposed publicly. With cluster access:
```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
Then open https://localhost:8443 (user `admin`).
