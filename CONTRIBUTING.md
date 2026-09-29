# Contributing to CCI-UI

Contributions and pull requests are welcome. Develop changes on a branch, keep
each commit focused, and use the Conventional Commit format described in
[AGENTS.md](AGENTS.md). Start with the [local setup](README.md#quick-start) and
complete the validation below before opening a pull request. Report undisclosed
vulnerabilities through the private channel in [SECURITY.md](SECURITY.md).

## Licensing

By submitting a contribution, you confirm that you have the right to submit it
and intend it to be distributed as part of CCI-UI under `AGPL-3.0-only`. Do not
knowingly submit code, documentation, assets, or other material whose license is
incompatible with the project.

Preserve all applicable third-party copyright, attribution, and license notices.
Describe the origin and license of any new dependency or third-party material in
the pull request. If compatibility or provenance is uncertain, raise it for
review instead of making an assumption.

CCI-UI does not require a Contributor License Agreement or assignment of
copyright. Contributors retain ownership of their contributions.

## Development and validation

Every application image build runs RuboCop with the `rubocop-rake` plugin before
asset compilation. The rules in `.rubocop.yml` cover application code, shared
libraries, Puppet copies, scripts and tests. Lint failures stop the build.

```console
bundle exec rake rubocop
# Refresh the shipped Puppet libraries after changing shared Ruby code.
ruby bin/package-puppet

docker build -t cci-ui:ci .
docker compose -f compose.ci.yml up --wait db consul
docker compose -f compose.ci.yml run --rm app ruby bin/rails db:prepare test
docker compose -f compose.ci.yml down --volumes
```

Run the [security checks](docs/container-publishing.md#run-security-checks-locally)
against the same image. Tests use isolated PostgreSQL and Consul data and
synthetic certificates. Never use production certificates, keys or secrets as
test fixtures. Local certificate files, runtime data and secrets are excluded
from version control and application images.

Update affected documentation with each change. For visible UI changes, review
and refresh affected screenshots using the isolated
[screenshot stack](script/screenshots/compose.yml) and
[capture script](script/screenshots/capture.cjs). Screenshots must show the actual
application with synthetic data. Remove the disposable stack afterwards with
`docker compose -f script/screenshots/compose.yml down --volumes`.

In a persistent development environment, finish by rebuilding and starting the
local stack, check `http://localhost:3000`, and leave it running for manual testing:

```console
docker compose -f compose.yml up --build -d --wait
```

See [AGENTS.md](AGENTS.md) for the complete validation and commit conventions,
including cleanup in ephemeral environments. Report any validation that could
not be run and its blocking dependency.
