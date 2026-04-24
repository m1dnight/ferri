connections := "100"
duration := "10s"

# Cross-build a linux/amd64 production release inside Docker
# and tar it up for scp to the VPS.
release:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf release-linux
    docker buildx build \
        --platform linux/amd64 \
        --target release \
        --output type=local,dest=release-linux \
        -f Dockerfile.release \
        .
    tar czf /tmp/ferri-release.tar.gz -C release-linux ferri
    echo "wrote /tmp/ferri-release.tar.gz  ($(du -sh /tmp/ferri-release.tar.gz | cut -f1))"

# Transfer the built release to the VPS.
deploy host="admin@platform.genserver.be":
    scp /tmp/ferri-release.tar.gz {{host}}:/tmp/

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
