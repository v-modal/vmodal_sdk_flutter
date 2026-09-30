----------------------------------------------------------
date: 2026-09-27
origin_commit: pending
title: Flutter SDK v1.2.3 Dartdoc package archive repair
summary:
  - Reissued the package with explicit public `lib/` include rules so pub.dev's archive retains the Dart entrypoint for dartdoc.
  - Added a regression assertion for the library include rules and release guidance that requires the package dry-run to list the entrypoint.
