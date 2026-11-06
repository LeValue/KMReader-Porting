"""Source and PyInstaller entry point."""

import sys

if sys.argv[1:] == ["rpc-json"]:
    from kindle_personal.native_rpc import main
else:
    from kindle_personal.cli import main

raise SystemExit(main())
