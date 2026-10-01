----------------------------------------------------------
date: 2026-10-02
origin_commit: e02e2e15a2d2eb6af43125e89dc4e5bef904ce20
title: Flutter SDK v1.3.0 app-user session isolation
summary:
  - Added an opt-in session interface for applications sharing a tenant API key across app users.
  - Guarded stale network work and isolated local owner namespaces while preserving tenant-scoped API compatibility.
  - Kept tenant key rotation independent of host login and account switching.
