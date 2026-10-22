# The plugin_mounts directories, which the Claude Code of the session loads.
#
# Uses from the launcher: plugin_mounts, overlaps, refuse, config_error,
# resolve_entry_dir and quoted. Uses from shares: add_share and
# in_shared_dir.
# Defines for the session fragment of command: plugin_args.
{ config, lib, pkgs }:

{
  collect = ''
    # The plugin_mounts directories in claudevm.toml order, each with "own"
    # when it has a read-only share of its own and "within" when the guest
    # sees it through the workspace or a [[mounts]] share.
    plugin_dirs=()
    plugin_shares=()
    for i in "''${!plugin_mounts[@]}"; do
      entry="plugin_mounts entry $((i + 1))"
      resolve_entry_dir "$entry" "''${plugin_mounts[i]}"
      if [ ! -f "$entry_dir/.claude-plugin/plugin.json" ]; then
        config_error "$entry: $(quoted "$entry_dir") is not a Claude Code plugin: .claude-plugin/plugin.json is missing"
      fi
      for j in "''${!plugin_dirs[@]}"; do
        if overlaps "''${plugin_dirs[j]}" "$entry_dir"; then
          refuse "$(quoted "$entry_dir") ($entry)" "it overlaps $(quoted "''${plugin_dirs[j]}") of plugin_mounts entry $((j + 1))"
        fi
      done
      if in_shared_dir "$entry_dir"; then
        plugin_shares+=(within)
      else
        add_share "$entry_dir" ro "$(quoted "$entry_dir") ($entry)" "$(quoted "$entry_dir") of $entry"
        plugin_shares+=(own)
      fi
      plugin_dirs+=("$entry_dir")
    done
  '';

  summary = ''
    for i in "''${!plugin_dirs[@]}"; do
      case ''${plugin_shares[i]} in
        own) printf 'claudevm: %-9s  ro  %s  (claudevm.toml)\n' plugin "$(quoted "''${plugin_dirs[i]}")" ;;
        within) printf 'claudevm: %-9s  %s  (claudevm.toml)\n' plugin "$(quoted "''${plugin_dirs[i]}")" ;;
      esac
    done
  '';

  # The entry lists the plugin directories as NUL-terminated paths, which
  # the guest sees at their host paths and loads into Claude Code in this
  # order.
  write = ''
    for dir in "''${plugin_dirs[@]}"; do printf '%s\0' "$dir"; done > "$runtime/launch/plugins"
  '';

  setup = "";

  session = ''
    plugin_args=()
    while IFS= read -r -d "" dir; do
      case $dir in
        /*) plugin_args+=(--plugin-dir "$dir") ;;
        *)
          echo "/mnt/launch/plugins lists '$dir', which is not an absolute path" >&2
          exit 1
          ;;
      esac
    done < /mnt/launch/plugins
    if [ -n "$dir" ]; then
      echo "/mnt/launch/plugins ends in an incomplete path" >&2
      exit 1
    fi
  '';
}
