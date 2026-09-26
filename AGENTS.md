# Project conventions

These instructions apply permanently to all work in this repository unless a later explicit instruction overrides them for a specific task.

## General conventions

- Write all project documentation in English, including new documents, updates
  to existing documentation, and comments in documentation examples.
- Preserve exact UI labels and other literal values when documenting them.
- Prefer existing project conventions, architecture, helpers, and abstractions
  over introducing parallel mechanisms.
- Avoid unnecessary duplication of configuration, business logic, version
  information, or infrastructure mechanisms.
- Keep changes focused and avoid unrelated refactoring unless it is required
  for the requested change.

## Documentation

- Keep the project documentation up to date with every change.
- Review the existing documentation for every task and update all affected
  documentation as part of the same change.
- Documentation must remain consistent with the actual implementation,
  configuration, architecture, deployment, operation, APIs, user workflows,
  and development procedures.
- Prefer updating existing documentation over creating new documents when an
  appropriate document already exists.
- Do not leave documentation describing obsolete behavior, configuration, UI,
  workflows, or architecture.
- Documentation updates belong to the same logical commit as the change they
  describe unless there is a clear reason to separate them.

### Screenshots

- When a change visibly affects the user interface, review all documentation
  screenshots that show the affected UI.
- Update affected screenshots so they reflect the current user interface.
- Do not leave outdated screenshots in the documentation.
- Preserve the existing screenshot location, naming conventions, dimensions,
  and documentation structure where practical.
- Only update screenshots affected by the change; do not regenerate unrelated
  screenshots unnecessarily.

## Validation before completion

Before completing changes:

- Run the full Rails test suite used by CI:

  ```bash
  ruby bin/rails db:prepare test
  ```

- Run the tests against the current application image with PostgreSQL and
  Consul.
- Tests must use isolated test data and must not depend on production data,
  production certificates, production private keys, production credentials,
  or other production secrets.
- When certificate-related test data is required, use deterministic test
  fixtures or generate synthetic certificates, CSRs, keys, and related data
  specifically for the test environment.
- Fix failures caused by the current changes before reporting completion.
- Do not commit changes that fail relevant tests unexpectedly.
- Run RuboCop with the `rubocop-rake` plugin for every build.
- The Dockerfile enforces RuboCop before asset compilation.
- Fix lint failures before continuing.
- Verify that the project documentation reflects the completed change.
- Verify that screenshots affected by visible UI changes have been updated.
- Documentation and required screenshot updates are part of the definition of
  done and must not be silently skipped.
- Do not silently skip required tests, linting, documentation, screenshot
  updates, or other validation steps.
- If a required validation step cannot be executed because of an environment
  limitation or unavailable dependency:
  - clearly report which validation step could not be executed;
  - explain the blocking dependency or environment limitation;
  - do not report the change as fully validated;
  - do not treat an unexecuted validation step as successful.

### Persistent local development environments

When running in a persistent local development environment, after completing
changes and all required validation:

- Rebuild and start the development containers with:

  ```bash
  docker compose -f compose.yml up --build -d --wait
  ```

- Verify that the application responds at:

  ```text
  http://localhost:3000
  ```

- Leave the development containers running so the current changes are
  immediately available for manual testing.
- If the application does not become healthy or does not respond at
  `http://localhost:3000`, investigate and fix failures caused by the current
  changes before reporting completion.

### Ephemeral or cloud environments

When running in an ephemeral environment, such as Codex Cloud:

- The same test, linting, documentation, screenshot, and code-quality
  requirements apply as in a persistent local development environment.
- Start PostgreSQL, Consul, the application, containers, or other required
  services when needed to execute tests or perform validation.
- Do not keep development containers or services running solely for later
  manual testing after the task has completed.
- Stop or discard temporary services when they are no longer required.
- The inability to leave development containers running after task completion
  is not a validation failure.
- Environment limitations are not a reason to silently omit required
  validation.
- Clearly report any required validation that could not be performed and the
  reason why it could not be performed.
- A task must not be reported as fully validated when a required validation
  step was skipped, failed, or could not be executed.

## Commit workflow

Codex should create commits automatically after a requested change has been
completed successfully, unless explicitly instructed not to commit.

A separate instruction such as "commit this" is not required.

Before creating commits:

1. Review all modified, added, and deleted files.
2. Check whether all changes belong to the same logical topic.
3. Separate unrelated changes into different commits.
4. Run the relevant tests and linting.
5. Check that affected documentation and screenshots are up to date.
6. Check for accidental or unrelated modifications.
7. Do not commit changes when relevant tests fail unexpectedly.

### Logical commits

Each commit should represent one logically coherent change.

Multiple technical changes may be included in one commit when they serve the
same functional goal.

For example, the following may belong to one logging-related change:

- structured JSON logging
- request correlation IDs
- Keycloak authorization diagnostics
- PuppetDB diagnostics
- removal of unnecessary database log noise

Unrelated topics should be committed separately.

For example, do not combine all of the following into one commit without a
clear functional dependency:

- logging changes
- CSR functionality
- unrelated CSS changes
- unrelated container changes

A commit should ideally be:

- understandable on its own
- reviewable on its own
- revertible on its own
- useful when reading the Git history later

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

A pull request should represent a larger but still logically coherent unit of
work.

A pull request may contain multiple logical commits.

Example:

```text
PR: Improve application logging

Commits:
feat(logging): unify structured json logging
feat(logging): add request correlation
feat(keycloak): add authorization diagnostics
feat(puppetdb): distinguish no data from no difference
```

Release notes describe the functional results represented by eligible
Conventional Commit subjects, not every internal implementation commit.

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
→ publish a GitHub release and tag from main
→ generate release notes since the previous release tag
→ update the published GitHub release
→ build, test, and publish the versioned container image
```

Creating a GitHub release and release tag triggers the container build.

If a GitHub release is created with:

```text
v1.4.2
```

the resulting container and application must identify themselves as:

```text
v1.4.2
```

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
derive build metadata from the GitHub release context.

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

The release workflow runs `git-cliff` against the tag of the published GitHub
release. It replaces that release's description with entries from after the
previous matching release tag through the current tag. Do not maintain a
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

## Long-term applicability

These conventions are permanent repository instructions.

In particular:

- Codex creates suitable commits after successfully completed tasks.
- Unrelated changes are separated into different commits.
- Conventional Commits are used.
- Eligible Conventional Commit subjects are the source for public release
  notes.
- Commits should be individually understandable and revertible.
- Relevant tests and linting are run before commits are considered complete.
- Required validation must never be silently skipped.
- Project documentation is reviewed and kept up to date with every change.
- Documentation remains consistent with the actual implementation and
  operation of the application.
- Visible UI changes require affected documentation screenshots to be updated.
- Documentation and required screenshot updates are part of the definition of
  done.
- Tests use isolated test data and do not depend on production data or secrets.
- Certificate-related tests use deterministic fixtures or synthetic
  certificates, CSRs, keys, and related test data.
- In persistent local development environments, the development environment is
  rebuilt, verified, and left running after completed changes.
- In ephemeral or cloud environments, the same validation requirements apply,
  but services do not need to remain running after task completion.
- Tasks are not reported as fully validated when required validation was
  skipped, failed, or could not be executed.
- GitHub release tags are the single authoritative application version source.
- Application versions are not maintained manually in parallel.
- Release versions are injected into container builds.
- The version is displayed subtly below the application title on the left.
- Build version, revision, and build time remain technically traceable.
- Release notes describe changes since the previous release.
- Existing project structures and conventions are preferred over parallel
  implementations.

A later explicit instruction may override these conventions for a specific
task.