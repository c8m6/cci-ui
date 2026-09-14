# Consul-Schema und schreibende Clients

Consul ist die maßgebliche Ablage für neue Zertifikate. PostgreSQL enthält den
wiederherstellbaren Suchindex, einschließlich Herkunft. Direkte Consul-Imports
werden beim nächsten Indexlauf sichtbar (standardmäßig nach spätestens etwa
60 Sekunden bei erfolgreichem Lauf). Es gibt keine separate HTTP-Upload-API.

## Einrichtung

1. Bereiche mit stabilen IDs in `config/areas.yml` konfigurieren, beispielsweise
   `zone_a`. Jeder externe Client verwendet dieselben IDs.
2. Consul bereitstellen und `CONSUL_URL`, `CONSUL_TOKEN` und optional
   `CONSUL_PREFIX` (Standard `cci/v1`) setzen. Für TLS kann `CONSUL_CA_FILE`
   auf eine CA-Datei zeigen.
3. Schreibenden Clients eigene ACL-Tokens zuweisen: Schreibzugriff auf die
   benötigten `areas/<area>/lookups/`, `versions/`, gegebenenfalls `private-keys/`
   und `events/` unter dem Prefix. Lookup-Lesen ist für CAS erforderlich.
4. Für private Schlüssel je Bereich ein gemeinsames Verschlüsselungs-Secret
   konfigurieren: `<UPPERCASE_AREA_ID>_KEY`, Base64-kodierte 32 Zufallsbytes.
   Schreibende und entschlüsselnde Clients verwenden denselben Bereichsschlüssel.
5. PostgreSQL mit `ruby bin/rails db:prepare` aktualisieren und Web sowie Indexer
   mit dem neuen Image starten. `bin/start` führt `db:prepare` automatisch aus.

Consul benötigt keine Tabellenmigration: Die Clients legen die folgenden Keys
beim Schreiben an. Vorhandene Consul-Einträge werden nicht umgeschrieben.
Die Rails-Migration ergänzt die nullable Indexspalten `client` und `created_by`.

## KV-Struktur

Alle Werte sind JSON-Objekte. Die Consul-KV- und Transaktions-API transportiert
sie zusätzlich Base64-kodiert. `<base>` bedeutet `<prefix>/areas/<area>`.

| Pfad | Bedeutung |
| --- | --- |
| `<base>/lookups/<lookup>` | `{ "entry_id": "<uuid>", "active_version": "<version_id>" }` |
| `<base>/versions/<version_id>` | Öffentliches Zertifikat, Kette, Metadaten und Herkunft |
| `<base>/private-keys/<version_id>` | Optionaler AES-256-GCM-Umschlag des privaten Schlüssels |
| `<prefix>/events/<uuid>` | Audit-Ereignis zur Änderung |

Ein Lookup besteht aus 1–120 Zeichen: `a-z`, `A-Z`, `0-9`, `.`, `_`, `-`.
Er bleibt bei Erneuerungen gleich. Die `entry_id` ist eine pro Bereich/Lookup
einmal erzeugte UUID. Die `version_id` ist der kleingeschriebene SHA-256-Hexwert
des UTF-8-Strings `<entry_id>:<fingerprint>`.

### Zertifikatsversion

| Feld | JSON-Typ und Inhalt |
| --- | --- |
| `schema` | String `"1"` |
| `entry_id` | UUID als String; unverändert für weitere Versionen desselben Lookups |
| `lookup` | Stabiler Lookup-Name |
| `pem` | Ein öffentliches X.509-Zertifikat als PEM-String |
| `chain` | **String mit JSON-Array** aus PEM-Strings, ohne das eigene Zertifikat, Aussteller zuerst; leer: `"[]"` |
| `tags` | **String mit JSON-Array** aus Tag-Strings; leer: `"[]"` |
| `fingerprint` | SHA-256 über Zertifikats-DER, 64 kleingeschriebene Hexzeichen |
| `public_key_fingerprint` | SHA-256 über SubjectPublicKeyInfo-DER (`public_to_der`), 64 Hexzeichen |
| `has_key` | String `"1"` oder `"0"`; bei `"1"` muss der Schlüsselumschlag existieren |
| `created_at` | Erstellzeit dieser gespeicherten Version als ISO-8601-String mit Zeitzone |
| `client` | Kennung des schreibenden Programms; Pflicht für neue Schreibvorgänge, 1–120 Zeichen wie Lookup |
| `created_by` | Auslösender Benutzer bzw. Dienstaccount; Pflicht für neue Schreibvorgänge, 1–255 Zeichen, nicht nur Leerraum |

CCI-UI setzt `client: "cci-ui"` fest im Uploadpfad und übernimmt `created_by`
aus der angemeldeten Identität. Andere Programme setzen eine eigene stabile
Kennung, etwa `acme-renewer` oder `inventory-import`. Eine reine Leseanfrage,
beispielsweise durch Puppet, verändert den Urheber nicht. Aktivieren einer
älteren Version verändert ebenfalls nicht ihre Herkunft.

