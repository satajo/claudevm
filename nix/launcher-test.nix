# Runs claudevm commands on claudevm.toml files and claudevm directories
# that each case sets up; a launch or shell runs up to the /dev/kvm check.
# A builder on a host with KVM exposes /dev/kvm to every build, so every
# command runs in a mount namespace whose /dev/kvm is a read-only file, as
# the user that started the test: a launch or shell stops at that check,
# and nothing past it starts, whatever the builder provides.
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

  # run_claudevm ARG... runs claudevm ARG... in the workspace and sets
  # status, stdout and stderr.
  run_claudevm() {
    status=0
    (
      cd "$workspace" &&
        unshare --user --map-root-user --mount -- bash -c '
          if [ -e /dev/kvm ]; then
            mount --bind "$1" /dev/kvm
          fi
          exec unshare --user --map-user="$2" --map-group="$3" -- claudevm "''${@:4}"
        ' bash "$no_kvm" "$uid" "$gid" "$@"
    ) > "$TMPDIR/stdout" 2> "$TMPDIR/stderr" || status=$?
    stdout=$(< "$TMPDIR/stdout")
    stderr=$(< "$TMPDIR/stderr")
  }

  # Runs claudevm launch in the workspace and sets status, stdout and
  # stderr.
  launch() {
    run_claudevm launch
  }

  # expect STATUS MESSAGE fails unless the last run of claudevm exited
  # with STATUS and printed MESSAGE to stderr.
  expect() {
    if [ "$status" -ne "$1" ] || [[ $stderr != *"$2"* ]]; then
      printf 'expected exit status %s and "%s", got exit status %s and:\n%s\n' "$1" "$2" "$status" "$stderr" >&2
      return 1
    fi
  }

  # expect_help TEXT fails unless TEXT is the help, which starts with the
  # usage line and has a line for every command.
  expect_help() {
    local command
    if [[ $1 != "usage: claudevm COMMAND [ARGS...]"$'\n'* ]]; then
      printf 'expected the help to start with the usage line, got:\n%s\n' "$1" >&2
      return 1
    fi
    for command in launch shell init login help; do
      if [[ $'\n'$1 != *$'\n'"  $command "* ]]; then
        printf 'expected the help with a line for %s, got:\n%s\n' "$command" "$1" >&2
        return 1
      fi
    done
  }

  # Prints every entry of the case directory with its type and mode, and
  # the digest of every file.
  case_state() {
    find "$case_dir" -printf '%P %y %m\n' -type f -exec sha256sum {} + | sort
  }

  # expect_usage_error MESSAGE ARG... fails unless claudevm ARG... exits
  # with status 1, prints "claudevm: MESSAGE" and the help to stderr and
  # nothing to stdout, and leaves the case directory as it was.
  expect_usage_error() {
    local message=$1 before
    shift
    before=$(case_state)
    run_claudevm "$@"
    if [ "$status" -ne 1 ] || [ -n "$stdout" ] || [[ $stderr != "claudevm: $message"$'\n'* ]]; then
      printf 'expected exit status 1, no stdout and "claudevm: %s" and the help on stderr, got exit status %s, stdout:\n%s\nand stderr:\n%s\n' \
        "$message" "$status" "$stdout" "$stderr" >&2
      return 1
    fi
    expect_help "''${stderr#*$'\n'}"
    expect_unchanged "$before"
  }

  # expect_no_control_characters fails if the stderr of the last run of
  # claudevm holds a control character other than a line break.
  expect_no_control_characters() {
    if [[ ''${stderr//$'\n'/} == *[[:cntrl:]]* ]]; then
      printf 'expected no control characters on stderr, got:\n%s\n' "''${stderr@Q}" >&2
      return 1
    fi
  }

  # expect_unchanged STATE fails unless the case directory is in STATE.
  expect_unchanged() {
    local after
    after=$(case_state)
    if [ "$after" != "$1" ]; then
      printf 'expected the case directory to stay:\n%s\nit is:\n%s\n' "$1" "$after" >&2
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

  # expect_help_command fails unless claudevm help exits with status 0,
  # prints the help to stdout and nothing to stderr, and leaves the case
  # directory as it was.
  expect_help_command() {
    local before
    before=$(case_state)
    run_claudevm help
    if [ "$status" -ne 0 ] || [ -n "$stderr" ]; then
      printf 'expected exit status 0 and no stderr, got exit status %s and:\n%s\n' "$status" "$stderr" >&2
      return 1
    fi
    expect_help "$stdout"
    expect_unchanged "$before"
  }

  help_prints_every_command_to_stdout_and_does_nothing_else() {
    # A launch would create the disks directory here.
    new_case
    write_config
    expect_help_command
    # A launch would stop at the invalid claudevm.toml or the missing token
    # here.
    new_case
    write_config "disk = 0"
    rm "$CLAUDEVM_HOME/token"
    expect_help_command
    # A launch or login would stop at the relative CLAUDEVM_HOME here.
    new_case
    export CLAUDEVM_HOME=claudevm
    expect_help_command
  }

  no_command_prints_the_help_to_stderr_and_fails() {
    new_case
    write_config
    expect_usage_error "no command given"
  }

  unknown_command_is_refused() {
    local command
    for command in "summarize this repo" --resume --help -h "" Launch; do
      new_case
      write_config
      expect_usage_error "unknown command '$command'" "$command"
    done
  }

  control_characters_in_an_unknown_command_are_shown_escaped() {
    new_case
    run_claudevm $'\e[31mred\\'
    expect 1 "claudevm: unknown command '\\x1b[31mred\\\\'"
    expect_no_control_characters
  }

  control_characters_in_claudevm_home_are_shown_escaped() {
    new_case
    export CLAUDEVM_HOME=$'relative\e[31m'
    run_claudevm launch
    expect 1 "claudevm: CLAUDEVM_HOME is 'relative\\x1b[31m', which is not an absolute path"
    expect_no_control_characters
  }

  control_characters_in_claudevm_toml_keys_are_shown_escaped() {
    new_case
    write_config '"key\u001b[31m" = 1' '[[mounts]]' 'path = "/data"' '"key\u0007" = 2'
    run_claudevm launch
    expect 1 "claudevm: claudevm.toml: unknown key 'key\\x1b[31m'"
    expect 1 "claudevm: claudevm.toml: [[mounts]] entry 1: unknown key 'key\\x07'"
    expect_no_control_characters
  }

  control_characters_in_invalid_toml_are_shown_escaped() {
    new_case
    write_config $'bad \e[31m'
    run_claudevm launch
    expect 1 "bad \\x1b[31m"
    expect 1 "claudevm: claudevm.toml is not valid TOML"
    expect_no_control_characters
  }

  unknown_key_that_contains_nul_is_reported_without_the_key() {
    new_case
    write_config '"key\u0000" = 1'
    run_claudevm launch
    expect 1 "claudevm: claudevm.toml: unknown key that contains NUL"
  }

  arguments_to_a_command_without_arguments_are_refused() {
    local command
    # init would write claudevm.toml, login would replace the token with
    # the one on stdin, and shell and help would print other messages.
    for command in shell init login help; do
      new_case
      expect_usage_error "$command takes no arguments" "$command" extra <<< sk-ant-oat-other
    done
  }

  launch_goes_on_to_the_vm_whatever_its_arguments() {
    local argument
    for argument in help --help shell init login launch "summarize this repo" --resume; do
      new_case
      write_config
      run_claudevm launch "$argument"
      expect 1 "$kvm_message"
    done
  }

  shell_goes_on_to_the_vm() {
    new_case
    write_config
    run_claudevm shell
    expect 1 "$kvm_message"
  }

  init_writes_the_default_disk() {
    new_case
    run_claudevm init
    expect 0 "claudevm: created claudevm.toml"
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
    expect 1 "claudevm: '$disks_dir' is a symlink; the disks directory must be a directory"
    expect_mode 755 "$case_dir/elsewhere"
  }

  disks_path_that_is_a_file_is_refused() {
    new_case
    : > "$disks_dir"
    write_config
    launch
    expect 1 "claudevm: cannot create the disks directory '$disks_dir'"
  }

  missing_disks_directory_in_a_read_only_claudevm_directory_is_refused() {
    new_case
    chmod 0500 "$CLAUDEVM_HOME"
    write_config
    launch
    expect 1 "claudevm: cannot create the disks directory '$disks_dir'"
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
      help_prints_every_command_to_stdout_and_does_nothing_else \
      no_command_prints_the_help_to_stderr_and_fails \
      unknown_command_is_refused \
      control_characters_in_an_unknown_command_are_shown_escaped \
      control_characters_in_claudevm_home_are_shown_escaped \
      control_characters_in_claudevm_toml_keys_are_shown_escaped \
      control_characters_in_invalid_toml_are_shown_escaped \
      unknown_key_that_contains_nul_is_reported_without_the_key \
      arguments_to_a_command_without_arguments_are_refused \
      launch_goes_on_to_the_vm_whatever_its_arguments \
      shell_goes_on_to_the_vm \
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
