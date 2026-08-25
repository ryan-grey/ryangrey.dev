# ryangrey.dev

My personal site. One HTML file, no build step, no dependencies, no JavaScript, and no external requests — served from a private S3 bucket behind CloudFront.

**Live:** <https://ryangrey.dev>

The site is its own case study: the architecture section on the page describes the infrastructure that serves the page.

## Constraints

I set these up front and held to them:

| Constraint | Result |
| --- | --- |
| No build tooling | Edit `index.html`, sync, done. Nothing to install, nothing to break in two years. |
| No frameworks | 0 dependencies. No `node_modules`, no lockfile, no supply chain. |
| No external requests | No CDN, no analytics, no web fonts, no trackers. Nothing loads from a third party. |
| No JavaScript | 0 `<script>` tags. Dark/light theming is pure CSS via `prefers-color-scheme`. |
| System font stack | Zero font payload; renders natively on every platform. |

Total page weight, everything included:

| Asset | Size |
| --- | --- |
| `index.html` (markup + inline CSS + inline SVG) | 14.3 KB |
| Profile photo (JPEG, EXIF stripped) | 29.9 KB |
| AWS certification badge (PNG) | 44.9 KB |
| **Total** | **~87 KB** |

## Architecture

```mermaid
flowchart LR
    U["Browser"] --> R53["Route 53<br/><small>DNS · ryangrey.dev</small>"]
    R53 --> CF["CloudFront<br/><small>CDN · ACM TLS</small>"]
    CF --> S3["S3<br/><small>private origin</small>"]

    style U fill:#eef2f7,stroke:#7a8494,color:#1c1e21
    style R53 fill:#eef2f7,stroke:#7a8494,color:#1c1e21
    style CF fill:#eef2f7,stroke:#7a8494,color:#1c1e21
    style S3 fill:#eef2f7,stroke:#7a8494,color:#1c1e21
```

- **S3** holds the static files. The bucket is **private** — it is not a website-endpoint bucket and has no public read policy.
- **CloudFront** is the only thing allowed to read it, via **Origin Access Control (OAC)**. Requests to the bucket that do not come from the distribution are denied.
- **ACM** provides the TLS certificate (free, auto-renewing), attached to the distribution.
- **Route 53** holds the hosted zone, with an A-record alias pointing the apex domain at CloudFront.
- **`.dev` is on the HSTS preload list**, so every connection is HTTPS by force — browsers refuse plaintext to the TLD before a request is ever made.

## The interesting part: a DNSSEC teardown mid-migration

The domain started at GoDaddy and moved to Route 53. A straight nameserver cutover would have broken resolution, because the domain had **DNSSEC enabled** at the old registrar.

DNSSEC works by chaining trust: the `.dev` registry holds a **DS record** that fingerprints the signing key at the authoritative nameservers. Point the domain at new nameservers that don't have the matching key, and every validating resolver doesn't just fail — it fails *closed*. The domain goes dark, and it stays dark for as long as the stale DS record is cached, which you do not control.

So the order mattered:

1. **Delete the DS records at the `.dev` registry first**, breaking the chain of trust deliberately and while the old nameservers still answered correctly.
2. **Wait for the DS TTL to expire**, so no validating resolver still believed the domain was signed.
3. **Only then cut the nameservers over** to Route 53.

Resolution never broke. The failure mode being avoided here is a genuinely nasty one: it's invisible from any resolver that isn't validating, so it can look fine from your own machine while being completely unreachable for a large share of real users.

## Deploy

```bash
aws s3 sync . s3://<bucket> \
  --exclude ".DS_Store" --exclude "CLAUDE.md" --exclude ".claude/*"

aws cloudfront create-invalidation --distribution-id <distribution-id> \
  --paths "/index.html"
```

Notes:

- Invalidation propagates in roughly 1–2 minutes.
- CloudFront's free tier covers 1,000 invalidation paths per month, so specific paths beat `"/*"` — a wildcard is one path against quota but throws away the whole cache.
- The excludes matter. Without them the sync happily uploads local tooling config into a public bucket.

## Certification

