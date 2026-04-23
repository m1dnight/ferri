connections := "100"
duration := "10s"

ferri_prod:
  PHX_SERVER=true PHX_HOST=localhost SECRET_KEY_BASE=0mofhrLV3VrPEk60ocWwfQ+jE5MXoECGNAAuGd91FQtzjEYwGUSdm4/rMVGBbO7m DATABASE_URL=ecto://USER:PASS@HOST/DATABASE MIX_ENV=prod iex -S mix
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
