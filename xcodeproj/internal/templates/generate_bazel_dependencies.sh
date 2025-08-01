#!/bin/bash

set -euo pipefail

cd "$SRCROOT"

# Calculate Bazel `--output_groups`

if [ "$ACTION" == "indexbuild" ]; then
  echo >&2 "error: \`BazelDependencies\` should not run during Index Build." \
"Please file a bug report here:" \
"https://github.com/MobileNativeFoundation/rules_xcodeproj/issues/new?template=bug.md"
  exit 1
else
  if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
    # Compile params, products (i.e. bundles) and index store data, and link
    # params
    readonly output_group_prefixes="bc,bp,bl"
  else
    # Products (i.e. bundles) and index store data
    readonly output_group_prefixes="bp"
  fi

  # In Xcode 14 the "Index" directory was renamed to "Index.noindex".
  # `$INDEX_DATA_STORE_DIR` is set to `$OBJROOT/INDEX_DIR/DataStore`, so we can
  # use it to determine the name of the directory regardless of Xcode version.
  readonly index_dir="${INDEX_DATA_STORE_DIR%/*}"
  readonly index_dir_name="${index_dir##*/}"

  # Xcode doesn't adjust `$OBJROOT` in scheme action scripts when building for
  # previews. So we need to look in the non-preview build directory for this file.
  readonly non_preview_objroot="${OBJROOT/\/Intermediates.noindex\/Previews\/*//Intermediates.noindex}"
  readonly base_objroot="${non_preview_objroot/\/$index_dir_name\/Build\/Intermediates.noindex//Build/Intermediates.noindex}"
  readonly build_marker_file="$non_preview_objroot/build_marker"

  # We need to read from `$output_groups_file` as soon as possible, as concurrent
  # writes to it can happen during indexing, which breaks the off-by-one-by-design
  # nature of it
  IFS=$'\n' read -r -d '' -a labels_and_output_groups < \
    <( "$CALCULATE_OUTPUT_GROUPS_SCRIPT" \
        "$XCODE_VERSION_ACTUAL" \
        "$non_preview_objroot" \
        "$base_objroot" \
        "$build_marker_file" \
        $output_group_prefixes \
        && printf '\0' )

  readonly outputgroup_regex='[^\ ]+ @{0,2}(.*)//(.*):(.*) ([^\ ]+)$'

  raw_labels=()
  raw_target_ids=()
  output_groups=("index_import" "target_ids_list")
  indexstores_filelists=()
  for (( i=0; i<${#labels_and_output_groups[@]}; i+=2 )); do
    raw_labels+=("${labels_and_output_groups[i]}")

    output_group="${labels_and_output_groups[i+1]}"
    raw_target_ids+=("${output_group#* }")
    output_groups+=("$output_group")

    output_type="${output_group%% *}"

    if [[ "$output_type" == 'xi' || "$output_type" == 'bi' ]]; then
      if [[ $output_group =~ $outputgroup_regex ]]; then
        repo="${BASH_REMATCH[1]}"
        if [[ "$repo" == "@" ]]; then
          repo=""
        fi

        package="${BASH_REMATCH[2]}"
        target="${BASH_REMATCH[3]}"
        configuration="${BASH_REMATCH[4]}"
        filelist="$configuration/bin/${repo:+"external/$repo/"}$package/$target-${output_type}.filelist"

        indexstores_filelists+=("$filelist")
      fi
    fi
  done
  readonly indexstores_filelists

  if [ "${#output_groups[@]}" -eq 1 ]; then
    echo "BazelDependencies invoked without any output groups set." \
      "Exiting early."
    exit
  else
    labels=()
    while IFS= read -r -d '' label; do
      labels+=("$label")
    done < <(printf "%s\0" "${raw_labels[@]}" | sort -uz)

    target_ids=()
    while IFS= read -r -d '' target_id; do
      target_ids+=("$target_id")
    done < <(printf "%s\0" "${raw_target_ids[@]}" | sort -uz)
  fi
fi

# Build

build_pre_config_flags=(
  # Include the following:
  #
  # - .indexstore directories to allow importing indexes
  # - .swift{doc,sourceinfo} files for indexing
  # - .a and .swiftmodule files for lldb
  # - primary compilation input files (.c, .C, .cc, .cl, .cpp, .cu, .cxx, .c++,
  #   .m, .mm, .swift) for Xcode build input checking
  # - files needed for Clang importer (headers, modulemaps, yaml files, etc.)
  #
  # This is brittle. If different file extensions are used for compilation
  # inputs, they will need to be added to this list. Ideally we can stop doing
  # this once Bazel adds support for a Remote Output Service.
  "--remote_download_regex=.*\.indexstore/.*|.*\.(a|cfg|c|C|cc|cl|cpp|cu|cxx|c++|def|h|H|hh|hpp|hxx|h++|hmap|ilc|inc|inl|ipp|tcc|tlh|tli|tpp|m|modulemap|mm|pch|swift|swiftdoc|swiftmodule|swiftsourceinfo|yaml)$"
)

apply_sanitizers=1
if [ "$ACTION" == "indexbuild" ]; then
  readonly config="${BAZEL_CONFIG}_indexbuild"

  # Index Build doesn't need sanitizers
  apply_sanitizers=0
elif [ "${ENABLE_PREVIEWS:-}" == "YES" ]; then
  readonly config="${BAZEL_CONFIG}_swiftuipreviews"
else
  readonly config="_${BAZEL_CONFIG}_build"
fi

# Respect the "Continue building after errors" setting
continue_building_value="$(defaults read com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors 2>/dev/null || echo 0)"
if [ "$continue_building_value" == "1" ]; then
  build_pre_config_flags+=("--keep_going")
else
  build_pre_config_flags+=("--nokeep_going")
fi

# Runtime Sanitizers
if [[ $apply_sanitizers -eq 1 ]]; then
  if [ "${ENABLE_ADDRESS_SANITIZER:-}" == "YES" ]; then
    build_pre_config_flags+=(
      --copt=-fno-omit-frame-pointer
      --copt=-fno-sanitize-recover=all
      --copt=-fsanitize=address
      --linkopt=-fsanitize=address
      --%swiftcopt%=-sanitize=address
      --copt=-Wno-macro-redefined
      --copt=-D_FORTIFY_SOURCE=0
    )
  fi
  if [ "${ENABLE_THREAD_SANITIZER:-}" == "YES" ]; then
    build_pre_config_flags+=(
      --copt=-fno-omit-frame-pointer
      --copt=-fno-sanitize-recover=all
      --copt=-fsanitize=thread
      --linkopt=-fsanitize=thread
      --%swiftcopt%=-sanitize=thread
      )
  fi
  if [ "${ENABLE_UNDEFINED_BEHAVIOR_SANITIZER:-}" == "YES" ]; then
    build_pre_config_flags+=(
      --copt=-fno-omit-frame-pointer
      --copt=-fno-sanitize-recover=all
      --copt=-fsanitize=undefined
      --linkopt=-fsanitize=undefined
    )
  fi
fi
readonly build_pre_config_flags

# `bazel_build.sh` sets `output_path`
source "$BAZEL_INTEGRATION_DIR/bazel_build.sh"

# Async actions
#
# For these commands to run in the background, both stdout and stderr need to be
# redirected, otherwise Xcode will block the run script.

readonly log_dir="$OBJROOT/rules_xcodeproj_logs"
mkdir -p "$log_dir"

# Report errors from previous async actions
shopt -s nullglob
for log in "$log_dir"/*.async.log; do
  if [[ -s "$log" ]]; then
    command=$(basename "${log%.async.log}")
    echo "warning: Previous run of \"$command\" had output:" >&2
    sed "s|^|warning: |" "$log" >&2
    echo "warning: If you believe this is a bug, please file a report here:" \
"https://github.com/MobileNativeFoundation/rules_xcodeproj/issues/new?template=bug.md" \
      >&2
  fi
done

# Import indexes
if [ -n "${indexstores_filelists:-}" ]; then
  "$BAZEL_INTEGRATION_DIR/import_indexstores" \
    "$PROJECT_DIR" \
    "${indexstores_filelists[@]/#/$BAZEL_OUT/}" \
    >"$log_dir/import_indexstores.async.log" 2>&1 &
fi