The AWS Certified Cloud Practitioner badge on the site links to [its Credly verification page](https://www.credly.com/badges/805d358d-416b-4def-8691-c0c92fa5f1d6/public_url). Credly's official embed is a `<script>` from their CDN, which would have broken the no-external-requests rule — so the badge art is self-hosted and simply hyperlinked to the verification URL. Same result, independently verifiable, zero third-party calls.

## CI/CD: keyless deploys

Pushing to `main` deploys the site. There are **no AWS access keys stored anywhere** — not in GitHub secrets, not in the repo, not on a laptop.

Instead, GitHub Actions and AWS establish trust directly via **OpenID Connect**:

```mermaid
sequenceDiagram
    participant GA as GitHub Actions
    participant GH as GitHub OIDC issuer
    participant STS as AWS STS
    participant AWS as S3 + CloudFront

    GA->>GH: request token for this run
    GH-->>GA: signed JWT (repo, branch, sha)
    GA->>STS: AssumeRoleWithWebIdentity(JWT)
    STS->>GH: fetch public keys, verify signature
    STS->>STS: check claims against role trust policy
    STS-->>GA: temporary credentials (expire with the job)
    GA->>AWS: sync + invalidate
```

The job proves its identity with a short-lived signed token describing *which repo, which branch, which commit* is running. AWS verifies that signature against GitHub's published keys, checks the claims against the role's trust policy, and hands back credentials that expire when the job does. Nothing long-lived exists to leak, and there is no key to rotate.

### The trust policy is the whole security boundary

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:ryan-grey@146499233/ryangrey.dev@1345403610:ref:refs/heads/main"
  }
}
```

`StringEquals` on `sub` pins role assumption to exactly one repository and one branch. This is the part worth getting right: the OIDC provider trusts *GitHub*, not *you* — so a trust policy that omits the `sub` condition, or uses `StringLike` with a wildcard, is assumable by **any repository on GitHub**, including one an attacker creates. The condition is what turns "GitHub can assume this role" into "this repo on this branch can assume this role."

The role's permissions are scoped to match: write objects to one bucket, create an invalidation on one distribution. Nothing else.

### Two subtleties worth knowing

**The subject claim carries database IDs.** Every tutorial shows the subject as `repo:OWNER/REPO:ref:refs/heads/main`. The token this repo actually receives says:

```
repo:ryan-grey@146499233/ryangrey.dev@1345403610:ref:refs/heads/main
```

The numeric owner and repository IDs are appended. This is a hardening measure: names are recyclable — delete a repository and the name becomes available to anyone — so binding trust to immutable IDs means the grant follows the actual repository rather than a string someone else could later register. A trust policy written from the documented format fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, which names the action rather than the claim that didn't match, so it reads like a missing permission instead of a string mismatch. `infra/setup-oidc.sh` resolves both IDs from the GitHub API rather than assuming a format.

The reliable way to find out what your own tokens carry is to ask the runner: request the token, base64-decode the JWT payload, and print the claims. Guessing costs a round trip per attempt.

**An `environment:` block changes the subject too.**

| Job configuration | `sub` claim in the issued token |
| --- | --- |
| plain push to `main` | `repo:OWNER/REPO:ref:refs/heads/main` |
| job with `environment: production` | `repo:OWNER/REPO:environment:production` |
| pull request | `repo:OWNER/REPO:pull_request` |
| tag push | `repo:OWNER/REPO:ref:refs/tags/v1.0.0` |

Adding an `environment:` block to the job — even purely for the deployment URL annotation — silently changes the claim and the role assumption starts failing with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. The error names the action, not the claim that failed to match, which makes it easy to misread as a missing permission rather than a condition mismatch.

This workflow therefore has no `environment:` block, and the trust policy stays pinned to a single exact subject rather than being widened to accommodate one.

### Setup

One-time, with IAM admin credentials:

```bash
DISTRIBUTION_ID=<your-distribution-id> ./infra/setup-oidc.sh
```

The script is idempotent and creates the OIDC provider, the role, and its policy. It derives the account ID at runtime, so no account identifiers are committed here. It prints the role ARN, which goes into the repo's secrets along with the distribution ID.

### The workflow

`.github/workflows/deploy.yml` runs on every push to `main`:

1. Assume the role via OIDC
2. `aws s3 sync --delete` the site files (excluding `README.md`, `infra/`, `.github/`, and tooling config)
3. Create a CloudFront invalidation and **wait** for it to complete
4. Fetch the live page and assert it byte-matches the committed `index.html`

Step 4 matters: it means a green check reflects verified-live content, not just a successful upload. A `concurrency` group prevents two deploys racing onto the same bucket.

## Security headers

Every response carries a full set of security headers, added by a CloudFront **viewer-response function**:

| Header | Value |
| --- | --- |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` |
| `Content-Security-Policy` | `default-src 'none'; script-src 'none'; …` (below) |
| `X-Frame-Options` | `DENY` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | camera, geolocation, microphone, payment, USB… all denied |

