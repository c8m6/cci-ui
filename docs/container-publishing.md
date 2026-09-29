# Publishing containers with GitHub Actions

The [docker-publish.yml](../.github/workflows/docker-publish.yml) workflow builds
the shared image for **web and indexer** from the root Dockerfile. PostgreSQL
and Consul use their official images and do not require a custom build.

## Set up GitHub and Docker Hub

Create a repository in the desired Docker Hub namespace, then configure the
following in GitHub under Settings → Secrets and variables → Actions:

| Type | Name | Example / contents |
| --- | --- | --- |
| Repository variable | `DOCKERHUB_USERNAME` | Docker Hub username associated with the token |
| Repository variable | `DOCKERHUB_IMAGE` | `my-organization/cci-ui`, without a tag or URL scheme |
| Repository secret | `DOCKERHUB_TOKEN` | Docker Hub access token with write permission for this repository |

The target is configurable; the GitHub repository name does not have to match
the Docker Hub namespace. Builds require no production data, Consul tokens,
or area encryption keys. The repository operator must supply the registry
credentials for tag publishing only. Branch builds, pull requests and manual
runs do not require Docker Hub credentials. Adding the workflow alone does not
upload anything locally.

## Triggers, changes, and tags

- Push to any branch: build, test, and scan, without registry login or publishing.
- Pull request: build, test, and scan, without registry login or publishing.
- Publish a GitHub release: check out its tag, build, test, scan, and publish with
  that exact release tag as the container tag, for example `v1.2.3` →
  `my-organization/cci-ui:v1.2.3`. A separate job generates release notes for
  that tag and updates the already-published GitHub release.
- `workflow_dispatch`: build, test, and scan the selected ref; manual runs do not
  publish.

There are no path exclusions: documentation-only changes also build, test, and scan.
BuildKit uses a GitHub Actions cache for unchanged layers.

Each published release creates only `DOCKERHUB_IMAGE:<release tag>`. No
additional branch, SHA or `latest` aliases are generated. The release tag must
also be a valid Docker tag; incompatible names (for example, names containing
`/`) fail publishing instead of being renamed. Use an image digest for
reproducible deployments. The image is built for `linux/amd64` on the GitHub
Ubuntu runner.

The release tag is the authoritative application version. The workflow passes
it to the image as `APP_VERSION`, resolves `APP_REVISION` from the checked-out
tag and records one UTC `APP_BUILD_TIME`. The same values populate standard
OCI image labels. Local and non-release builds use `development` as the
version. At runtime, web and indexer log all three values once in the structured
`CCI-UI started` event. The sidebar displays only the version. Generated
GitHub release notes use [cliff.toml](../cliff.toml) and Conventional Commit
subjects from after the previous release tag through the published tag. The
release-note job checks out the tagged revision with the complete Git history
and tags, then updates the release using the repository `GITHUB_TOKEN`.

The intended release sequence is:

```text
develop on dev
→ create logical Conventional Commits
→ merge dev into main
→ publish the GitHub release and tag
→ GitHub Actions generates notes since the previous release tag
→ GitHub Actions updates the release description
→ the tested versioned image is published
```

`feat`, `fix`, `perf`, and meaningful `refactor` commits appear under **New
Features**, **Bug Fixes**, **Performance**, and **Improvements**. Useful scopes
are retained. Merge commits, non-Conventional commits, and commits using
`docs`, `test`, `chore`, `ci`, `build`, or `style` are omitted. There is no
manually maintained changelog or second version source.

Release-note generation runs only for the GitHub `release.published` event.
Creating or editing a draft does not run it, and editing a published release
does not generate the notes again. Rerun the original workflow job if release
note generation failed. The release-note job is isolated from the application
build, test, and container publication job; it alone receives `contents: write`
permission.

Before publishing, the built image is tested against PostgreSQL and Consul
using the isolated [compose.ci.yml](../compose.ci.yml) configuration
(`db:prepare test`). Failures prevent publishing; test services are removed
even on failure. The final push tags and pushes the exact local image that passed
tests and security checks. It does not rebuild the image before publishing.

