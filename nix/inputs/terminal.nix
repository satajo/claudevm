# The host terminal's TERM and window size, which the session's terminal
# takes on. The serial console carries no window size, so the guest
# applies the launch-time size once.
{ config, lib, pkgs }:

{
  collect = ''
    terminal_type=''${TERM:-xterm-256color}
    terminal_rows=
    terminal_cols=
    if size=$(stty size 2>/dev/null); then
      terminal_rows=''${size% *}
      terminal_cols=''${size#* }
    fi
  '';

  summary = "";

  # The entry holds TERM, the rows and the columns as NUL-terminated
  # fields; rows and columns are empty when the host has no window size.
  write = ''
    printf '%s\0%s\0%s\0' "$terminal_type" "$terminal_rows" "$terminal_cols" > "$runtime/launch/terminal"
  '';

  setup = "";

  session = ''
    if ! { IFS= read -r -d "" terminal_type && IFS= read -r -d "" terminal_rows && IFS= read -r -d "" terminal_cols && ! IFS= read -r -d "" rest && [ -z "$rest" ]; } < /mnt/launch/terminal \
        || [ -z "$terminal_type" ] \
        || ! [[ "$terminal_rows $terminal_cols" =~ ^([0-9]+ [0-9]+| )$ ]]; then
      echo "/mnt/launch/terminal holds no TERM, rows and columns" >&2
      exit 1
    fi
    export TERM=$terminal_type
    if [ -n "$terminal_rows" ]; then
      ${lib.getExe' pkgs.coreutils "stty"} rows "$terminal_rows" cols "$terminal_cols" || true
    fi
  '';
}