### Why a function instead of a response headers policy

The obvious mechanism is a CloudFront **response headers policy**, and that is what this started as. It fails:

```
InvalidArgument: Distributions with the Free pricing plan can't have the
following features: Custom response headers policy
```

Worth reading carefully — that is `InvalidArgument`, not `AccessDenied`. The IAM user had every permission required and created the policy without complaint; the *pricing plan* refused the attachment. A viewer-response function is permitted on the Free plan and sets the same headers, so the workaround costs nothing and needs no plan upgrade.

### The CSP

```
default-src 'none'; script-src 'none'; style-src 'unsafe-inline';
img-src 'self' data:; font-src 'none'; connect-src 'none';
object-src 'none'; base-uri 'none'; form-action 'none';
frame-ancestors 'none'; upgrade-insecure-requests
```

`script-src 'none'` is the one that matters, and it is only available because the site genuinely has **zero `<script>` tags**. That single directive removes the whole XSS class rather than mitigating it — a property of the no-JavaScript constraint, not of the header.

Two judgement calls are worth stating outright:

- **`img-src` must include `data:`.** The favicon is an inline `data:image/svg+xml` URI. Omit `data:` and the tab icon silently disappears while every other check still passes.
- **`style-src 'unsafe-inline'` is a deliberate compromise.** The CSS is one inline `<style>` block; the strict alternative is a `sha256-` hash of its exact contents, which goes stale on *every* CSS edit and fails silently to an unstyled page. With no JavaScript on the page, there is nothing to weaponise CSS injection against, so the hash buys very little for real operational risk.

`X-XSS-Protection` is deliberately **not** set — it is deprecated, and with a real CSP present it can introduce vulnerabilities rather than prevent them.

### Deploying header changes

```bash
DISTRIBUTION_ID=<your-distribution-id> ./infra/deploy-security-headers.sh
```

Idempotent. It updates the function, runs `test-function` against a sample event and prints the resulting headers **before** publishing, then associates it with the distribution if it isn't already. The pre-publish test matters: a broken CSP fails silently — the headers still look perfect in `curl` while images vanish and the page renders unstyled. Verify in a browser, not just with `curl -I`.

## Alert delivery: SNS → Lambda → SES

CloudWatch alarms publish to SNS, but SNS's built-in email uses shared sending infrastructure — and mail from it was **never delivered** to the target Gmail address. Four subscribe attempts across CLI and console, zero arrivals, while other AWS senders (`costalerts@`, `no-reply@amazonaws.com`) reached the same inbox fine. A different provider received it on the first try, which isolated the problem to that sender/recipient pair.

SNS offers no delivery diagnostics for the `email` protocol — unlike SMS and HTTP/S, there are no delivery status logs to enable — so there was nothing to debug. The fix is to stop using it:

```mermaid
flowchart LR
    CW["CloudWatch<br/><small>alarm</small>"] --> SNS["SNS topic"]
    SNS --> L["Lambda<br/><small>formats payload</small>"]
    L --> SES["SES<br/><small>alerts@ryangrey.dev</small>"]
    SES --> IN["Inbox"]
```

Mail now originates from a domain identity we control, **DKIM-signed**, so it authenticates properly instead of arriving from shared infrastructure with no relationship to the sender.

### Domain authentication

`infra/setup-ses-alerts.sh` provisions the SES identity and writes five records into Route 53:

