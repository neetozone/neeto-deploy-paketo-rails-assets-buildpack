#!/usr/bin/env bash

set -eu
set -o pipefail

readonly ROOT_DIR="$(cd "$(dirname "${0}")/.." && pwd)"
readonly BIN_DIR="${ROOT_DIR}/.bin"
readonly BUILD_DIR="${ROOT_DIR}/build"

# shellcheck source=SCRIPTDIR/.util/tools.sh
source "${ROOT_DIR}/scripts/.util/tools.sh"

# shellcheck source=SCRIPTDIR/.util/print.sh
source "${ROOT_DIR}/scripts/.util/print.sh"

function main {
  local image_ref token buildpack_path
  token=""

  while [[ "${#}" != 0 ]]; do
    case "${1}" in
      --image-ref|-i)
        image_ref="${2}"
        shift 2
        ;;

      --buildpack-path|-b)
        buildpack_path="${2}"
        shift 2
        ;;

      --token|-t)
        token="${2}"
        shift 2
        ;;

      --help|-h)
        shift 1
        usage
        exit 0
        ;;

      "")
        # skip if the argument is empty
        shift 1
        ;;

      *)
        util::print::error "unknown argument \"${1}\""
        ;;
    esac
  done

  if [[ -z "${image_ref:-}" ]]; then
    usage
    util::print::error "--image-ref is required"
  fi

  repo::prepare

  tools::install "${token}"

  buildpack::publish "${image_ref}" "${buildpack_path}"
}

function usage() {
  cat <<-USAGE
Publishes the rails-assets buildpack to a registry.

Targets are automatically read from buildpack.toml [[targets]] sections.

OPTIONS
  -i, --image-ref <ref>               Image reference to publish to (required)
  -b, --buildpack-path <filepath>     Path to the buildpack archive (default: auto-detected from build directory)
  -t, --token <token>                 Token used to download assets from GitHub (e.g. pack) (optional)
  -h, --help                          Prints the command usage

USAGE
}

function repo::prepare() {
  util::print::title "Preparing repo..."

  mkdir -p "${BIN_DIR}"

  export PATH="${BIN_DIR}:${PATH}"
}

function tools::install() {
  local token
  token="${1}"

  util::tools::pack::install \
    --directory "${BIN_DIR}" \
    --token "${token}"

  util::tools::yj::install \
    --directory "${BIN_DIR}" \
    --token "${token}"
}

