# Container mit GitHub Actions veröffentlichen

Der Workflow [docker-publish.yml](../.github/workflows/docker-publish.yml) baut
das gemeinsame Image für **Web und Indexer** aus dem Root-Dockerfile. PostgreSQL
und Consul verwenden ihre offiziellen Images und benötigen keinen eigenen Build.

## GitHub und Docker Hub einrichten

Im gewünschten Docker-Hub-Namespace ein Repository anlegen und in GitHub unter
Settings → Secrets and variables → Actions konfigurieren:

| Typ | Name | Beispiel / Inhalt |
| --- | --- | --- |
| Repository variable | `DOCKERHUB_USERNAME` | Docker-Hub-Benutzer des Tokens |
| Repository variable | `DOCKERHUB_IMAGE` | `meine-organisation/cci-ui`, ohne Tag und ohne URL-Schema |
| Repository secret | `DOCKERHUB_TOKEN` | Docker-Hub-Zugriffstoken mit Schreibrecht für dieses Repository |

Das Ziel ist bewusst konfigurierbar; der GitHub-Repositoryname muss nicht dem
Docker-Hub-Namespace entsprechen. Es werden keine Produktionsdaten, Consul-Tokens
oder Bereichsschlüssel zum Bauen benötigt. Die Zugangsdaten sind noch durch den
Repositorybetreiber zu hinterlegen. Das Hinzufügen des Workflows allein führt
lokal keinen Upload aus.

## Auslöser, Änderungen und Tags

- Push auf einen beliebigen Branch: Build, Tests und Push. Reine Änderungen
  an `docs/**`, Markdown-Dateien oder `.gitignore` werden übersprungen.
- Pull Request: Build und Tests, ohne Registry-Anmeldung und ohne Veröffentlichung.
- Push eines Tags `v*`: Build, Tests und Push auch ohne Codeänderung.
- `workflow_dispatch`: vollständiger Build und Push für den gewählten Ref;
  damit lassen sich auch aktualisierte Basisimages bewusst neu bauen.

Da nur ein eigenes Image existiert, löst jede nicht ausgeschlossene Änderung
dessen Build aus. Das schließt Dockerfile, Gems, App, Indexer, Migrationen,
Konfiguration, Tests, Compose und Workflow ein. BuildKit nutzt einen GitHub-Actions-
Cache für unveränderte Layer. Bei späteren zusätzlichen Dockerfiles muss die
Jobstruktur um deren Build und Änderungserkennung erweitert werden.

Veröffentlichte Tags: Branchname (durch die Metadata-Action normalisiert),
Git-Tag bei Release-Tags und `sha-<vollständiger Commit-SHA>`. Nur der Default-Branch
erhält außerdem `latest`; andere Branches und Release-Tags aktualisieren diesen
Tag nicht. Für reproduzierbare Deployments einen Image-Digest verwenden.
Das Image wird für `linux/amd64` auf dem GitHub-Ubuntu-Runner gebaut.

Vor dem Push wird das gebaute Image mit dem isolierten
[compose.ci.yml](../compose.ci.yml) gegen PostgreSQL und Consul getestet
(`db:prepare test`). Fehler verhindern die Veröffentlichung; die Testdienste
werden auch bei Fehlern entfernt. Der abschließende Push verwendet den Buildx-
Cache des zuvor getesteten Builds.

Die Actions entsprechen dem offiziellen Docker-Ablauf
[Test before push](https://docs.docker.com/build/ci/github-actions/test-before-push/).
Das Verhalten der Pfad- und Tagfilter beschreibt die
[GitHub-Workflow-Syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

## Veröffentlichtes Image einsetzen

In der Produktions-Umgebungsdatei neben den bestehenden Einstellungen setzen:

```dotenv
CCI_IMAGE=meine-organisation/cci-ui:sha-<commit-sha>
```

```console
docker compose --env-file .env.production -f compose.production.yml pull web indexer
docker compose --env-file .env.production -f compose.production.yml up -d --no-build
```

Beide Dienste verwenden `CCI_IMAGE`; ohne die Variable bleibt der lokale Build
unter `cci-ui:local` möglich. Bei privaten Docker-Hub-Repositories vorher auf dem
Deploymenthost anmelden. Der Webstart führt Datenbankmigrationen aus; der Indexer
wiederholt fehlgeschlagene Läufe während des Starts automatisch.

Lokalen CI-Lauf ohne Docker-Hub-Zugang ausführen:

```console
docker build -t cci-ui:ci .
docker compose -f compose.ci.yml up --wait db consul
docker compose -f compose.ci.yml run --rm app ruby bin/rails db:prepare test
docker compose -f compose.ci.yml down --volumes
```
