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

- Push to any branch: build and test, without registry login or publishing.
- Pull request: build and test, without registry login or publishing.
- Publish a GitHub release: check out its tag, build, test, and publish with
  that exact release tag as the container tag, for example `v1.2.3` →
  `my-organization/cci-ui:v1.2.3`.
- `workflow_dispatch`: build and test the selected ref; manual runs do not
  publish.

There are no path exclusions: documentation-only changes also build and test.
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
GitHub release notes use [release.yml](../.github/release.yml); pull requests
labeled `skip-changelog` are excluded.

Before publishing, the built image is tested against PostgreSQL and Consul
using the isolated [compose.ci.yml](../compose.ci.yml) configuration
(`db:prepare test`). Failures prevent publishing; test services are removed
even on failure. The final push uses the Buildx cache from the tested build.

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
