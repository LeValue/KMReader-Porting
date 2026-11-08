# Historical experiments

These files preserve earlier design work and reproduction tools. They are not
the current development or distribution procedure. Start with
[the documentation index](../docs/README.md).

| Path | Purpose | Status |
|---|---|---|
| `docs/parity-before-closure-plan-2026-11-07.md` | Previous parity matrix and versioned implementation checkpoints | Historical snapshot; active closure plan is in `docs/PARITY.md` |
| `kindle-prototype/` | Standalone Amazon.it prototype guide, release notes, feasibility research and former workflow | Superseded by the integrated app in 0.9.x |
| `epub/epub_range_feasibility.py` | Generated EPUB over lazy ZIP/HTTP Range | Research proof, not the app's Kindle transport |
| `epub/epub_pipeline_benchmark.py` | 0.8.13 browser task/pipeline measurements | Historical benchmark, not native display FPS |
| `experiments/kindle-web-import/` | First-party web STK source and test snapshots | Authenticated GETs passed, POSTs redirected to sign-in; excluded from the app after the native registration fix passed |

Run archived Python tools from the repository root, for example
`python archive/epub/epub_range_feasibility.py --help`.
The archived YAML is reference material outside `.github/workflows`; it cannot
trigger Actions or create a release. Its build recipe is superseded by
`tool/build_kindle_worker.ps1`, called by `ci.yml`.

Shared Python modules, entry points, launchers, packaging and probes remain in
`tool/`: the app still uses them. See the
[Kindle dependency inventory](../docs/KINDLE_RUNTIME.md).
No branches, tags, releases, assets, local builds or Android signing files were
deleted as part of this archive.