function buildpack::publish() {
  local image_ref buildpack_path
  local -a targets

  image_ref="${1}"
  buildpack_path="${2}"

  util::print::title "Publishing rails-assets buildpack..."
  util::print::info "Publishing buildpack to ${image_ref}"

  # Read targets from buildpack.toml
  local buildpack_toml="${ROOT_DIR}/buildpack.toml"
  if [[ ! -f "${buildpack_toml}" ]]; then
    util::print::error "buildpack.toml not found at ${buildpack_toml}"
  fi

  util::print::info "Reading targets from ${buildpack_toml}..."
  local targets_json
  targets_json=$(cat "${buildpack_toml}" | yj -tj | jq -r '.targets[]? | "\(.os)/\(.arch)"' 2>/dev/null || echo "")
  
  if [[ -z "${targets_json}" ]]; then
    util::print::error "No targets found in buildpack.toml. Please add [[targets]] sections."
  fi

  while IFS= read -r target; do
    if [[ -n "${target}" ]]; then
      targets+=("${target}")
    fi
  done <<< "${targets_json}"
  
  util::print::info "Found ${#targets[@]} target(s) in buildpack.toml: ${targets[*]}"

  # Auto-detect buildpack path if not provided
  if [[ -z "${buildpack_path:-}" ]]; then
    if [[ ${#targets[@]} -gt 0 ]]; then
      # Check if we have architecture-specific archives
      local first_arch
      first_arch=$(echo "${targets[0]}" | cut -d'/' -f2)
      local arch_archive="${BUILD_DIR}/buildpack-${first_arch}.tgz"
      if [[ -f "${arch_archive}" ]]; then
        buildpack_path="${arch_archive}"
        util::print::info "Using architecture-specific archive: ${buildpack_path}"
      else
        buildpack_path="${BUILD_DIR}/buildpack.tgz"
        util::print::info "Using default buildpack path: ${buildpack_path}"
      fi
    else
      buildpack_path="${BUILD_DIR}/buildpack.tgz"
      util::print::info "Using default buildpack path: ${buildpack_path}"
    fi
  fi

  if [[ ! -f "${buildpack_path}" ]]; then
    util::print::error "buildpack artifact not found at ${buildpack_path}; run scripts/package.sh first"
  fi

  # For multi-arch, pack needs to publish each architecture separately, then create a manifest
  if [[ ${#targets[@]} -gt 1 ]]; then
    util::print::info "Publishing multi-arch buildpack (${#targets[@]} architectures)..."
    
    # Check if we have architecture-specific archives (bundle-install style)
    local first_arch
    first_arch=$(echo "${targets[0]}" | cut -d'/' -f2)
    local arch_archive="${BUILD_DIR}/buildpack-${first_arch}.tgz"
    
    if [[ -f "${arch_archive}" ]]; then
      # Architecture-specific archives exist (bundle-install style)
      util::print::info "Using architecture-specific archives..."
      
      # Publish each architecture separately
      local arch_images=()
      for target in "${targets[@]}"; do
        local arch
        arch=$(echo "${target}" | cut -d'/' -f2)
        local arch_archive="${BUILD_DIR}/buildpack-${arch}.tgz"
        local arch_image_ref="${image_ref}-${arch}"
        
        if [[ ! -f "${arch_archive}" ]]; then
          util::print::error "Architecture-specific archive not found: ${arch_archive}"
        fi
        
        util::print::info "Publishing ${target} as ${arch_image_ref}..."
        pack \
          buildpack package "${arch_image_ref}" \
          --path "${arch_archive}" \
          --target "${target}" \
          --format image \
          --publish
        
        arch_images+=("${arch_image_ref}")
      done
      
      # Create and push multi-arch manifest
      util::print::info "Creating multi-arch manifest for ${image_ref}..."
      
      # Remove existing manifest if it exists
      if docker manifest inspect "${image_ref}" >/dev/null 2>&1; then
        util::print::info "Removing existing manifest list..."
        docker manifest rm "${image_ref}" 2>/dev/null || true
      fi
      
      # Create the manifest list
      docker manifest create "${image_ref}" "${arch_images[@]}"
      docker manifest push "${image_ref}"
      
      util::print::info "Successfully published multi-arch buildpack: ${image_ref}"
    else
      # Single archive with both architectures (MRI/rails-assets style)
      util::print::info "Using single archive with multiple architectures..."
      
      # Extract the archive to a temporary directory
      util::print::info "Extracting archive..."
      local tmp_dir
      tmp_dir=$(mktemp -d)
      tar -xzf "${buildpack_path}" -C "${tmp_dir}"
      
      # Publish each architecture separately from the extracted archive
      # For each target, create a filtered version and publish it
      local arch_images=()
      for target in "${targets[@]}"; do
        local arch
        arch=$(echo "${target}" | cut -d'/' -f2)
        local platform
        platform=$(echo "${target}" | cut -d'/' -f1)
        local arch_image_ref="${image_ref}-${arch}"
        
        util::print::info "Publishing ${target} as ${arch_image_ref}..."
        
        # Create a filtered directory for this architecture
        local arch_tmp_dir
        arch_tmp_dir=$(mktemp -d)
        
        # Copy buildpack.toml
        cp "${tmp_dir}/buildpack.toml" "${arch_tmp_dir}/"
        
        # Copy only this architecture's binaries
        if [[ -d "${tmp_dir}/${platform}/${arch}" ]]; then
          mkdir -p "${arch_tmp_dir}/${platform}/${arch}"
          cp -r "${tmp_dir}/${platform}/${arch}"/* "${arch_tmp_dir}/${platform}/${arch}/"
        fi
        
        # Update buildpack.toml to only include this architecture's files
        if command -v yj >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
          local filtered_toml
          filtered_toml=$(mktemp)
          yj -tj < "${arch_tmp_dir}/buildpack.toml" | \
            jq --arg target "${target}" '
              if .metadata."include-files" then
                .metadata."include-files" = (
                  .metadata."include-files" | 
                  map(select(
                    . == "buildpack.toml" or 
                    startswith($target + "/")
                  ))
                )
              else
                .
              end
            ' | \
            yj -jt > "${filtered_toml}"
          mv "${filtered_toml}" "${arch_tmp_dir}/buildpack.toml"
        fi
        
        # Publish the filtered buildpack
        pack \
          buildpack package "${arch_image_ref}" \
          --path "${arch_tmp_dir}" \
          --target "${target}" \
          --format image \
          --publish
        
        arch_images+=("${arch_image_ref}")
        
        # Clean up filtered directory
        rm -rf "${arch_tmp_dir}"
      done
      
      # Clean up temporary directory
      rm -rf "${tmp_dir}"
      
      # Create and push multi-arch manifest
      util::print::info "Creating multi-arch manifest for ${image_ref}..."
      
      # Remove existing manifest if it exists
      if docker manifest inspect "${image_ref}" >/dev/null 2>&1; then
        util::print::info "Removing existing manifest list..."
        docker manifest rm "${image_ref}" 2>/dev/null || true
      fi
      
      # Create the manifest list
      docker manifest create "${image_ref}" "${arch_images[@]}"
      docker manifest push "${image_ref}"
      
      util::print::info "Successfully published multi-arch buildpack: ${image_ref}"
    fi
  else
    # Single architecture - use standard pack command
    args=(
      buildpack package "${image_ref}"
      --path "${buildpack_path}"
      --format image
      --publish
    )

    for target in "${targets[@]}"; do
      args+=("--target" "${target}")
    done

    pack "${args[@]}"
  fi
}

main "${@:-}"

