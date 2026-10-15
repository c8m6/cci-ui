# Production Compose with external services

[compose.full.yml](../compose.full.yml) retains web, indexer and one migration
job using an existing PostgreSQL, Consul and OIDC deployment. All three load
one read-only `config.yml` and the same secret/TLS directories. No application
settings are embedded in Compose environment variables.

1. Copy the Compose file and [config.example.yml](../config.example.yml) to a
   protected deployment directory, naming the latter `config.yml`.
2. Set the immutable image, endpoint URLs, database settings, OIDC client and
   stable areas. Preserve existing area keys and session secret.
3. Provide secret files under `secrets/`, CA/client TLS files under `tls/`, and
   change mounts for your actual legacy inventories. UID 10001 needs read access.
4. Set the same logical configuration and paths for web, indexer and migrate.
   An unused filesystem inventory requires neither a mapping nor a mount.
5. Start with `docker compose -f compose.full.yml up -d --wait`. The migration
   job must succeed before web and indexer start. The web service uses `/ready`.

The web legacy mount is writable for confirmed filesystem deletion; the indexer
mount is read-only. Configuration, TLS and secrets stay read-only for all
services. Never copy real YAML or secrets into the image. Run only one indexer.
Use an HTTPS reverse proxy and back up PostgreSQL, Consul, inventories and keys.

For subsequent releases, run migration once with the new immutable image,
then update replicas; see [deployment ordering](installation.md#deploying-multiple-web-replicas).
See [YAML configuration](configuration.md) for the full schema, inheritance,
multiple Consul clusters, PostgreSQL TLS and file-reference behavior.
