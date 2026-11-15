# Create-Capstone-CareLink-App

CareLink Health (capstone Use Case B): Spring PetClinic Cloud (api-gateway, customers, vets and visits services) on Amazon EKS. Infrastructure, including Argo CD itself, lives in the `capstone-carelink-infra` repo.

## Delivery pipeline

```
feature/* ──PR──▶ main ──cd.yaml──▶ env/staging ──Argo CD──▶ staging cluster
   │                │                    │
   CI gates         review               └─ approval ─▶ env/production ──Argo CD──▶ production cluster
```

1. **Feature branch → pull request.** `ci.yaml` runs on every PR to `main`: Maven build and tests, Trivy dependency scan (fails on HIGH/CRITICAL), container build and Trivy image scan (fails on CRITICAL), and a Helm chart lint/render for staging and production. The `build` job aggregates these and is the required status check; `main` also needs one approving review and accepts no direct pushes.
2. **Merge → staging.** `cd.yaml` builds the four images, pushes them to the staging ECR repositories tagged with the commit SHA (tags are immutable), and runs `scripts/promote.sh staging <sha>`. That commits the chart plus the image tag to the branch `env/staging`. Argo CD in the staging cluster syncs it, and `scripts/wait-for-argocd.sh` waits until Argo CD reports the app *Synced* and *Healthy*; otherwise the job fails.
3. **Approval → production.** The `production` job uses the GitHub environment `production`, which requires a reviewer. After approval it copies the exact images that passed staging into the production ECR repositories (nothing is rebuilt), records the deployment on `env/production`, and waits for Argo CD in the production cluster.

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

### Rollback
Re-run the `cd.yaml` workflow for the last good commit of `main` (Actions → CD → Run workflow), or revert the bad commit on `main` through a PR. Argo CD's `selfHeal` undoes manual `kubectl` changes, so Git is the only way to change what runs.

### Argo CD UI
Not exposed publicly. With cluster access:
```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
Then open https://localhost:8443 (user `admin`).
