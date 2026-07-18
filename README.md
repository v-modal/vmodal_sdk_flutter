# VModal Flutter SDK Swagger documentation

This GitHub Pages site is generated from the Flutter SDK route contract by
`../docs.py` and uses the
[peter-evans/swagger-github-pages](https://github.com/peter-evans/swagger-github-pages)
template.

From the `vmx_api` repository root:

```bash
source ./isetup_env.sh
export PYTHONPATH=$(pwd)
python uinterface/sdk_flutter/docs.py generate
python uinterface/sdk_flutter/docs.py check
```

Use `--refresh_ui=True` with `generate` to restore or update the pinned template
files. To preview locally:

```bash
python -m http.server 8000 --directory uinterface/sdk_flutter/docs_swagger
```

Then open `http://localhost:8000`.
