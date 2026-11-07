# Repository audit — 2026-11-07

## Working baseline and comparison with main

- Main/work: `21997b92525a9bc91e55d4d12a4476d6da5fc90c`, app **0.8.12+22**.
- Working 0.9.1: `a5e51aa44e59a4ff5d01dedfb83a70c53c126aa7`, app **0.9.1+29**.
  Main is its ancestor: **0 main-only / 59 baseline-only commits**.
  The tree comparison has **155 files, +19,484 / −658 lines**.
- Retained follow-ups through `63ad4e7430b7c59b3f7982aa41a86dbda41019b0`:
  three commits changing only the personal runtime probe and its workflow setup.
  They choose annotated documents, format the test and use the existing Windows
  PowerShell SDK setup. No production app behavior changes in these follow-ups.
- This PR starts from that history, preserving all original commits. It does not
  restore main's older source over the working reader.

The 59 baseline commits include Android EPUB recovery/composition work, reader
layout/curl corrections, 0.8.13–0.8.17 candidates, the Kindle prototype and its
integration, 0.9.0/0.9.1 fixes, and corresponding tests/delivery tools. Thus this
PR contains the working app changes missing from main as well as organization.
Review the organization separately from the already functioning baseline:

```sh
git log --oneline 21997b9..a5e51aa
git diff --stat 21997b9 a5e51aa
git diff a5e51aa 63ad4e7
git diff 63ad4e7 HEAD
```

The reorganization keeps app/native source paths, Flutter dependency locks,
third-party plugin patches, package IDs, version/build and signing configuration.
The shared Python package has corrected documentation and packaging checks;
it remains an app dependency. See [the dependency map](KINDLE_RUNTIME.md).

## Organization and workflows

- Current setup/test/distribution guides are linked from README and
  [the documentation index](README.md). Historical evidence stays versioned.
- Superseded Kindle research, standalone user/release documents and two browser
  experiments move with Git rename history into `archive/`. Runtime Python,
  launchers, migration paths, probes and corresponding-source tooling stay active.
- The former `kindle-prototype.yml` is preserved outside `.github/workflows`.
  Its separate automatic build/release pipeline is retired. The active app CI
  owns Linux protocol/browser/prepared import checks, Windows protocol tests,
  frozen worker self-checks and app bundling through one build script.
- The three required CI job names and exact-source publication/signature gates
  remain intact. Device/account diagnostics remain manual/reusable. This PR
  does not dispatch personal-account or physical-device workflows.
- Android release instructions now use sequential `--target-platform` builds;
  `--split-per-abi` conflicts with Chaquopy's explicit ABI filters.

## Retention inventory presented before any deletion

The [complete JSON snapshot](inventory/repository-before-2026-11-07.json) records
**6 remote branches, 22 existing Git tags, 42 releases (20 draft / 22 published)
and 166 assets** before creating the cleanup branch. Every item is marked
`retain`. Each asset has its ID, exact name, size, uploaded state, SHA256 digest
when supplied by GitHub, and download URL. Release source, draft status, IDs and
URLs are recorded too. The snapshot is dated; re-read remote state before any
future deletion. Local working branches/builds and private signing files are
preserved; they are not candidates for cleanup.

| Existing remote branch | Commit | Behind / ahead of main | Action |
|---|---|---:|---|
| `codex/native-epub-diagnostics-081` | `8a4db52d72fb2ad529485f62a0df3283a814c388` | 76 / 2 | Retain |
| `codex/native-epub-post-turn-081` | `68cfb4404316f701660c5eee2d45cee15f659f52` | 74 / 1 | Retain |
| `codex/windows-capture-interval` | `94dd447c8d33e15fa2e9376ccea597509656fbbe` | 17 / 2 | Retain |
| `fix/android-epub-recovery` | `63ad4e7430b7c59b3f7982aa41a86dbda41019b0` | 0 / 62 | Retain |
| `main` | `21997b92525a9bc91e55d4d12a4476d6da5fc90c` | 0 / 0 | Retain |
| `work` | `21997b92525a9bc91e55d4d12a4476d6da5fc90c` | 0 / 0 | Retain |

The three older diagnostic branches contain unique Git commits; equivalent
patches have not been established. The recovery branch contains the 0.9.1
history and later diagnostic fixes. No branch deletion is proposed.
Draft release names are not necessarily existing Git tags: the 0.9.1 draft
points directly to its source SHA. Do not infer tag coverage from a release name.

