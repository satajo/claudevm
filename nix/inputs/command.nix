# What the session runs: Claude Code with the arguments claudevm was given,
# or the debug shell.
#
# Uses from the launcher: session and the positional parameters. Uses from
# plugins: plugin_args.
{ config, lib, pkgs }:

let
  claude = lib.getExe' config.claudevm.claudeCode "claude";
  bash = lib.getExe pkgs.bashInteractive;
in
{
  collect = "";

  summary = "";

  # The entry holds the session kind, claude or shell, and then the
  # arguments of claude as NUL-terminated fields.
  write = ''
    printf '%s\0' "$session" "$@" > "$runtime/launch/command"
  '';

  setup = "";

  session = ''
    command_fields=()
    while IFS= read -r -d "" field; do
      command_fields+=("$field")
    done < /mnt/launch/command
    if [ -n "$field" ] || [ "''${#command_fields[@]}" -eq 0 ]; then
      echo "/mnt/launch/command holds no complete session kind and arguments" >&2
      exit 1
    fi
    command_kind=''${command_fields[0]}
    command_args=("''${command_fields[@]:1}")
    case $command_kind in
      claude) exec ${claude} --dangerously-skip-permissions "''${plugin_args[@]}" "''${command_args[@]}" ;;
      shell)
        if [ "''${#command_args[@]}" -eq 0 ]; then
          exec ${bash} -l
        fi
        echo "/mnt/launch/command gives the shell arguments" >&2
        exit 1
        ;;
    esac
    echo "/mnt/launch/command holds the unknown session kind '$command_kind'" >&2
    exit 1
  '';
}
