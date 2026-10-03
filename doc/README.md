# Flutter SDK documentation

For an existing Android/iOS app, start with
[Choose authentication](authentication.md), then
[Flutter app integration recipes](component_patterns.md). They cover API choice,
host activation, a complete search controller/widget, upload progress, index
polling, recovery, storage, mobile lifecycle, and host acceptance tests.

| Reading path | Guide |
| --- | --- |
| Direct keys, local user isolation, or server-enforced scoped tokens | [Choose authentication](authentication.md) |
| Backend endpoint, exact grants, renewal, errors and rollout | [Backend authentication](auth_user_backend_mode.md) |
| Ready-to-use production integration patterns | [Component patterns](component_patterns.md) |
| Concise tenant-scoped API orientation | [SDK guide](sdk_doc.md) |
| Exact sessions, permissions, provenance, storage, and response semantics | [SDK contract](sdk_contract.md) |
| Tenant rotation and app-user identity transitions | [Manage API keys](manage_api_key.md) |
| Component relationships and sequences | [Diagrams](diagrams.md) |
| Advanced tenant-scoped search/image implementation | [Search app](search_app.md) |
| Streaming, concurrency, timeouts, and device measurement | [Performance](performance.md) |
| Tenant-scoped custom video reducer | [Transcode](transcode_360.md) |
| Complete session app and host adapter injection | [Framebase example](../example/05_framebase_userlogin/README.md) |
| Separate scoped callback and verified-identity backend reference | [Backend-auth reference](../example/06_userlogin_backend_auth/README.md) |
| SDK maintainer publication and export | [Release](release.md) |

Session recipes require the 1.3.0 APIs present in this source tree. Use the local
dependency instructions in the recipes for reproduction; verify a public
artifact before choosing a production pin. Older 1.2.3 installation examples
refer to the earlier tenant-scoped API.

Authored guides live in `docs/`. Generated Dart API reference lives in `doc/`
and is published separately at [the SDK reference site](https://v-modal.github.io/vmodal_sdk_flutter/).
Internal planning notes are excluded from the standalone source export.