| Existing release | Source | State | Assets | Action |
|---|---|---|---:|---|
| `v0.9.1-epub-candidate.1` | `a5e51aa44e59a4ff5d01dedfb83a70c53c126aa7` | Draft | 5 | Retain |
| `v0.9.0-epub-candidate.1` | `2877d50ed932927d6e01eba6ff2ecb154671c58d` | Draft | 5 | Retain |
| `kindle-personal-prototype-v0.3.1` | `dbff418fc7f9d17157975924422e7df00fd15fa8` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.3.0` | `ce8f83d3f69e5b334ad2e8fd2d2a3f804263a2bb` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.2.3` | `49b9366ea5299767f62101aa4747fcfe2ce60822` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.2.2` | `02e8fe5209943e3bfaad933530141edb5f3aa036` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.2.1` | `7464fe219a9a1955c1a07c8db5a16a0778954fc3` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.2.0` | `76d58bbd621c3925c5055a8b7036aa885e03d7df` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.1.6` | `b432342d0f49d17e50c3996ecdc19185c3fed8df` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.1.5` | `55e74e9d0de3192bff96b5b83631be01c9d3a1da` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.1.4` | `f506c88f5f2f426f99925fc0aa53c338c978396c` | Draft | 3 | Retain |
| `kindle-personal-prototype-v0.1.3` | `bce44a941da6543899b77e2347fa06cfd964acd2` | Draft | 2 | Retain |
| `kindle-personal-prototype-v0.1.2` | `ad2819812250c1878c5d41a3d90c5ea6b8df1e6a` | Draft | 2 | Retain |
| `kindle-personal-prototype-v0.1.1` | `41ec50fd596723a68f7e1ac960cfffc7030d1b09` | Draft | 2 | Retain |
| `v0.8.17-epub-candidate.1` | `23f410c2175d307585fa47b84e83f36be543648d` | Draft | 5 | Retain |
| `v0.8.16-epub-candidate.1` | `d4c495e39ae83cd9701b4576b9987b2ede850503` | Draft | 5 | Retain |
| `v0.8.15-epub-candidate.1` | `0d42ce3da7ce719b59faca4a6a813626551d3b24` | Draft | 5 | Retain |
| `v0.8.14-epub-candidate.1` | `05ec4772dbddf5c50fa3d555353e2ed887624df6` | Draft | 5 | Retain |
| `v0.8.13-epub-candidate.1` | `8b84da08f5853e03ea40e5b244958795f1326c41` | Draft | 5 | Retain |
| `kindle-personal-prototype-v0.1.0` | `c13b43d915855b1d45d77b0ec4c7fa255e1d0360` | Draft | 2 | Retain |
| `v0.8.12-preview.1` | `da6545fe21941f036db784b5538ed85aaad2c88d` | Published preview | 5 | Retain |
| `v0.8.11-preview.1` | `f4f0d806d83471c3cecf61cfdf9bb3f17132bb04` | Published preview | 5 | Retain |
| `v0.8.10-preview.1` | `22b3d13541257da7b91952267494e58664e6427d` | Published preview | 5 | Retain |
| `v0.8.9-preview.1` | `bc785e1f6b1f541473f2ea8b1deda1fd6f7856e5` | Published preview | 5 | Retain |
| `v0.8.8-preview.1` | `82881fda76ecc653e7dc027cced65114d23af040` | Published preview | 5 | Retain |
| `v0.8.7-preview.1` | `20641b8b95e4028587bedb5fdf60be99d655c392` | Published preview | 5 | Retain |
| `v0.8.6-preview.1` | `3d04cd82715a768f0b05c4ec328b46cfd1a24a6b` | Published preview | 5 | Retain |
| `v0.8.5-preview.1` | `0628968e2ad2dc80856ae017caf307fa2bdbca7e` | Published preview | 5 | Retain |
| `v0.8.4-preview.1` | `469ea3a6a8f6bd24c31d7c5ca1e3f850ba8a5995` | Published preview | 5 | Retain |
| `v0.8.3-preview.1` | `43bc0e127aa8c7392482817ceacd4115e0980416` | Published preview | 5 | Retain |
| `v0.8.2-preview.1` | `1bb75274855204c554a48122af281e28b6661670` | Published preview | 5 | Retain |
| `v0.8.1-preview.1` | `3aaeafc32f13c8b6469806d26d970f86f02ea998` | Published preview | 5 | Retain |
| `v0.8.0-preview.1` | `eb40fbddb6452ea124f7f17e0a4d72581d0ba55b` | Published preview | 5 | Retain |
| `v0.7.0-preview.1` | `4041b8ca631f4113c6d9f81c8c6fccbc851b4ef8` | Published preview | 5 | Retain |
| `v0.6.1-preview.1` | `e94e45ef58d74ead79bcdcf91a58cce03ae9b7f4` | Published preview | 5 | Retain |
| `v0.6.0-preview.1` | `98c42f7ea84d732e7079df795dc26b97caabd0fc` | Published preview | 5 | Retain |
| `v0.5.0-preview.1` | `d95a360f48d3045dc133458f19f3b539715cd19a` | Published preview | 3 | Retain |
| `v0.4.1-preview.1` | `9332ee4bf67fcfa11db645b3941b4c5ae03c15a1` | Published preview | 3 | Retain |
| `v0.4.0-preview.1` | `f23eaa42ec5713df1ce4f66d03c0124c9817690e` | Published preview | 3 | Retain |
| `v0.3.0-preview.1` | `77a5786fb19c173e7925b6a64e5d424ffb843eb3` | Published preview | 3 | Retain |
| `v0.2.0-preview.1` | `fc5b32be6c613eb936696134cb598b40037f950b` | Published preview | 2 | Retain |
| `v0.1.0-dev.1` | `39988b1c7e279b0c9c76038bd3b5ffa6211e431b` | Published preview | 2 | Retain |

The 0.9.1 draft (release ID **437138822**) contains all three signed APKs,
the portable Windows bundle and `SHA256SUMS.txt`. Its exact asset identities and
digests are in the inventory. The latest published preview is 0.8.12. This PR
neither publishes nor replaces a release and does not move/delete tags.

## Verification and limits

The 0.9.1 baseline passed all three native/build jobs in
[CI 42307062098](https://github.com/LeValue/KMReader-Porting/actions/runs/42307062098),
plus [Windows diagnostics 42308712643](https://github.com/LeValue/KMReader-Porting/actions/runs/42308712643).
These runs verify the named baseline, not future commits. Current cleanup
validation is recorded at the top of [VALIDATION.md](VALIDATION.md) and in the
PR checks. Linux cannot build or interactively verify native Windows binaries;
Windows/emulator verification belongs to the hosted CI for this PR.

Private Android signing files are ignored and are checked for unchanged hashes
locally without exposing values. The expected public certificate pin and signing
logic are preserved. Existing ignored `build/` and `artifacts/` outputs remain
available; no clean/prune or deletion of previous build products is performed.
Any new local build uses normal generated build paths and retains its APK in a
separate ignored validation directory. Published/baseline assets remain intact.
