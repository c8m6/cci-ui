#!/usr/bin/env python3
"""Exercise the real 7.4.5 import and discovery engine in the disposable stack.

Run only with script/zabbix/compose.yml. Credentials and certificates are synthetic.
Uses Python's standard library. No production Zabbix connection is supported.
"""

import json
import pathlib
import subprocess
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPOSE = ["docker", "compose", "-f", str(ROOT / "script/zabbix/compose.yml")]
TOKEN = None


def api(method, params):
    headers = {"Content-Type": "application/json-rpc"}
    if TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    request = urllib.request.Request(
        "http://127.0.0.1:18074/api_jsonrpc.php",
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers,
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(result["error"])
    return result["result"]


def wait_for(description, check, timeout=150):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            print("PASS:", description, flush=True)
            return result
        time.sleep(3)
    raise AssertionError("Timed out: " + description)


def mode(value):
    subprocess.run(COMPOSE + ["exec", "-T", "fixture", "ruby", "-e",
                             'File.write("/tmp/mode", ARGV.fetch(0))', value], check=True)


def main():
    global TOKEN
    assert api("apiinfo.version", {}) == "7.4.5"
    TOKEN = api("user.login", {"username": "Admin", "password": "zabbix"})
    rules = {name: {"createMissing": True, "updateExisting": True}
             for name in ["templates", "items", "discoveryRules", "triggers"]}
    rules["template_groups"] = {"createMissing": True}
    assert api("configuration.import", {
        "format": "yaml", "source": (ROOT / "integrations/zabbix/cci-certificates.yaml").read_text(),
        "rules": rules,
    })
    print("PASS: complete YAML imported into Zabbix 7.4.5", flush=True)
    template = api("template.get", {"filter": {"host": ["CCI Certificates"]},
                                    "selectMacros": "extend"})[0]
    secret = next(m for m in template["macros"] if m["macro"] == "{$CCI.ZABBIX.TOKEN}")
    assert secret["type"] == "1"
    old = api("host.get", {"filter": {"host": ["CCI integration demonstration"]}})
    if old:
        api("host.delete", [entry["hostid"] for entry in old])
    groups = api("hostgroup.get", {"filter": {"name": ["CCI isolated validation"]}})
    group = groups[0]["groupid"] if groups else api("hostgroup.create", {
        "name": "CCI isolated validation"})["groupids"][0]
    host = api("host.create", {
        "host": "CCI integration demonstration", "groups": [{"groupid": group}],
        "templates": [{"templateid": template["templateid"]}],
        "macros": [{"macro": "{$CCI.URL}", "value": "http://fixture:3000"},
                   {"macro": "{$CCI.ZABBIX.TOKEN}", "value": "synthetic-zabbix-test-token", "type": 1}],
    })["hostids"][0]
    items = api("item.get", {"hostids": [host], "output": "extend"})
    master = next(i for i in items if i["key_"] == "cci.certificates.raw")
    assert master["type"] == "19" and master["delay"] == "1h"
    assert master["verify_peer"] == master["verify_host"] == "1"
    assert master["follow_redirects"] == "0"
    assert master["status_codes"] == "200"
    # Accelerate this disposable host only. The shipped template remains hourly.
    api("item.update", {"itemid": master["itemid"], "delay": "5s"})
    discovery = api("discoveryrule.get", {"hostids": [host], "output": "extend",
                                         "selectLLDMacroPaths": "extend", "selectOverrides": "extend"})[0]
    assert discovery["type"] == "18" and discovery["master_itemid"] == master["itemid"]
    assert discovery["lifetime"] == "30d" and discovery["enabled_lifetime"] == "1d"
    assert len(discovery["lld_macro_paths"]) == 4 and len(discovery["overrides"]) == 2

    def collected():
        values = api("item.get", {"hostids": [host], "filter": {"flags": 4},
                                  "output": ["key_", "state", "error", "lastclock", "lastvalue"]})
        return values if len(values) == 35 and all(i["state"] == "0" and int(i["lastclock"]) > 0 for i in values) else None

    mode("valid")
    values = wait_for("35 dependent items have valid values", collected)
    by_key = {i["key_"]: i["lastvalue"] for i in values}
    assert by_key["cci.cert.renewal[4]"] == "acme"
    assert by_key["cci.cert.renewal[6]"] == "puppet"
    assert int(by_key["cci.cert.valid_until[1]"]) > int(time.time())

    def expiration_problems():
        triggers = api("trigger.get", {"hostids": [host], "filter": {"flags": 4},
                                       "output": ["description", "value", "priority", "error"], "selectTags": "extend"})
        active = [t for t in triggers if t["value"] == "1"]
        if len(triggers) != 21 or len(active) != 6:
            return False
        actual = {}
        for trigger in active:
            tags = {t["tag"]: t["value"] for t in trigger["tags"]}
            assert tags["source"] == "cci" and tags["component"] == "certificate"
            assert tags["cert_id"] not in actual, "Overlapping expiration problems"
            actual[tags["cert_id"]] = trigger["priority"]
        assert actual == {"1": "2", "2": "4", "3": "5", "4": "2", "5": "4", "6": "5"}
        assert all(not t["error"] for t in triggers)
        return True

    wait_for("LLD overrides and all six exclusive severity bands", expiration_problems)

    def master_state():
        return api("item.get", {"itemids": [master["itemid"]], "output": ["state", "error", "lastclock"]})[0]

    for failure, fragment in [("invalid", "Invalid CCI JSON"), ("schema", "Unsupported CCI schema"),
                              ("stale", "Stale CCI response"), ("unavailable", "503")]:
        mode(failure)
        wait_for(failure + " response rejected", lambda: fragment in " ".join(master_state()["error"].split()))
        # Invalid inventory must not mark previously discovered certificates lost.
        assert len(api("item.get", {"hostids": [host], "filter": {"flags": 4}})) == 35
        mode("valid")
        wait_for("collection recovers", lambda: master_state()["state"] == "0")

    secret = next(m for m in api("usermacro.get", {"hostids": [host], "output": "extend"})
                  if m["macro"] == "{$CCI.ZABBIX.TOKEN}")
    api("usermacro.update", {"hostmacroid": secret["hostmacroid"], "value": "synthetic-invalid-token"})
    wait_for("authentication failure rejected", lambda: "401" in master_state()["error"])
    api("usermacro.update", {"hostmacroid": secret["hostmacroid"], "value": "synthetic-zabbix-test-token"})
    wait_for("authentication recovers", lambda: master_state()["state"] == "0")
    mode("empty")

    def empty_problem():
        return api("trigger.get", {"hostids": [host], "filter": {
            "description": "CCI: Certificate inventory below expectation", "value": 1}})

    wait_for("sudden empty inventory raises Warning", empty_problem)
    mode("valid")
    wait_for("inventory recovery", lambda: not empty_problem())
    print("PASS: validation complete. Demonstration host retained for real UI screenshots.", flush=True)
    print("Lost-resource intervals were imported and checked, not elapsed for 1/30 days.", flush=True)


if __name__ == "__main__":
    main()
