# CCI-UI project conventions

Read and apply the [shared engineering guidelines](https://github.com/c8m6/empeira/blob/aea7029f456c9b4b795b160f25c4bafec7fd7293/docs/engineering/AGENTS.md) alongside this
file. This repository specifies CCI-UI's contracts and required checks. An
explicit task instruction may override a convention for that task. For offline
work, use the shared file from the linked revision in your local instructions.

## Documentation and licensing

Write project documentation and comments in documentation examples in English.
Keep it consistent with the implemented UI, APIs, architecture, deployment,
operation and development procedures. Update the existing document when one
already covers the topic.

Project-owned code and documentation use `AGPL-3.0-or-later`. New code and
bundled material must be compatible with that license. Changing the project
license requires an explicit instruction.

### Screenshots

For visible UI changes, review every documentation screenshot showing the
affected UI and refresh those that changed. Preserve their locations, names,
dimensions and documentation structure where practical. Use the isolated
capture workflow in [CONTRIBUTING.md](CONTRIBUTING.md#development-and-validation).

## Validation before completion

Follow the commands in [CONTRIBUTING.md](CONTRIBUTING.md#development-and-validation)
and the blocking thresholds in [container publishing](docs/container-publishing.md#security-validation).
Review documentation and affected screenshots as part of completion.

- Run the full CI Rails suite with isolated PostgreSQL and Consul data. Use
  deterministic fixtures or synthetic certificates, CSRs and keys. Production
  data, certificates, keys and credentials must stay out of tests.
- Before committing meaningful application changes, run the relevant Rails tests,
  RuboCop, Brakeman and bundler-audit with current advisories. Every image build
  runs RuboCop with the `rubocop-rake` plugin before asset compilation. Fix
  lint failures before continuing.
- Image, runtime and deployment changes also require a local build, Compose
  tests with PostgreSQL and Consul, and Trivy against the exact image. A release
  requires full image and integration tests and Trivy locally, manually or in
  the release workflow.
- Resolve genuine findings introduced by the change. Classify baseline findings
  and report unresolved dependency or image risks. A suppression for a false
  positive or accepted risk requires evidence of applicability, a specific
  reason, an owner and a review date. A green build alone cannot justify it.
- Normal push and PR CI runs direct Rails tests, RuboCop, Brakeman and
  bundler-audit. Image builds, image tests, Trivy and full report uploads stay
  outside this budget. Heavy schedules or broad OS/Ruby matrices require an
  explicit release-critical need. CodeQL Advanced Setup analyzes Ruby on
  pushes to `main` and manual runs. PR or scheduled CodeQL requires a specific
  security need that justifies the cost.

### Development environments

After validation in a persistent local environment, run
`docker compose -f compose.yml up --build -d --wait`, verify the application
responds at `http://localhost:3000` and leave it running for manual testing.
Investigate startup or health failures and fix those caused by the change.

In ephemeral environments, apply the same checks. Start the services needed
for validation and stop or discard them afterwards. Report incomplete checks
and their blocking dependencies. Only claim full validation when all required
checks ran successfully.

## Commit workflow

Automatically commit successfully validated work unless instructed otherwise,
and report the commits created. Unexpected failures in relevant tests block
the commit. Include any affected screenshots in the documentation review.

## Conventional Commits

Use Conventional Commit messages.

Preferred commit types are:

```text
feat:
fix:
perf:
refactor:
docs:
test:
chore:
```

Use a meaningful scope when it improves clarity.

Examples:

```text
feat(logging): add structured oidc diagnostics
fix(keycloak): handle missing client roles correctly
feat(csr): add certificate lifecycle handling
refactor(puppetdb): simplify result comparison
chore(release): add build metadata
```

Commit messages should describe the functional purpose of the change rather
than listing modified files.

Conventional Commit subjects are the input for automatically generated public
release notes. Use `feat` for new user-visible behavior, `fix` for user-visible
corrections, `perf` for meaningful performance improvements, and `refactor`
only when the improvement is useful to release readers. Use `docs`, `test`, and
`chore` for internal work that should normally stay out of public release
notes. Do not select a public type merely to make an internal change appear in
the notes. Keep internal refactors out of public release notes.

One user-visible result should generally be one logical commit. Put independent
user-visible results in separate commits so each release-note entry remains
clear and can be reviewed or reverted independently.

Avoid commit messages such as:

```text
update files
changes
fix stuff
update controllers and views
```

After creating commits, provide a short summary of the commits that were
created.

## Pull request conventions

Group related logical commits into one reviewable pull request.

## Versioning

The GitHub release tag is the single authoritative source of the application
version.

Example:

```text
v1.4.2
```

Do not introduce or maintain a second manually synchronized application
version in files such as:

```text
VERSION
version.txt
```

unless such a file becomes technically necessary for a future tool and is
generated automatically from the release tag.

There must not be two independently maintained version sources.

## Release workflow

The intended release workflow is:

```text
Implement changes on dev
→ create logical Conventional Commits
→ merge dev into main
→ manually dispatch container release on main in dry-run mode
→ inspect full image build, tests and security gates
→ manually dispatch again with dry_run=false
→ create the validated tag → push the exact tested image to Docker Hub
→ generate git-cliff notes → publish the GitHub release
```

Manual workflow dispatch is the only supported publishing trigger. Creating a
tag or publishing a GitHub release manually must not independently build or push
a container. The workflow must never publish from a branch other than main,
reuse an existing tag, or publish before validation. Do not deploy to production
hosts as part of this workflow.


## Build metadata

The container build should provide the following metadata:

```text
APP_VERSION
APP_REVISION
APP_BUILD_TIME
```

Their meaning is:

```text
APP_VERSION
GitHub release tag, for example v1.4.2

APP_REVISION
Git commit SHA of the exact source revision used for the build

APP_BUILD_TIME
UTC timestamp of the container build
```

The application must not depend on the `.git` directory being available at
runtime.

The Git repository must not be required inside the production container for
determining application version information.

## Docker build metadata

The Docker build should accept the build metadata through build arguments and
make it available to the application.

Use the existing Dockerfile structure and avoid introducing a parallel
versioning mechanism.

Conceptually:

```dockerfile
ARG APP_VERSION=development
ARG APP_REVISION=unknown
ARG APP_BUILD_TIME=unknown

ENV APP_VERSION=${APP_VERSION}
ENV APP_REVISION=${APP_REVISION}
ENV APP_BUILD_TIME=${APP_BUILD_TIME}
```

Adapt the implementation to the existing Dockerfile rather than duplicating
existing configuration.

For local development, use sensible fallbacks:

```text
APP_VERSION=development
APP_REVISION=unknown
APP_BUILD_TIME=unknown
```

## GitHub Actions release metadata

The GitHub Actions workflow responsible for release container builds should
derive build metadata from validated manual release inputs and the checked-out main commit.

For a release tagged:

```text
v1.4.2
```

the build should effectively receive:

```text
APP_VERSION=v1.4.2
APP_REVISION=<commit sha>
APP_BUILD_TIME=<UTC build timestamp>
```

Preserve the existing container image tagging behavior unless a change is
explicitly required.

Do not create a separate independent version calculation.

## OCI image metadata

Where appropriate, add standard OCI image labels:

```text
org.opencontainers.image.version
org.opencontainers.image.revision
org.opencontainers.image.created
org.opencontainers.image.source
```

Use the same build metadata that is already used for the application.

Do not calculate these values separately.

## Application build information

Provide application build information through one central application-level
abstraction.

Application code should not independently read the environment variables from
multiple unrelated places.

Expose at least:

```text
version
revision
build_time
```

Use local development fallbacks:

```text
version = development
revision = unknown
build_time = unknown
```

## Version display in the UI

Display the current application version in the UI.

The version must appear:

- below the application title
- on the left side
- significantly smaller than the application title
- visually subtle
- consistent with the existing design
- without competing with primary navigation

Example:

```text
CCI-UI
v1.4.2
```

Do not permanently display the Git revision or build timestamp directly below
the application title.

If an existing About, Info, Status, or similar view already exists, it may
also display:

```text
Version
Revision
Build time
```

Do not create a large dedicated page only for these values unless explicitly
requested.

## Build information logging

Log build information once when the application starts.

Use the application's existing structured JSON logging.

Example:

```json
{
  "level": "INFO",
  "message": "CCI-UI started",
  "version": "v1.4.2",
  "revision": "a3f928c",
  "build_time": "2026-09-26T08:35:21Z"
}
```

Do not introduce a separate logging mechanism for build information.

## Release notes

Release notes must correspond to the changes introduced since the previous
release.

Use eligible Conventional Commit subjects as their source and configure their
rendering through:

```text
cliff.toml
```

The manual release workflow creates the tag only after all gates pass, then runs `git-cliff` against that tag to prepare release notes for the GitHub release created after Docker Hub publication. Do not maintain a
parallel `CHANGELOG` or another version source manually.

Public categories are:

```text
feat     → New Features
fix      → Bug Fixes
perf     → Performance
refactor → Improvements
```

Commits using `docs`, `test`, `chore`, `ci`, `build`, or `style` are excluded,
as are merge commits, non-Conventional commits, and other unmatched history.
Useful scopes are retained in the rendered entry and descriptions are
capitalized.

## Release note quality

Release notes should describe meaningful functional changes.

Do not generate release notes that merely list changed files or implementation
details.

Avoid:

```text
- changed auth_controller.rb
- changed logging config
- updated dockerfile
```

Prefer:

```text
- Improved Keycloak authorization diagnostics
- Added structured JSON logging across the application
- Added application version information to container builds
```

Release notes for a version must only contain changes introduced since the
previous release.

Do not repeat changes from older releases.

## Logging conventions

Use the application's central logging infrastructure for all application
logging.

Application logs should use one consistent structured JSON format regardless
of which application component produces the message.

Do not mix structured JSON logging with custom plaintext application logs.

Prefer structured fields for diagnostic information instead of embedding all
context into the message string.

Do not introduce independent logging mechanisms for individual components
unless technically unavoidable.

Existing security requirements for logging remain applicable:

- never log passwords
- never log access tokens
- never log refresh tokens
- never log client secrets
- never log session cookies
- never log Authorization headers
- never log private keys
- never log revoke passwords
- never log other credentials or secrets

Debug logging may include non-sensitive interpreted information such as:

- usernames
- client IDs
- realms
- effective roles
- required roles
- HTTP status codes
- decision results
- request IDs
- operation names

Never log complete JWTs solely for debugging purposes.