The actions follow Docker's official
[Test before push](https://docs.docker.com/build/ci/github-actions/test-before-push/)
workflow. Event and tag filter behavior is described in the
[GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

## Deploy a published image

Set the image alongside the existing production environment variables, either
through the deployment environment or an optional environment file:

```dotenv
CCI_IMAGE=my-organization/cci-ui:v1.2.3
```

```console
docker compose --env-file .env.production -f compose.production.yml pull web indexer
docker compose --env-file .env.production -f compose.production.yml up -d --no-build
```

Web, indexer and the migration job use `CCI_IMAGE`; without this variable, local builds using
`cci-ui:local` remain available. For private Docker Hub repositories, log in
on the deployment host first. The one-shot migration job must succeed before
web and indexer start. Web startup never runs migrations. For controlled release
updates with existing replicas, follow the
[deployment ordering](installation.md#deploying-multiple-web-replicas).
The indexer retries failed indexing passes.

To run CI locally without Docker Hub credentials:

```console
docker build -t cci-ui:ci .
docker compose -f compose.ci.yml up --wait db consul
docker compose -f compose.ci.yml run --rm app ruby bin/rails db:prepare test
docker compose -f compose.ci.yml down --volumes
```

The Dockerfile runs `bundle exec rubocop --force-exclusion` before asset compilation.
This includes the `rubocop-rake` plugin and blocks image builds on lint failures.
The same check runs in local Compose builds.

## Security validation

Every branch push, pull request, manual run, and published release runs these
checks. One Docker build supplies the Rails tests and Trivy image scan. The Ruby
scanners use Ruby 3.4 and the committed `Gemfile.lock` through Bundler on the
runner. They do not need running application services or credentials.

| Tool | Scope | Blocking findings |
| --- | --- | --- |
| Brakeman | Rails application source | High- and medium-confidence warnings (`--confidence-level 2`), and scanner errors |
| bundler-audit | Locked Ruby dependencies against a freshly updated ruby-advisory-db | Any known applicable vulnerability or insecure gem source, and scanner/update errors |
| Trivy | OS packages and application libraries in the actual application image | Fixable HIGH or CRITICAL vulnerabilities, and scanner errors |

Brakeman confidence measures the reliability of a warning, not its severity.
Low-confidence warnings are outside this initial gate. Trivy retains all
severities and unfixed vulnerabilities in its JSON, SARIF, and human-readable
report. The blocking check uses `jq` to select entries with a nonempty fixed
version and converts that derived JSON with the narrower severity policy,
so it does not perform a second image scan. Secret and configuration scanning
are not enabled in Trivy. bundler-audit covers the complete lockfile, including
development tools, while Trivy additionally inspects OS packages and application
library manifests in the built image.

CI logs include human-readable findings. The `security-reports` Actions artifact
retains Brakeman JSON/SARIF, bundler-audit JSON, and Trivy JSON/SARIF for 14 days,
even when a security gate fails. Brakeman and Trivy SARIF are also uploaded to
GitHub **Security → Code scanning**. bundler-audit does not provide native SARIF.
The upload action is used only to publish these reports, not to run CodeQL.
Native CodeQL, Dependabot, and Secret Scanning remain repository settings.

Fork pull requests receive no repository secrets and do not upload SARIF. Their
reports remain available as workflow artifacts. Dependabot-triggered runs also
use artifacts only. The application job requests `contents: read` and
`security-events: write` for eligible SARIF uploads, subject to GitHub's fork
token restrictions. Checkout does not persist credentials. Docker Hub secrets
are referenced only in release-only steps. There is no `pull_request_target`
workflow, personal access token, or external scanning service. Advisory databases
are downloaded, but application images and source are not sent to a scanning
service. Only reports are uploaded to GitHub.

A failed build, test, scanner, security gate, or required report step prevents
release publication. Tests and independent scans still run after another scan
fails, and test services are always removed. Release-note generation retains
its separate release-only job and permissions.

### Run security checks locally

With Ruby 3.4, Git, and `jq` installed, run from the repository root:

```console
bundle install
mkdir -p tmp/security/sarif
bundle exec brakeman --no-pager --confidence-level 2 --output /dev/stdout --output tmp/security/brakeman.json --output tmp/security/sarif/brakeman.sarif
bundle exec bundler-audit update
bundle exec bundler-audit check --format json --output tmp/security/bundler-audit.json
bundle exec bundler-audit check

docker build --pull -t cci-ui:ci .
trivy image --timeout 30m --scanners vuln --pkg-types os,library --format json --output tmp/security/trivy.json cci-ui:ci
trivy convert --format sarif --output tmp/security/sarif/trivy.sarif tmp/security/trivy.json
trivy convert --format table tmp/security/trivy.json
jq '.Results |= map(if .Vulnerabilities then .Vulnerabilities |= map(select(.FixedVersion != null and .FixedVersion != "")) else . end)' tmp/security/trivy.json > tmp/security/trivy-fixable.json
trivy convert --format table --severity HIGH,CRITICAL --exit-code 1 tmp/security/trivy-fixable.json
```

Use Trivy 0.74.0 to match CI. Install it from the
[official releases](https://github.com/aquasecurity/trivy/releases/tag/v0.74.0)
and verify the release checksum. CI pins the official Trivy action to its
v0.36.0 commit and explicitly selects the scanner version. These releases
postdate the [March 2026 supply-chain incident](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23).
Review provenance when updating the pins. The bundled JRuby archive in
`concurrent-ruby` also triggers the Java database download. Allow time for the
initial database downloads rather than disabling library analysis. If the default
mirror is unavailable, the official alternate Java database is
`--java-db-repository ghcr.io/aquasecurity/trivy-java-db:1`.
Run the PostgreSQL/Consul test commands above against that same `cci-ui:ci` image. RuboCop runs during the image build.

The image excludes Bundler's development/test groups. Run the Ruby scanners in
a development Ruby environment with those groups enabled, rather than expecting
the scanner executables in the production image. This also keeps Brakeman out of
the distributed image: its [Public Use License](https://github.com/presidentbeef/brakeman/blob/main/LICENSE.md)
permits analyzing one's own software but restricts commercial redistribution.
Brakeman is separate analysis tooling and is not loaded into CCI-UI. Do not assume
its license permits bundling it in a redistributed product. bundler-audit is
GPL-3.0-or-later and Trivy/the Trivy action are Apache-2.0. Neither changes the
project's AGPL-3.0-only license. Preserve upstream notices and review licensing
and known vulnerabilities whenever dependencies are added or updated.

### Review findings and suppressions

For each finding, record whether it concerns project code, a Ruby dependency, or
the base image, and check the affected version and execution path. Fix applicable,
actionable findings, using the smallest compatible dependency update where
needed, then rerun security checks and the complete Rails suite. Unfixed image
vulnerabilities and lower severities remain visible for review even when they do
not block CI. Report unresolved base-image vulnerabilities rather than changing
platforms or hiding them merely to obtain a clean report.

Do not add an ignore entry solely to make CI pass. A persistent suppression must
identify the exact warning fingerprint or advisory, explain with evidence why it
is a false positive or an explicitly accepted risk, and record the accepting
owner and review date in this document alongside the tool's narrow ignore entry.
Risk acceptance requires an explicit maintainer decision. Reassess suppressions
when code, dependencies, or deployment assumptions change. No persistent
suppressions are introduced by this integration.


### Initial baseline (2026-09-29)

Brakeman 8.0.6 initially reported two findings. The EOL Ruby warning referred to
stale `Gemfile.lock` metadata for Ruby 3.2.3, while the application image already
ran Ruby 3.4.11. Updating only the locked Ruby metadata resolved that mismatch.
The mass-assignment warning concerned the CSR publication index map. The service
already selected only the request's own areas and converted each index to an
integer, so the map could not mass-assign model attributes. The controller now
explicitly permits only those area names, removing `permit!` without an ignore.
The repeat scan reported zero warnings and zero errors.

bundler-audit 0.9.3 found no advisories for the locked dependencies using
ruby-advisory-db commit `47b5bdca2771ccac35faf579c4fcea1dc8d5726a`. Existing gem
versions were preserved. The image build passed RuboCop with `rubocop-rake`, and
the PostgreSQL/Consul Rails suite passed 270 tests and 3,752 assertions with no
failures, errors, or skips. No UI or screenshot changes were needed.


Trivy 0.74.0 scanned the same image used for those tests,
`sha256:01a639c19d42eed4f4afab2de6c31047aa979dcd6e2255c7c0db7aed1b8fbdb5`,
built from the refreshed `ruby:3.4-slim` base (Debian 13.7). It reported 2,921
package/advisory occurrences, including repeated source-package advisories:

| Severity | OS packages | Ruby libraries |
| --- | ---: | ---: |
| CRITICAL | 1 | 0 |
| HIGH | 134 | 0 |
| MEDIUM | 1,461 | 0 |
| LOW | 819 | 1 |
| UNKNOWN | 505 | 0 |

None of the 2,920 OS occurrences had a fixed version in Trivy's Debian data.
The fixable HIGH/CRITICAL gate passed. These are inherited distribution/build
package findings, not newly discovered CCI-UI code vulnerabilities. They remain
visible in the complete reports and must not be described as a clean image.

Of these, 2,125 occurrences concern `linux-libc-dev`, including the sole CRITICAL
finding, [CVE-2026-43185](https://security-tracker.debian.org/tracker/CVE-2026-43185).
This installed package supplies [userspace development headers](https://packages.debian.org/trixie/linux-libc-dev),
not the running kernel or the vulnerable ksmbd server. The image scan does not
establish whether a deployment host's kernel is vulnerable. No kernel advisory
was suppressed. CVE-2026-16742 is attributed to `libsystemd0`/`libudev1`, but the
vulnerable `systemd-homed` executable is absent from this image.

The other HIGH advisories concern util-linux mount/namespace operations
(CVE-2026-76642 and CVE-2026-78408 through CVE-2026-78410), privileged libacl
pathname operations (CVE-2026-54369), Perl Archive::Tar parsing
(CVE-2026-9538), and ncurses `infocmp` parsing (CVE-2025-69720). Their packages
remain present. Application-level exploitability of the remaining distribution
findings has not been established, so they remain unresolved upstream risks,
not accepted-risk suppressions. The refreshed base and current Debian package
installation did not provide fixes. No distribution switch, broad dependency
upgrade, or build-toolchain refactoring was made solely to empty the report.

The LOW Ruby finding, CVE-2026-54696, concerns the base image's default
`json-2.9.1.gemspec`. The application lockfile already selects patched JSON 2.21.2,
and both early operational logging before Rails boot and `bundle exec ruby`
were verified to load 2.21.2. Explicitly invoking the old default gem remains a
base-image concern. No ignore entry or redundant gem update was added.

The SARIF and complete JSON reports were generated successfully, and synthetic
reports verified the image gate's blocking/nonblocking cases. `actionlint`
validated the workflow. GitHub-hosted execution, SARIF acceptance by the live
repository, and Docker Hub publication require the subsequent GitHub run and
were not exercised by this local validation.
