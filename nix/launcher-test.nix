# Runs the claudevm launcher on claudevm.toml files and claudevm
# directories that each case sets up, up to the /dev/kvm check. A builder
# on a host with KVM exposes /dev/kvm to every build, so each launch runs
# in a mount namespace whose /dev/kvm is a read-only file, as the user
# that started the test: the launch stops at that check, and nothing past
# it starts, whatever the builder provides.
{ runCommand, util-linux, toml2json, jq, claudevm, guest }:

runCommand "claudevm-launcher-test" {
  nativeBuildInputs = [ claudevm util-linux toml2json jq ];
} ''
  set -euo pipefail

  default_disk=${toString guest.claudevm.disk}
  disk_minimum=${toString guest.claudevm.diskMinimum}
  kvm_message="claudevm: /dev/kvm is missing or not writable; the VM requires KVM"

  no_kvm=$TMPDIR/no-kvm
  : > "$no_kvm"
  chmod 0444 "$no_kvm"
  uid=$(id -u)
  gid=$(id -g)

  # Sets case_dir to a fresh directory with a home, a claudevm directory
  # that holds a token and an empty workspace, and points HOME and
  # CLAUDEVM_HOME there.
  new_case() {
    case_dir=$(mktemp -d)
    export HOME=$case_dir/home CLAUDEVM_HOME=$case_dir/claudevm
    workspace=$case_dir/workspace
    disks_dir=$CLAUDEVM_HOME/disks
    mkdir "$HOME" "$CLAUDEVM_HOME" "$workspace"
    printf 'sk-ant-oat-test\n' > "$CLAUDEVM_HOME/token"
    chmod 0600 "$CLAUDEVM_HOME/token"
  }

  # write_config LINE... writes the workspace's claudevm.toml.
  write_config() {
    printf '%s\n' "$@" > "$workspace/claudevm.toml"
  }

  # Runs claudevm in the workspace and sets status and stderr.
  launch() {
    status=0
    stderr=$(
      cd "$workspace" &&
        unshare --user --map-root-user --mount -- bash -c '
          if [ -e /dev/kvm ]; then
            mount --bind "$1" /dev/kvm
          fi
          exec unshare --user --map-user="$2" --map-group="$3" -- claudevm
        ' bash "$no_kvm" "$uid" "$gid" 2>&1 > /dev/null
    ) || status=$?
  }

  # expect STATUS MESSAGE fails unless the last launch exited with STATUS
  # and printed MESSAGE.
  expect() {
    if [ "$status" -ne "$1" ] || [[ $stderr != *"$2"* ]]; then
      printf 'expected exit status %s and "%s", got exit status %s and:\n%s\n' "$1" "$2" "$status" "$stderr" >&2
      return 1
    fi
  }

  # expect_mode MODE PATH
  expect_mode() {
    local mode
    mode=$(stat -c %a "$2")
    if [ "$mode" != "$1" ]; then
      echo "expected $2 to have mode $1, it has $mode" >&2
      return 1
    fi
  }

  init_writes_the_default_disk() {
    new_case
    (cd "$workspace" && claudevm init 2> /dev/null)
    disk=$(toml2json "$workspace/claudevm.toml" | jq '.disk')
    if [ "$disk" != "$default_disk" ]; then
      echo "claudevm init wrote disk = $disk, not $default_disk" >&2
      return 1
    fi
  }

  disk_that_is_not_a_positive_integer_is_rejected() {
    local value
    for value in 0 -1 1.5 '"32G"' true; do
      new_case
      write_config "disk = $value"
      launch
      expect 1 "claudevm: claudevm.toml: 'disk' must be a positive integer"
    done
  }

  disk_below_the_minimum_is_rejected() {
    new_case
    write_config "disk = $((disk_minimum - 1))"
    launch
    expect 1 "claudevm: claudevm.toml: 'disk' must be at least $disk_minimum (MiB)"
  }

  disk_at_the_minimum_or_left_out_is_accepted() {
    local config
    for config in "disk = $disk_minimum" ""; do
      new_case
      write_config "$config"
      launch
      expect 1 "$kvm_message"
      expect_mode 700 "$disks_dir"
    done
  }

  symlinked_disks_directory_is_refused() {
    new_case
    mkdir -m 0755 "$case_dir/elsewhere"
    ln -s "$case_dir/elsewhere" "$disks_dir"
    write_config
    launch
    expect 1 "claudevm: $disks_dir is a symlink; the disks directory must be a directory"
    expect_mode 755 "$case_dir/elsewhere"
  }

  disks_path_that_is_a_file_is_refused() {
    new_case
    : > "$disks_dir"
    write_config
    launch
    expect 1 "claudevm: cannot create the disks directory $disks_dir"
  }

  missing_disks_directory_in_a_read_only_claudevm_directory_is_refused() {
    new_case
    chmod 0500 "$CLAUDEVM_HOME"
    write_config
    launch
    expect 1 "claudevm: cannot create the disks directory $disks_dir"
  }

  disks_directory_gets_mode_0700() {
    new_case
    mkdir -m 0755 "$disks_dir"
    write_config
    launch
    expect 1 "$kvm_message"
    expect_mode 700 "$disks_dir"
  }

  for case in \
      init_writes_the_default_disk \
      disk_that_is_not_a_positive_integer_is_rejected \
      disk_below_the_minimum_is_rejected \
      disk_at_the_minimum_or_left_out_is_accepted \
      symlinked_disks_directory_is_refused \
      disks_path_that_is_a_file_is_refused \
      missing_disks_directory_in_a_read_only_claudevm_directory_is_refused \
      disks_directory_gets_mode_0700; do
    echo "case $case"
    "$case"
  done

  touch "$out"
''
