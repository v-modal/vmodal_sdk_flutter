# Flutter SDK reference publication

The generated Flutter SDK class and method reference is published at:

**https://v-modal.github.io/vmodal_sdk_flutter/**

The site is hosted by GitHub Pages from the `gh-pages` branch of
`v-modal/vmodal_sdk_flutter`. Its source is the public Dart API in
`uinterface/sdk_flutter/lib/`; the generated site is stored in this
`docs_sdk/` directory. Do not edit the generated HTML, JavaScript, or index
files by hand. This README is the maintainer note that `docs.py` preserves
when it regenerates the rest of the directory.

## Publish the SDK reference

Publication is handled by the manual GitHub Actions workflow
`.github/workflows/sdk_flutter_test_release.yml`. To publish only the SDK
reference, run this from the monorepo root:

```bash
gh workflow run .github/workflows/sdk_flutter_test_release.yml \
  -f publish_sdk_flutter=false \
  -f publish_pub_dev=false \
  -f publish_sdk_docs_only=true
```

The workflow:

1. Installs the pinned Flutter toolchain.
2. Runs `python uinterface/sdk_flutter/docs.py generate` and `check`.
3. Uploads `docs_sdk/` as an immutable workflow artifact.
4. Replaces the public repository's `gh-pages` branch with that artifact.
5. Enables branch-based GitHub Pages and verifies the deployed `RELEASE_SHA`.

A normal source release also publishes the reference when
`publish_sdk_flutter=true`. Set `publish_pub_dev=true` only when the package
version should also be released to pub.dev.

The workflow requires its configured `GH_TOKEN` secret to write the public
repository and configure GitHub Pages. Do not report the publication as
successful until the `publish_sdk_docs` job passes its deployed SHA check.

## Generate and inspect locally

From the monorepo root:

```bash
./cli.sh flutter docs_generate
./cli.sh flutter docs_check
python -m http.server 8000 --directory uinterface/sdk_flutter/docs_sdk
```

Then open `http://localhost:8000/`. Commit public API comments, generator
changes, this README, and regenerated `docs_sdk/` output together.

## Pre-commit regeneration

Install the repository's pre-commit hook once:

```bash
pre-commit install
```

The local hook in `.pre-commit-config.yaml` runs
`./cli.sh flutter docs_precommit` whenever staged files under
`uinterface/sdk_flutter/` change. It regenerates and verifies the reference. If
the generated tree changes, the hook stops the commit so you can stage
`uinterface/sdk_flutter/docs_sdk/` and commit again.
