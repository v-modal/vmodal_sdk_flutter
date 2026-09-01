----------------------------------------------------------
date: 2026-09-01
origin_commit: 9ace1fb2ad558d5061b18eb1185cce9af9bd3d9e
title: Flutter SDK v1.2.0 CCTV timestamp and metadata contract
summary:
  - Added caller-selected CCTV video filenames, metadata text, repeated metadata tags, offset-aware start datetimes, and reprocessing options for direct and signed uploads.
  - Preserved the CCTV contract across single, multipart, resumed, bulk, adaptive, and transcoded upload paths, including the original public filename.
  - Added canonical timestamp response accessors for normalized start datetime, UTC epoch milliseconds, and timestamp source.
  - Added metadata-text and absolute-time video search support with timezone validation, paired date bounds, scoped API propagation, and legacy compatibility.
  - Added a compile-checked CCTV example covering authentication, collection and index-job discovery, timestamped upload, index creation, polling, and absolute-time search.
  - Added offline contract, multipart wire, transcode, workflow, and explicit CCTV live tests, plus synchronized documentation and generated Dart reference pages.
  - Released the public Flutter SDK source and documentation after analysis, SDK/example tests, security scanning, package validation, Android/iOS builds, and the production lifecycle passed.
