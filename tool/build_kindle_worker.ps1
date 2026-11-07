$ErrorActionPreference = 'Stop'
function Check-Exit([string] $Step) { if ($LASTEXITCODE -ne 0) { throw "$Step failed" } }
python -m venv artifacts/kindle-build-env
Check-Exit 'Create build environment'
$python = Join-Path $PWD 'artifacts/kindle-build-env/Scripts/python.exe'
& $python -m pip install -r tool/kindle_personal/requirements.txt pyinstaller==6.22.3
Check-Exit 'Install pinned converter dependencies'
& $python -m unittest discover -s tool/kindle_personal/tests -v
Check-Exit 'Verify shared Kindle protocol and conversion modules'
& $python -m PyInstaller --noconfirm --clean --onedir --name KMReader-Kindle --distpath artifacts/kindle-dist --workpath artifacts/kindle-work --specpath artifacts/kindle-spec --paths tool --collect-all playwright --collect-submodules amazon.ion --collect-all kfxlib --collect-all lxml --collect-all PIL --collect-all bs4 tool/kindle_personal_cli.py
Check-Exit 'Build converter'
& artifacts/kindle-dist/KMReader-Kindle/KMReader-Kindle.exe self-test --browser --output artifacts/kindle-executable-check.json
Check-Exit 'Verify converter and browser callbacks'
if (-not (Test-Path artifacts/kfxlib-source/.git)) {
    git init artifacts/kfxlib-source
    Check-Exit 'Initialize corresponding source'
    git -C artifacts/kfxlib-source remote add origin https://github.com/kafkasl/ksync.git
    Check-Exit 'Configure corresponding source'
}
git -C artifacts/kfxlib-source fetch --depth=1 origin fc00a7b7a04badfbd61f3e42aaaa5e45e1d0cfd7
Check-Exit 'Obtain pinned corresponding source'
git -C artifacts/kfxlib-source checkout --detach FETCH_HEAD
Check-Exit 'Check corresponding source revision'
& $python tool/package_kindle_prototype.py --binary-directory artifacts/kindle-dist/KMReader-Kindle --source (git rev-parse HEAD) --smoke-report artifacts/kindle-executable-check.json --output artifacts/kindle-delivery --kfx-source-repository artifacts/kfxlib-source
Check-Exit 'Package corresponding source and licenses'
