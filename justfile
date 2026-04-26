connections := "100"
duration := "10s"

# Cross-build a linux/amd64 production release inside Docker
# and tar it up for scp to the VPS.
release:
    #!/usr/bin/env bash
    export MIX_ENV=prod
    mix deps.get --only=prod
    mix assets.deploy
    mix release --overwrite
    unset MIX_ENV

webserver:
    python3 scripts/hello_server.py

bench target subdomain="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{target}}" in
      direct)
        oha -c {{connections}} -z {{duration}} http://127.0.0.1:4444/
        ;;
      ferri)
        if [ -z "{{subdomain}}" ]; then
          echo "usage: just bench ferri <subdomain>" >&2
          exit 1
        fi
        oha -c {{connections}} -z {{duration}}  "http://{{subdomain}}.localhost:8080/"
        ;;
      *)
        echo "unknown target '{{target}}' (expected: direct | ferri)" >&2
        exit 1
        ;;
    esac
