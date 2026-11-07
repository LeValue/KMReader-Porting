import sys

if sys.argv[1:] == ["rpc-json"]:
    from .native_rpc import main
else:
    from .cli import main

raise SystemExit(main())
