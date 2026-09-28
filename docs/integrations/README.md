# Integrations

CCI exposes narrowly scoped integration endpoints and ships matching monitoring
configuration. Integrations are disabled by default and configured through the
deployment environment.

- [Zabbix certificate monitoring](zabbix.md): bearer-authenticated inventory,
  automatic discovery and expiration alerts for Zabbix 7.4.5.

Certificate distribution and inventory enrichment are covered separately in the
[Puppet](../puppet.md) and [PuppetDB](../puppetdb.md) documentation.
