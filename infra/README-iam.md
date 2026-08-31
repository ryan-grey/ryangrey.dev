# IAM for infra work

Companion to `../../cloud-watchtower/infra/README-iam.md`, which established this
pattern. Same idea, different job: Watchtower assumes a **read-only** role so a
menu-bar app holds no write access; this assumes an **infra** role so deploys
stop going through CloudShell.

Unlike the Watchtower files, these carry the real account id (<AWS_ACCOUNT_ID>) and
user (`ryan-cli`) rather than placeholders. Neither is a secret — the account id
is already in `~/.aws/config` and in every `infra/` script in the greyscale
repo — and hardcoding them is what makes the block below one paste with nothing
to substitute.

## Why this exists

`ryan-cli` has no IAM write, deliberately, so every role or policy change meant
opening CloudShell as admin, uploading a script, and pasting. That is the thing
being retired.

The fix is **not** to widen `ryan-cli`. It keeps exactly the permissions it has.
Instead `ryangrey-infra` is a role it can assume: no new long-lived key on disk,
1-hour STS credentials, and revoking it is deleting the role.

## The three files

| File | What it is |
|---|---|
| `ryangrey-infra-trust.json` | Who may assume the role — `ryan-cli`, nobody else |
| `ryangrey-infra-policy.json` | What the role may do |
| `ryangrey-app-boundary.json` | The ceiling on any role the role itself creates |

## How the IAM statements are closed

This is the part worth reading twice, because an infra role that can write IAM
is an admin role wearing a hat.

1. **`CreateAppRolesOnlyUnderPathAndOnlyWithTheBoundary`** — `iam:CreateRole` is
   allowed only for ARNs under `role/ryangrey-app/`, and only when the request
   sets `PermissionsBoundary` to `ryangrey-app-boundary`. A role created without
   the boundary is not created at all.
2. **`ManageAppRolesOnlyUnderPath`** — attaching and writing role policies is
   scoped to that same path. The infra role therefore cannot edit *itself*
   (it lives at path `/`), and cannot touch `ryangrey-dev-ops`.
3. **`PassRoleToLambdaOnly`** — identical to the statement already in
   `ryangrey-dev-ops`: `iam:PassRole` is conditioned on
   `iam:PassedToService = lambda.amazonaws.com`, so a role cannot be handed to
   EC2 or to anything else that would run code under it.
4. **`DenyIamEscalationOutright`** — an explicit Deny, which beats any Allow,
   covering users, groups, access keys, login profiles, customer-managed policy
   versions, SAML/OIDC providers, and **both boundary actions**. That last pair
   is what stops the obvious move: create a boundary-capped role, then remove
   its boundary.

The boundary itself allows the runtime services a Lambda needs and then denies
`iam:*` and `sts:AssumeRole` outright, so nothing the infra role creates can
escalate even if its own policy is generous.

## Create it (CloudShell, as admin — `ryan-cli` has no IAM write, by design)

This is the last CloudShell paste. See the block in the chat, or reproduce it
with the three files here and `file://` arguments.

## Then add to `~/.aws/config`

```ini
[profile infra]
role_arn = arn:aws:iam::<AWS_ACCOUNT_ID>:role/ryangrey-infra
source_profile = default
region = us-east-1
```

Verify:

```sh
aws --profile infra sts get-caller-identity
```

The ARN must read `arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/ryangrey-infra/...`.
If it still reads `user/ryan-cli`, the profile was not picked up and every
command after it is running as the unprivileged user.

## Known gaps, stated rather than discovered

**Deliberately outside the stated service list.** `sqs:*` is in the policy even
though it was not on the list, because greyscale's photo pipeline runs on a
queue and a DLQ — the `SqsBeyondTheStatedList` sid names itself so it is easy to
delete if the list should stay exact.

**Not included, and likely to be the first thing that denies:**

| Service | Why you will hit it | One-line fix |
|---|---|---|
| ACM | CloudFront distributions need a certificate | add `"acm:*"` to a new statement |
| SNS | `ryangrey-dev-ops` has `sns:*`; the SES alert pipeline uses it | add `"sns:*"` |
| CloudFormation | only if you start using stacks | add `"cloudformation:*"` |

**Existing roles are outside the guard.** `greyscale-role` and
`greyscale-analyzer-role` were created at path `/`, not `/ryangrey-app/`, so the
infra role cannot change their inline policies — `07-calorie-permissions.sh` and
anything like it still needs admin. That is the cost of the path restriction,
not an oversight. A role's path cannot be changed after creation. The way to
bring them under management is to attach `ryangrey-app-boundary` to them, which
should be done only after checking the boundary covers what they currently do —
attaching a boundary that is missing an action breaks a live app the same way a
missing grant does.

## Note on Cost Explorer

`ce:Get*` is in the policy because breakdowns are occasionally worth running.
**Every Cost Explorer call is billed at $0.01.** Nothing calls it on a timer and
nothing should start; a polling loop against it is how a $0.50/month account
becomes a surprise.
