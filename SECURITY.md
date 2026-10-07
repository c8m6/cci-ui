# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/c8m6/cci-ui/security/advisories/new)
when it is available and enabled for this repository. A GitHub account is
required. Open the repository's **Security** tab and select
**Report a vulnerability**.

If that option is unavailable, including while the repository is private, open
an issue asking only for a private security contact. Do not include vulnerability
details, affected sensitive endpoints, exploit instructions or attachments in
that issue. Wait until a private channel has been agreed before sharing details.
No email address or alternative private channel is published here.

Do not use public GitHub Issues or pull requests to disclose an exploitable,
undisclosed vulnerability. Keep reproduction details in the private report until
disclosure has been coordinated with the maintainers.

Include the affected release tag or commit, deployment conditions, required
permissions, expected and observed behavior, and a minimal reproduction using
synthetic data. Describe the potential impact. Do not include production private
keys, passwords, tokens, certificates containing sensitive information, or other
secrets.

## Versions and fixes

The project does not currently publish a maintained-version matrix, a long-term
support policy or a guaranteed response schedule. This document does not promise
security backports to older releases. Report the exact affected version even if
you cannot reproduce the issue on the newest release.

Check [GitHub Releases](https://github.com/c8m6/cci-ui/releases) for release and
prerelease status and update notes. Release tags are the authoritative
application version source.

## Security checks and deployment

See [security validation](docs/container-publishing.md#security-validation) for
scanner coverage, gates, reports and finding review. A passing scan does not
prove that no vulnerabilities remain.

Follow the [production deployment guide](docs/installation.md#production-deployment)
for authentication, HTTPS, Consul ACLs and secret handling. Local test identities
are for development and evaluation only.
