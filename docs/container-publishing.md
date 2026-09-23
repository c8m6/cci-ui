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
- Push any Git tag: build, test, and publish with that exact Git tag as the
  container tag, for example `v1.2.3` → `my-organization/cci-ui:v1.2.3`.
- `workflow_dispatch`: build and test the selected ref, including when selecting
  a tag; manual runs do not publish.

There are no path exclusions: documentation-only changes also build and test.
BuildKit uses a GitHub Actions cache for unchanged layers.

Each tag push publishes only `DOCKERHUB_IMAGE:<Git tag>`. No additional branch,
SHA or `latest` aliases are generated. The Git tag must also be a valid Docker
tag; incompatible names (for example, names containing `/`) fail publishing
instead of being renamed. Use an image digest for reproducible deployments.
The image is built for `linux/amd64` on the GitHub Ubuntu runner.

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

Both services use `CCI_IMAGE`; without this variable, local builds using
`cci-ui:local` remain available. For private Docker Hub repositories, log in
on the deployment host first. Web startup runs database migrations; the indexer
automatically retries failed indexing passes during startup.

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
