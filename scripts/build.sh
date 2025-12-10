#!/usr/bin/env bash

set -eu
set -o pipefail

readonly ROOT_DIR="$(cd "$(dirname "${0}")/.." && pwd)"
readonly PROGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILDPACKDIR="$(cd "${PROGDIR}/.." && pwd)"

# shellcheck source=SCRIPTDIR/.util/print.sh
source "${ROOT_DIR}/scripts/.util/print.sh"

function main() {
  local targets=()
  while [[ "${#}" != 0 ]]; do
    case "${1}" in
      --help|-h)
        shift 1
        usage
        exit 0
        ;;

      --target)
        targets+=("${2}")
        shift 2
        ;;

      "")
        # skip if the argument is empty
        shift 1
        ;;

      *)
        util::print::error "unknown argument \"${1}\""
    esac
  done

  if [[ ${#targets[@]} -eq 0 ]]; then
    # Read targets from buildpack.toml
    local buildpack_toml="${BUILDPACKDIR}/buildpack.toml"
    if [[ -f "${buildpack_toml}" ]]; then
      util::print::info "Reading targets from ${buildpack_toml}..."
      # Parse [[targets]] sections from buildpack.toml
      local in_targets=false
      local current_os=""
      local current_arch=""
      
      while IFS= read -r line || [[ -n "${line}" ]]; do
        # Check if we're entering a targets section
        if [[ "${line}" =~ ^\[\[targets\]\] ]]; then
          # Save previous target if we have both os and arch
          if [[ "${in_targets}" == true && -n "${current_os}" && -n "${current_arch}" ]]; then
            targets+=("${current_os}/${current_arch}")
          fi
          in_targets=true
          current_os=""
          current_arch=""
        elif [[ "${in_targets}" == true ]]; then
          # Check if we're leaving the targets section (next section starts)
          if [[ "${line}" =~ ^\[\[ ]] && ! [[ "${line}" =~ ^\[\[targets\]\] ]]; then
            # Save current target before leaving
            if [[ -n "${current_os}" && -n "${current_arch}" ]]; then
              targets+=("${current_os}/${current_arch}")
            fi
            in_targets=false
            current_os=""
            current_arch=""
          # Extract os value
          elif [[ "${line}" =~ ^[[:space:]]*os[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            current_os="${BASH_REMATCH[1]}"
            # If we already have arch, add the target immediately
            if [[ -n "${current_arch}" ]]; then
              targets+=("${current_os}/${current_arch}")
              current_os=""
              current_arch=""
            fi
          # Extract arch value
          elif [[ "${line}" =~ ^[[:space:]]*arch[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            current_arch="${BASH_REMATCH[1]}"
            # If we already have os, add the target immediately
            if [[ -n "${current_os}" ]]; then
              targets+=("${current_os}/${current_arch}")
              current_os=""
              current_arch=""
            fi
          fi
        fi
      done < "${buildpack_toml}"
      
      # Handle last target if we ended while still in targets section
      if [[ "${in_targets}" == true && -n "${current_os}" && -n "${current_arch}" ]]; then
        targets+=("${current_os}/${current_arch}")
      fi
      
      if [[ ${#targets[@]} -gt 0 ]]; then
        util::print::info "Found ${#targets[@]} target(s) in buildpack.toml: ${targets[*]}"
      else
        # Fallback to default if no targets found
        targets=("linux/amd64")
        util::print::info "No targets found in buildpack.toml, using default: linux/amd64"
      fi
    else
      # Fallback to default if buildpack.toml not found
      targets=("linux/amd64")
      util::print::info "buildpack.toml not found, using default target: linux/amd64"
    fi
  fi

  mkdir -p "${BUILDPACKDIR}/bin"

  run::build
  cmd::build

  ## For backwards compatibility with amd64 wokflows
  if [[ ${#targets[@]} -eq 1 && "${targets[0]}" == "linux/amd64" ]]; then
    cp -r "${BUILDPACKDIR}/linux/amd64/bin/" "${BUILDPACKDIR}/"
  fi
}

function usage() {
  cat <<-USAGE
build.sh [OPTIONS]

Builds the buildpack executables.

OPTIONS
  --target strings  Target platforms to build for.
                    Targets should be in the format '[os][/arch][/variant]'.
                      - To specify two different architectures: '--target "linux/amd64" --target "linux/arm64"'
                    If not provided, targets will be read from buildpack.toml [[targets]] sections.
  --help  -h        prints the command usage
USAGE
}

function run::build() {
  if [[ -f "${BUILDPACKDIR}/run/main.go" ]]; then
    pushd "${BUILDPACKDIR}" > /dev/null || return
      for target in "${targets[@]}"; do
        platform=$(echo "${target}" | cut -d '/' -f1)
        arch=$(echo "${target}" | cut -d'/' -f2)

        util::print::title "Building run... for platform: ${platform} and arch: ${arch}"

        GOOS=$platform \
        GOARCH=$arch \
        CGO_ENABLED=0 \
          go build \
            -ldflags="-s -w" \
            -o "${platform}/${arch}/bin/run" \
              "${BUILDPACKDIR}/run"

          echo "Success!"

          names=("detect")

          if [ -f "${BUILDPACKDIR}/extension.toml" ]; then
            names+=("generate")
          else
            names+=("build")
          fi

        for name in "${names[@]}"; do
          printf "%s" "Linking ${name}... "

          ln -fs "run" "${platform}/${arch}/bin/${name}"

          echo "Success!"
        done
      done

    popd > /dev/null || return
  fi
}

function cmd::build() {
  if [[ -d "${BUILDPACKDIR}/cmd" ]]; then
    local name
    for src in "${BUILDPACKDIR}"/cmd/*; do
      name="$(basename "${src}")"
      for target in "${targets[@]}"; do
        platform=$(echo "${target}" | cut -d '/' -f1)
        arch=$(echo "${target}" | cut -d'/' -f2)

        if [[ -f "${src}/main.go" ]]; then
          util::print::title "Building ${name}... for platform: ${platform} and arch: ${arch}"

          GOOS=$platform \
          GOARCH=$arch \
          CGO_ENABLED=0 \
            go build \
              -ldflags="-s -w" \
              -o "${BUILDPACKDIR}/${platform}/${arch}/bin/${name}" \
                "${src}/main.go"

          echo "Success!"
        else
          printf "%s" "Skipping ${name}... "
        fi
      done
    done
  fi
}

main "${@:-}"