| Record | Purpose |
| --- | --- |
| 3 × `<token>._domainkey` CNAME | Easy DKIM — SES publishes the public keys, signs outbound mail with the private half |
| `TXT` at apex | SPF: `v=spf1 include:amazonses.com ~all` |
| `TXT` at `_dmarc` | DMARC: `v=DMARC1; p=none;` |

DKIM is what does the real work. SPF authorises the *envelope* sender, which for SES is an `amazonses.com` domain and therefore not aligned with `ryangrey.dev` — DKIM signs as `d=ryangrey.dev`, so DMARC passes on DKIM alignment. Publishing SPF anyway costs nothing and helps receivers that weight it.

### The SES sandbox

New accounts are sandboxed: SES will only send to **verified** addresses. So the recipient has to be verified too, which the script does — that triggers a verification email that must be clicked once. Production access (arbitrary recipients) requires a support request, unnecessary for alerting a fixed address.

### Least privilege

The Lambda's role can call `ses:SendEmail` on exactly one identity ARN, plus CloudWatch Logs. It cannot send as any other identity, and it holds no other permissions.

### Deploy

```bash
curl -fsSL -o setup-ses-alerts.sh https://raw.githubusercontent.com/ryan-grey/ryangrey.dev/main/infra/setup-ses-alerts.sh
bash setup-ses-alerts.sh
```

Idempotent. Creates the SES identity, DNS records, IAM role, Lambda, and SNS subscription; re-running updates the function in place.

## Testing the alert path

Alerts reach the inbox through a Lambda. If that function breaks — a bad IAM scope, an SES change, a code error — the alarm still fires and SNS still publishes while **nothing arrives**. Every console screen reads healthy. That failure mode is not hypothetical: during the initial build the Lambda failed three consecutive invocations on an IAM scoping error while the topic and alarm both showed green.

So the pipeline tests itself monthly:

```mermaid
flowchart LR
    S["EventBridge Scheduler<br/><small>1st of month, 14:00 UTC</small>"] --> A["SetAlarmState<br/><small>ALARM</small>"]
    A --> SNS["SNS"] --> L["Lambda"] --> SES["SES"] --> IN["Inbox"]
    A -.->|"~5 min, real datapoints"| OK["back to OK"]
```

EventBridge Scheduler calls `cloudwatch:SetAlarmState` directly via a **universal target** — no Lambda in the test path, so the thing doing the testing shares no failure modes with the thing being tested. The alarm self-recovers on its next evaluation against real metric data, leaving no lasting state.

The scheduler's role can call `SetAlarmState` on exactly one alarm ARN and nothing else.

### Why not a GitHub Actions cron

The repo already has keyless OIDC access to this account, so a scheduled workflow would have been less setup. **GitHub disables scheduled workflows in repositories with no commits for 60 days.** A personal site can easily go that long between changes, and the test would stop running silently — reproducing precisely the failure it exists to catch. A monitoring check that can quietly switch itself off is worse than none, because it manufactures false confidence.

### Setup

```bash
curl -fsSL -o setup-alert-pipeline-test.sh https://raw.githubusercontent.com/ryan-grey/ryangrey.dev/main/infra/setup-alert-pipeline-test.sh
bash setup-alert-pipeline-test.sh
```

The monthly email is a heartbeat: its arrival confirms the chain works. Its **absence** is the signal — worth knowing, since a missing email is easier to overlook than an arriving one.

## Contents

```
index.html                          the entire site — markup, CSS, and SVG diagram
ryan-grey.jpg                       profile photo (EXIF stripped)
aws-cloud-practitioner-badge.png    self-hosted Credly badge art
ryan-grey-cv.pdf                    CV linked from the page
.github/workflows/deploy.yml        keyless CI/CD pipeline
infra/setup-oidc.sh                 one-time IAM OIDC provider + role setup
infra/cloudfront-security-headers.js   viewer-response function: security headers
infra/deploy-security-headers.sh    deploys/updates that function
infra/ses_alert_lambda.py           SNS -> SES alert forwarder (Lambda)
infra/setup-ses-alerts.sh           provisions SES identity, DKIM, Lambda, subscription
infra/setup-alert-pipeline-test.sh  monthly self-test of the alert delivery path
```
