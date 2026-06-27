# UDM Network App modernization — Integration API + API-key auth

## Status: scoping doc (M47), 2026-05-26

This is the research output for [outstanding-work M47](../../planning/outstanding-work.md#-m47-udm-network-app-modernization--api-key--integration-api).
It scopes how to migrate `infra/ansible/playbooks/udm-firewall.yml` off the
username/password + cookie + CSRF login dance onto the official UniFi
**Integration API** (`/proxy/network/integration/v1/...`) with an
`X-API-Key` header, against the UDM running UniFi Network Application
≥10.1.84.

**Bottom line:** swap auth everywhere, migrate the two endpoints that
have a clean Integration equivalent (sites + firewall policies), and
keep the other two (firewall zones discovery, firewall groups CRUD) on
the legacy paths with the new auth header. Both APIs are documented to
keep coexisting on the same controller.

## TL;DR coverage table

| Resource | Integration API? | Recommended action |
|---|---|---|
| Auth (`POST /api/auth/login`) | n/a — replaced by `X-API-Key` header | **Migrate.** Delete the login + CSRF tasks; inject header on every uri{}. |
| Sites listing | `GET /proxy/network/integration/v1/sites` | **Optional.** Lets us resolve `udm_site` (currently hard-coded `default`) to its Integration-API UUID. |
| Firewall zones | **No** Integration API equivalent (zones are read-only in the official spec; only `/v2/api/.../firewall/zone` returns the structure we need) | **Stay on legacy.** Keep `GET /proxy/network/v2/api/site/{site}/firewall/zone`, just add `X-API-Key` header. |
| Firewall policies (zone-based) | `GET /v1/sites/{site}/firewall/policies` + `PATCH /v1/sites/{site}/firewall/policies/{id}` | **Partial.** GET + enable/disable migrate cleanly. POST/PUT (full create/update) coverage is still community-reported as patchy; safest path is GET on integration, create/update on legacy `/v2/api/.../firewall-policies`. |
| Firewall groups (address-group / port-group) | **No direct equivalent.** The closest is `traffic-matching-lists` under `/v1/sites/{site}/traffic-matching-lists` (types `IPV4_ADDRESSES`, `IPV6_ADDRESSES`, `PORTS`), but it's a *new* resource type, not the same as the legacy `firewallgroup` records consumed by `firewall-policies.ip_group_id` / `port_group_id`. | **Stay on legacy.** Keep `/proxy/network/api/s/{site}/rest/firewallgroup` GET/POST/PUT. Re-evaluate once Ubiquiti aligns the two type systems (probably late-2026 per their "write scope rollout through 2026" note). |
| Networks (VLANs) | `GET/POST/PUT/DELETE /v1/sites/{site}/networks` | Not used by udm-firewall.yml, but tee'd up for future playbooks. |
| Devices / clients | `GET /v1/sites/{site}/devices`, `/clients` (read-only) | Not used today. |
| Port forwards, traffic rules, static routes, RADIUS, DNS policies, VPN, port profiles, QoS, NAT | **No Integration API.** | Future playbooks must use the legacy `/proxy/network/api/s/{site}/...` paths. |

## Auth migration

### Today (cookie + CSRF dance)

```yaml
- name: UDM login
  ansible.builtin.uri:
    url: "{{ udm_base }}/api/auth/login"
    method: POST
    body: { username: "{{ udm_username }}", password: "{{ udm_password }}" }
  register: udm_login

- name: Build common auth headers
  ansible.builtin.set_fact:
    udm_headers:
      Cookie: "TOKEN={{ udm_token }}"
      X-Csrf-Token: "{{ udm_csrf }}"
      Content-Type: application/json
```

Drawbacks: short-lived session, can't be rotated by an external IdP,
CSRF token capture is fiddly across Ansible versions, and the `tf-admin`
1P item carries a full username/password pair.

### After (API key header)

```yaml
- name: Fetch UDM API key from 1Password
  ansible.builtin.command:
    argv: [op, item, get, unifi-udm-api, --fields, credential, --reveal]
  register: udm_api_key_op
  changed_when: false
  no_log: true

- name: Build common auth headers
  ansible.builtin.set_fact:
    udm_headers:
      X-API-Key: "{{ udm_api_key_op.stdout | trim }}"
      Content-Type: application/json
  no_log: true
```

Drop the `UDM login`, `Extract TOKEN cookie + CSRF`, and
`Sanity-check session captured` tasks entirely. Every existing `uri:`
task already references `headers: "{{ udm_headers }}"`, so no changes
there beyond the header dict.

Key generation: UniFi Network UI → Control Plane → Admins & Users → tab
*Admins* → pick the admin to act as → **Create API Key**. Store the
key value in 1P item `unifi-udm-api` field `credential` (API Credential
category). Long-lived; rotate by creating a new key and deleting the
old. No MFA prompts on use.

For CI, mirror as GH Actions secret `UNIFI_UDM_API_KEY` and inject via
`ansible-playbook -e udm_api_key="${UNIFI_UDM_API_KEY}"`.

## Per-endpoint migration plan

### 1. Sites (cosmetic, optional)

Today: `udm_site: default` is a hard-coded string used directly in the
legacy path segments (`/s/default/...`).

Integration API has `GET /proxy/network/integration/v1/sites`, which
returns each site with both a new UUID (`id`) and the legacy short name
(`internalReference`). For a single-site UDM, the cost/benefit of
discovering this dynamically is low; recommendation = **leave as-is**
unless we add a second site.

### 2. Firewall zones (stay on legacy)

Integration API does not expose zone CRUD or a zone listing endpoint as
of UniFi Network 10.1.x. The `udm-firewall.yml` playbook only *reads*
zones (`GET /proxy/network/v2/api/site/{site}/firewall/zone`) to resolve
`zone_name → zone_id`. That call works fine with `X-API-Key` —
nothing to migrate, just drop the cookie/CSRF headers.

### 3. Firewall groups (stay on legacy)

Integration API has `/v1/sites/{site}/traffic-matching-lists` (PORTS /
IPV4_ADDRESSES / IPV6_ADDRESSES). However, the `firewall-policies`
endpoint we use to attach groups still references the **legacy**
firewallgroup object IDs via `ip_group_id` and `port_group_id`. Until
Ubiquiti unifies the two type systems, traffic-matching-lists is a
parallel resource, not a drop-in replacement.

**Action:** keep `/proxy/network/api/s/{site}/rest/firewallgroup` for
GET/POST/PUT of address-groups and port-groups, with `X-API-Key`.
Revisit when (a) UniFi Network release notes show `firewall-policies`
accepting `traffic_matching_list_id`, or (b) zone-based firewall is
fully exposed in Integration v1 with write scope.

### 4. Firewall policies (partial migration)

| Legacy call | Integration API | Recommendation |
|---|---|---|
| `GET /proxy/network/v2/api/site/{site}/firewall-policies` | `GET /proxy/network/integration/v1/sites/{site}/firewall/policies` (paginated, `offset` + `limit`) | Migrate — but the response shape changes (paginated wrapper). Be prepared to handle the wrapper in the `udm_policy_id_by_name` builder. |
| `POST /proxy/network/v2/api/site/{site}/firewall-policies` (create) | Not reliably exposed in v1 yet (community reports patchy POST/PUT coverage; UniFi notes "write scope rollout through 2026") | **Stay on legacy** for create. |
| `PUT /proxy/network/v2/api/site/{site}/firewall-policies/{id}` (full update — not used today, we only create) | n/a today | n/a |
| Enable/disable existing policy | `PATCH /proxy/network/integration/v1/sites/{site}/firewall/policies/{id}` | Available if we ever add an enable/disable task. |

Pragmatic interim: keep the entire firewall-policies block on the
legacy `v2/api` path with the new header. Saves having to translate the
paginated wrapper for marginal benefit on a playbook that creates ~1
rule. Migrate to Integration GET only once we have ≥10 policies and
need pagination semantics anyway.

## What to do first (recommended order)

1. **Create the UDM API key.** UniFi UI path above; store in 1P as
   `unifi-udm-api` (field `credential`). Done already per user.
2. **Add `UNIFI_UDM_API_KEY` to `secrets.sops.yml`** (group_vars/all)
   so non-laptop runs (CI, gh-runner) can read it.
3. **Refactor auth in `udm-firewall.yml`:** delete the 3 login tasks
   and the `op item get` of `UDM (tf-admin)`. Replace with the
   `op item get unifi-udm-api --fields credential --reveal` pattern.
   Set `udm_headers = { X-API-Key, Content-Type }`. Run `--check
   --diff` against the UDM to confirm every existing `uri:` task still
   returns 200 with just the header.
4. **Leave URL paths alone for now.** The four endpoint patterns
   (`/v2/api/.../firewall/zone`, `/api/s/.../rest/firewallgroup`,
   `/v2/api/.../firewall-policies` GET, same POST) all continue to
   work with the new header; the legacy API isn't deprecated.
5. **Defer Integration-path migration** to a follow-up once Ubiquiti's
   v1 firewall-policies POST/PUT lands. Track via UniFi Network release
   notes ≥10.2.x.

## Acceptance criteria for the M47 commit

- `udm-firewall.yml` no longer references the `UDM (tf-admin)` 1P item,
  `udm_username`, `udm_password`, `udm_token`, `udm_csrf`, or
  `/api/auth/login`.
- `ansible-playbook playbooks/udm-firewall.yml --check --diff` succeeds
  with only the API key in the environment (no username/password).
- `secrets.sops.yml` carries `udm_api_key` (or path equivalent).
- GH Actions workflow that invokes the playbook reads
  `UNIFI_UDM_API_KEY` from secrets.
- The four endpoint paths above are unchanged (legacy paths retained).

## Sources

- Ubiquiti Help Center, [Getting Started with the Official UniFi API](https://help.ui.com/hc/en-us/articles/30076656117655-Getting-Started-with-the-Official-UniFi-API) — auth header, minimum version 10.1.84, where to generate keys, scope rollout note ("write scope rollout through 2026").
- UniFi Developer Portal, [Network API ≥10.1.84](https://developer.ui.com/network/v10.1.84/quick_start) — base path `/proxy/network/integration/v1`, OpenAPI spec at `/proxy/network/api-docs/integration.json`.
- UniFi Developer Portal, [GET firewall policy ordering](https://developer.ui.com/network/v10.1.84/getfirewallpolicyordering) — confirms `firewall/policies/ordering` shape under Integration v1.
- DeepWiki, [enuno/unifi-mcp-server: Zone-Based Firewall](https://deepwiki.com/enuno/unifi-mcp-server/5.5-zone-based-firewall) and [Zone-Based Firewall Tools](https://deepwiki.com/enuno/unifi-mcp-server/5.5-zone-based-firewall-tools) — observed-in-the-wild endpoint inventory and the "87% of ZBF endpoints do not exist in the actual UniFi API" caveat.
- Art of WiFi, [UniFi API Authentication: Local Admin vs. API Key vs. Site Manager](https://artofwifi.net/blog/unifi-api-authentication-local-admin-vs-api-key-vs-site-manager) — API-key vs. session-cookie tradeoffs (long-lived, no MFA, no rotation churn).
- Art of WiFi, [UniFi Network Application API Client](https://artofwifi.net/unifi-network-application-api-client) — coverage list ("sites, devices, connected clients, networks, WiFi broadcasts, hotspot vouchers, firewall zones and policies, ACL rules, DNS policies") and explicit "broader coverage in our legacy client" gap note.
- trtmn, [agent-skills/unifi-api/SKILL.md](https://github.com/trtmn/agent-skills/blob/main/unifi-api/SKILL.md) — concrete endpoint table including `/sites/{SITE}/firewall/policies` (GET, PATCH), `/sites/{SITE}/firewall/zones` (GET), networks/devices/clients paths, and a "Critical Gaps (404s on UDR-7)" list (WiFi broadcasts, DNS policies, VPN tunnels, port-forward, RADIUS, DPI, traffic stats).
- Local memory: [reference_udm_zone_policy_api.md](../../../.claude/projects/-Users-grahamsmith-code-infra/memory/reference_udm_zone_policy_api.md) — why paultyng/unifi Terraform provider is broken on UniFi 10+ and why this playbook drives the API directly.