Dies ist eine additive Erweiterung von Schema `"1"`; Namespace, ID-Berechnung
und Verschlüsselung bleiben gleich. Bestehende Leser können zusätzliche Felder
ignorieren. Alte Versionen ohne Herkunft bleiben lesbar und erscheinen als
„Unbekannt (keine Client-Angabe)“. Aus dem Speicherort Consul lässt sich kein
Client ableiten. Dateibestand wird separat als solcher angezeigt. Neue Clients
müssen die Herkunft mitschreiben; Consul selbst erzwingt kein JSON-Schema.

Die Angaben sind Selbstauskünfte des schreibenden Clients, kein kryptografischer
Urhebernachweis. Der Client ist außerdem vom X.509-Aussteller (`issuer`) zu
unterscheiden. Schreibrechte und die Zuordnung der ACL-Tokens bleiben maßgeblich.

### Privater Schlüssel

```json
{ "version": 1, "iv": "<base64>", "tag": "<base64>", "data": "<base64>" }
```

`version` ist hier eine **Zahl**, anders als `schema` im Zertifikatsobjekt.
Verschlüsselt wird der private PEM-Schlüssel mit AES-256-GCM, einem frischen
12-Byte-IV und dem 32-Byte-Bereichsschlüssel. Der Authentifizierungstag hat
16 Bytes. AAD ist exakt `cci:v1:<area>:<version_id>`, auch bei abweichendem
`CONSUL_PREFIX`. Private Schlüssel gehören nie in das öffentliche Versionsobjekt.

### Transaktion und Audit

Zuerst den Lookup konsistent lesen. Beim ersten Import UUID erzeugen; bei
Erneuerung die vorhandene `entry_id` wiederverwenden. In einer Transaktion:

1. Lookup mit `cas` und seinem bisherigen `ModifyIndex` schreiben; bei einem
   neuen Lookup `Index: 0` verwenden. `active_version` auf die neue ID setzen.
2. Version mit `cas`, `Index: 0` anlegen; bestehende Versionen nie überschreiben.
3. Optional den Schlüsselumschlag ebenfalls mit `cas`, `Index: 0` anlegen.
4. Audit-Ereignis mit neuer UUID anlegen.

Bei HTTP 409 wird die gesamte Transaktion verworfen. Erneut lesen und fachlich
entscheiden; niemals mit einem bedingungslosen Schreibzugriff überschreiben.
Gleiches Zertifikat unter gleichem Lookup ist ein Duplikat; für eine Erneuerung
wird ein neues Zertifikat benötigt. Werte dürfen höchstens 512 KiB groß sein;
eine Transaktion umfasst höchstens 64 Operationen.

Audit-Felder: `action` (`import`, `activate`, `delete`), `area`, `id` (Versions-ID),
`actor` (handelnder Benutzer), `at` (ISO 8601), `details` (JSON-Objekt).
Bei Import enthält `details` die vorherige `previous_version` oder `null`,
`tags` als Array, `has_key` als Boolean und `certificates` als Array von
Snapshots (`common_name`, `subject`, `issuer`, `serial`, `fingerprint`, `source`,
`source_id`, `lookup`, `kind`). Das ausführbare Beispiel zeigt diese Struktur.

## Ruby-Beispiele

[examples/add_certificate.rb](../examples/add_certificate.rb) funktioniert ohne
Rails und ohne zusätzliche Gems. Es verwendet die Standardbibliothek und
[lib/consul_connection.rb](../lib/consul_connection.rb). Beide Dateien können mit
derselben relativen Verzeichnisstruktur in einen externen Client übernommen
werden. Zugangsdaten und Bereichsschlüssel über die Laufzeitumgebung bereitstellen.

```bash
export CONSUL_URL=https://consul.example.test:8501
export CONSUL_PREFIX=cci/v1
export CCI_CLIENT_ID=acme-renewer
export CCI_ACTOR=svc-acme
# CONSUL_TOKEN und optional ZONE_A_KEY / KEY_PASSWORD aus Secret-Verwaltung setzen.
ruby examples/add_certificate.rb zone_a portal.production certificate.pem
# Mit privatem Schlüssel:
ruby examples/add_certificate.rb zone_a portal.production renewed.pem private-key.pem
```

Mit Kette und Tags aus eigenem Ruby-Code:

```ruby
require_relative "examples/add_certificate"

version_id = CertificateExample.add(
  area: "zone_a", lookup: "portal.production",
  cert: OpenSSL::X509::Certificate.new(File.binread("certificate.pem")),
  chain: [OpenSSL::X509::Certificate.new(File.binread("issuer.pem"))],
  tags: ["Produktion", "ACME"], client: "acme-renewer", actor: "svc-acme"
)
puts version_id
```

Innerhalb der Rails-Anwendung kann ein eigener Importer stattdessen
`ConsulStore.save(area:, cert:, key:, chain:, tags:, lookup:, actor:, client:)`
aufrufen. `client:` ist ausdrücklich erforderlich und hat keinen UI-Standardwert.
`CciClient#fetch(..., field: "metadata")` liefert die Herkunft auch an Puppet bzw.
andere lesende Ruby-Clients, sofern sie in der Version vorhanden ist.
