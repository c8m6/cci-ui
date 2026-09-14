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
credentials. Adding the workflow alone does not upload anything locally.

## Triggers, changes, and tags

- Push to any branch: build, test, and publish. Changes limited to `docs/**`,
  Markdown files, or `.gitignore` are skipped.
- Pull request: build and test, without registry login or publishing.
- Push a `v*` tag: build, test, and publish even without code changes.
- `workflow_dispatch`: complete build and publish for the selected ref;
  this also allows deliberate rebuilds with updated base images.

Since the project has only one custom image, any change outside the excluded
paths triggers its build. This includes the Dockerfile, gems, application,
indexer, migrations, configuration, tests, Compose files, and workflow. BuildKit
uses a GitHub Actions cache for unchanged layers. If additional Dockerfiles
are introduced, extend the jobs to build them and detect their relevant changes.

Published tags include the branch name (normalized by the Metadata action),
the Git tag for release tags, and `sha-<full-commit-sha>`. Only the default branch
also receives `latest`; other branches and release tags do not update it.
Use an image digest for reproducible deployments. The image is built for
`linux/amd64` on the GitHub Ubuntu runner.

Before publishing, the built image is tested against PostgreSQL and Consul
using the isolated [compose.ci.yml](../compose.ci.yml) configuration
(`db:prepare test`). Failures prevent publishing; test services are removed
even on failure. The final push uses the Buildx cache from the tested build.

The actions follow Docker's official
[Test before push](https://docs.docker.com/build/ci/github-actions/test-before-push/)
workflow. Path and tag filter behavior is described in the
[GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

## Deploy a published image

Add the following alongside the existing settings in the production environment
file:

```dotenv
CCI_IMAGE=my-organization/cci-ui:sha-<commit-sha>
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
