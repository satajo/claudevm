# The forward_packages, built on the host and put on the agent's PATH in the
# guest, which reads them through its share of the host's store.
#
# Uses from the launcher: forward_packages, HOME, config_error and quoted.
#
# Besides the five fragments it provides login, which puts the packages on
# PATH in login shells.
{ config, lib, pkgs }:

let
  # The entry is a directory. Its "path" lists the bin directories of the
  # packages as NUL-terminated store paths. This puts them in front of PATH
  # in that order; an empty list leaves PATH unchanged.
  prependPath = ''
    PATH="$(${lib.getExe' pkgs.coreutils "tr"} '\0' : < /mnt/launch/forward-packages/path)$PATH"
  '';
in
{
  collect = ''
    # The guest sees the host's /nix/store, so a package built here needs no
    # download in the VM. The working directory is still the workspace, so
    # relative flake references resolve against it. Each out-link in the
    # runtime directory is a GC root that keeps the build for the session;
    # nix names it fwd<entry>, plus -<output> for an output other than out.
    forward_installables=()
    forward_outputs=()
    forward_dirs=()
    for i in "''${!forward_packages[@]}"; do
      entry="forward_packages entry $((i + 1))"
      installable=''${forward_packages[i]}
      case $installable in
        \~/*) installable=$HOME/''${installable#\~/} ;;
      esac
      if ! out_paths=$(nix build --print-out-paths --out-link "$runtime/fwd$((i + 1))" -- "$installable"); then
        config_error "$entry: building $(quoted "$installable") failed"
      fi
      entry_outputs=()
      bin_dirs=()
      while IFS= read -r out_path; do
        case $out_path in
          /nix/store/*) ;;
          *) config_error "$entry: $(quoted "$installable") built $(quoted "$out_path"), which lies outside /nix/store, the only store the VM sees" ;;
        esac
        entry_outputs+=("$out_path")
        if [ -d "$out_path/bin" ]; then
          bin_dirs+=("$out_path/bin")
        fi
      done <<< "$out_paths"
      if [ "''${#bin_dirs[@]}" -eq 0 ]; then
        config_error "$entry: $(quoted "$installable") provides no executables; none of its outputs has a bin directory: $(quoted "''${entry_outputs[@]}")"
      fi
      forward_outputs+=("''${entry_outputs[@]}")
      forward_installables+=("$installable")
      forward_dirs+=("''${bin_dirs[@]}")
    done
  '';

  summary = ''
    for installable in "''${forward_installables[@]}"; do
      printf 'claudevm: %-9s  %s  (claudevm.toml)\n' forward "$(quoted "$installable")"
    done
  '';

  write = ''
    mkdir "$runtime/launch/forward-packages"

    for dir in "''${forward_dirs[@]}"; do printf '%s\0' "$dir"; done > "$runtime/launch/forward-packages/path"

    # "outputs" lists the store paths of the outputs, each once, as
    # NUL-terminated paths.
    for out_path in "''${forward_outputs[@]}"; do printf '%s\0' "$out_path"; done \
      | LC_ALL=C sort -zu > "$runtime/launch/forward-packages/outputs"

    # "registration" is the Nix validity registration of the closure of the
    # outputs, as nix-store --dump-db writes it; empty without outputs, for
    # which nix-store --query prints nothing. nix-store --dump-db without
    # paths dumps the host's whole database, so xargs -r runs it only when
    # there are paths.
    if ! nix-store --query --requisites "''${forward_outputs[@]}" \
        | xargs -r -d '\n' nix-store --dump-db > "$runtime/launch/forward-packages/registration"; then
      echo "claudevm: cannot read the nix registration of the forward_packages closure" >&2
      exit 1
    fi
  '';

  # A garbage collection, which every user may ask the Nix daemon for,
  # removes from the /nix/store overlay every path that is not valid in the
  # guest's Nix database or not reachable from a garbage collection root.
  # The database starts with the system closure; the registration adds the
  # closure of the outputs, and the links under /nix/var/nix/gcroots root
  # the outputs. Root's nix-store opens the database itself, without the
  # daemon.
  setup = ''
    while IFS= read -r -d "" dir; do
      if ! [[ $dir =~ ^/nix/store/[^/]+/bin$ ]]; then
        echo "/mnt/launch/forward-packages/path lists '$dir', which is not the bin directory of a store path" >&2
        exit 1
      fi
    done < /mnt/launch/forward-packages/path
    if [ -n "$dir" ]; then
      echo "/mnt/launch/forward-packages/path ends in an incomplete path" >&2
      exit 1
    fi
    ${config.nix.package.out}/bin/nix-store --load-db < /mnt/launch/forward-packages/registration
    mkdir /nix/var/nix/gcroots/forward-packages
    while IFS= read -r -d "" out_path; do
      if ! [[ $out_path =~ ^/nix/store/[^/]+$ ]]; then
        echo "/mnt/launch/forward-packages/outputs lists '$out_path', which is not a store path" >&2
        exit 1
      fi
      ln -s -t /nix/var/nix/gcroots/forward-packages "$out_path"
    done < /mnt/launch/forward-packages/outputs
    if [ -n "$out_path" ]; then
      echo "/mnt/launch/forward-packages/outputs ends in an incomplete path" >&2
      exit 1
    fi
  '';

  session = prependPath;

  login = prependPath;
}
