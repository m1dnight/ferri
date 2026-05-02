connections := "100"
duration := "10s"

# Cut a new release: bump versions in mix.exs + Cargo.toml, roll up the
# changelog from .changelogs/unreleased into a versioned dir, regenerate
# CHANGELOG.md, commit as "Release vVERSION", and create the v<VERSION> tag.
# Does NOT push — verify the result, then run:
#     git push origin main && git push origin v<VERSION>
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="{{VERSION}}"

    if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "version must look like X.Y.Z (got '${VERSION}')" >&2
      exit 1
    fi

    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "working tree is dirty — commit or stash first" >&2
      exit 1
    fi

    # 1. bump versions
    sed -i.bak -E "s/(version: )\"[0-9]+\.[0-9]+\.[0-9]+\"/\1\"${VERSION}\"/" mix.exs
    sed -i.bak -E "s/^version = \"[0-9]+\.[0-9]+\.[0-9]+\"/version = \"${VERSION}\"/" ferri-client/ferri/Cargo.toml
    rm -f mix.exs.bak ferri-client/ferri/Cargo.toml.bak

    # refresh Cargo.lock so the version bump is recorded there too
    (cd ferri-client/ferri && cargo update -p ferri --precise "${VERSION}" >/dev/null 2>&1 || cargo generate-lockfile >/dev/null 2>&1 || true)

    # 2. create the new changelog version directory
    mix unclog --create "${VERSION}"

    # 3. copy contents from unreleased into the new version's directory,
    #    then truncate the unreleased files so the structure stays in place.
    if [ -d .changelogs/unreleased ]; then
      for dir in .changelogs/unreleased/*/; do
        [ -d "${dir}" ] || continue
        category="$(basename "${dir}")"
        mkdir -p ".changelogs/${VERSION}/${category}"
        for src in "${dir}"*.md; do
          [ -f "${src}" ] || continue
          cp "${src}" ".changelogs/${VERSION}/${category}/$(basename "${src}")"
          : > "${src}"
        done
      done
      if [ -f .changelogs/unreleased/summary.md ]; then
        cp .changelogs/unreleased/summary.md ".changelogs/${VERSION}/summary.md"
        : > .changelogs/unreleased/summary.md
      fi
    fi

    # 4. regenerate the rolled-up changelog
    mix unclog --generate

    # 5. commit
    git add mix.exs ferri-client/ferri/Cargo.toml ferri-client/ferri/Cargo.lock .changelogs
    [ -f CHANGELOG.md ] && git add CHANGELOG.md
    git commit -m "Release v${VERSION}"

    # 6. tag (local only — push manually after verifying)
    git tag "v${VERSION}"

    echo ""
    echo "Created commit and tag v${VERSION}."
    echo "When ready, push with:"
    echo "  git push origin main && git push origin v${VERSION}"

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
