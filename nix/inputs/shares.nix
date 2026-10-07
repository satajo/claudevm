# The host directories the guest sees at their host paths: the workspace,
# the [[mounts]] directories and the directories later inputs add with
# add_share. Each is served by a virtiofsd of its own.
#
# Uses from the launcher: workspace, HOME, claudevm_home, token_file,
# mount_fields, contains, overlaps, refuse and resolve_entry_dir. Uses
# from transcripts, in add_share: session_dir, which the launcher sets
# empty and transcripts sets before it calls add_share.
# Defines for later collect fragments: add_share and in_shared_dir.
# Defines for the launcher after write: share_sockets.
#
# Besides the five fragments it provides serveShares, the part of the
# runner's virtiofsd-run that serves its shares, and qemuDevices, the QEMU
# arguments of its shares.
{ config, lib, pkgs }:

let
  agent = config.users.users.agent;
  jq = lib.getExe pkgs.jq;
  mount = lib.getExe' pkgs.util-linux "mount";

  # Guest paths the VM itself relies on. Every shared host directory, the
  # workspace included, appears in the guest at its host path, so none may
  # overlap any of them.
  guestPaths = [ "/nix" agent.home config.claudevm.diskMountPoint ]
    ++ map (share: share.mountPoint) config.microvm.shares;

  # Guest directories that the system of the VM and Claude Code in it need.
  # A share may lie under one of them, but a share that contains one would
  # hide it behind its mount.
  guestSystemPaths = [
    "/bin"
    "/boot"
    "/dev"
    "/etc"
    "/lib"
    "/proc"
    "/root"
    "/run"
    "/sys"
    "/tmp"
    "/usr"
    "/var"
    "/tmp/claude-${toString agent.uid}"
  ];

  # The entry lists the shares, the workspace first, as NUL-terminated tag,
  # path, mode (ro or rw) triples. The host serves each tag on the socket
  # <tag>.sock and the guest mounts it at path, the same absolute path the
  # directory has on the host.
  readShare = ''IFS= read -r -d "" tag && IFS= read -r -d "" path && IFS= read -r -d "" mode'';

  # Fails unless tag, path and mode form a share as the host writes it.
  checkShare = ''
    if ! [[ $tag =~ ^(workspace|extra[1-9][0-9]*)$ ]] || [[ $path != /* ]] || ! [[ $mode =~ ^(ro|rw)$ ]]; then
      echo "/mnt/launch/shares holds the malformed share '$tag' '$path' '$mode'" >&2
      exit 1
    fi
  '';

  # Sets workspace to the guest path of the workspace.
  readWorkspace = ''
    if ! { ${readShare}; } < /mnt/launch/shares || [ "$tag" != workspace ] || [ "$mode" != rw ]; then
      echo "/mnt/launch/shares does not start with the read-write workspace" >&2
      exit 1
    fi
    ${checkShare}
    workspace=$path
  '';
in
{
  collect = ''
    # Nothing the VM can read or write may contain these.
    protected=(
      "$(realpath -e "$HOME")"
      "$claudevm_home"
      "$(realpath -e "$token_file")"
    )
    # A dangling symlink counts too, since claude on the host creates its
    # target.
    claude_dir=
    if [ -e "$HOME/.claude" ] || [ -L "$HOME/.claude" ]; then
      claude_dir=$(realpath -m "$HOME/.claude")
      protected+=("$claude_dir")
    fi
    if [ -e "$HOME/.claude.json" ] || [ -L "$HOME/.claude.json" ]; then
      protected+=("$(realpath -m "$HOME/.claude.json")")
    fi

    # The shares in the order of the entry: virtiofs tag, canonical
    # path, mode (ro or rw), and the name a refusal of a later, overlapping
    # share gives it.
    share_tags=()
    share_paths=()
    share_modes=()
    share_names=()

    # add_share PATH MODE SUBJECT NAME adds canonical directory PATH to the
    # shares unless the VM must not see it, with the tag workspace for the
    # first share and extra<index> for every later one. SUBJECT names PATH
    # in its own refusal and NAME in the refusal of a later share that
    # overlaps it.
    add_share() {
      local path=$1 mode=$2 subject=$3 name=$4 protected_path guest_path i
      for protected_path in "''${protected[@]}"; do
        if contains "$path" "$protected_path"; then
          refuse "$subject" "it contains $protected_path"
        fi
      done
      if [ -n "$claude_dir" ] && contains "$claude_dir" "$path"; then
        refuse "$subject" "it lies inside $claude_dir"
      fi
      # The session directory of this launch is the one directory inside
      # the claudevm directory that the VM may see.
      if contains "$claudevm_home" "$path" && [ "$path" != "$session_dir" ]; then
        refuse "$subject" "it lies inside $claudevm_home"
      fi
      for guest_path in ${lib.escapeShellArgs guestPaths}; do
        if overlaps "$guest_path" "$path"; then
          refuse "$subject" "it overlaps $guest_path, which the VM uses"
        fi
      done
      for guest_path in ${lib.escapeShellArgs guestSystemPaths}; do
        if contains "$path" "$guest_path"; then
          refuse "$subject" "it contains $guest_path, which the VM uses"
        fi
      done
      for i in "''${!share_paths[@]}"; do
        if overlaps "''${share_paths[i]}" "$path"; then
          refuse "$subject" "it overlaps ''${share_names[i]}"
        fi
      done
      if [ "''${#share_paths[@]}" -eq 0 ]; then
        share_tags+=(workspace)
      else
        share_tags+=("extra''${#share_paths[@]}")
      fi
      share_paths+=("$path")
      share_modes+=("$mode")
      share_names+=("$name")
    }

    add_share "$workspace" rw "$workspace as workspace" "the workspace $workspace"

    mount_paths=()
    mount_modes=()
    for ((i = 0; i < ''${#mount_fields[@]}; i += 2)); do
      entry="[[mounts]] entry $((i / 2 + 1))"
      mode=''${mount_fields[i + 1]}
      resolve_entry_dir "$entry" "''${mount_fields[i]}"
      add_share "$entry_dir" "$mode" "$entry_dir ($entry)" "$entry_dir of $entry"
      mount_paths+=("$entry_dir")
      mount_modes+=("$mode")
    done

    # in_shared_dir PATH succeeds when canonical PATH lies inside the
    # workspace or a [[mounts]] directory, through which the guest already
    # sees it at the same path.
    in_shared_dir() {
      local share_path
      for share_path in "$workspace" "''${mount_paths[@]}"; do
        if contains "$share_path" "$1"; then
          return 0
        fi
      done
      return 1
    }
  '';

  summary = ''
    printf 'claudevm: %-9s  rw  %s\n' workspace "$workspace"
    for i in "''${!mount_paths[@]}"; do
      printf 'claudevm: %-9s  %s  %s  (claudevm.toml)\n' mount "''${mount_modes[i]}" "''${mount_paths[i]}"
    done
  '';

  write = ''
    share_sockets=()
    for i in "''${!share_paths[@]}"; do
      printf '%s\0%s\0%s\0' "''${share_tags[i]}" "''${share_paths[i]}" "''${share_modes[i]}"
      share_sockets+=("''${share_tags[i]}.sock")
    done > "$runtime/launch/shares"
  '';

  setup = ''
    ${readWorkspace}
    # hasTrustDialogAccepted is the record of an accepted workspace trust
    # dialog. Claude Code requires it, in an interactive session and in a
    # -p run alike, before it applies the hooks, permissions,
    # extraKnownMarketplaces and enabledPlugins of a repository's
    # .claude/settings.json and loads the plugins under its
    # .claude/skills/<name>/.
    claude_json=$(${jq} --arg workspace "$workspace" \
      '.projects[$workspace].hasTrustDialogAccepted = true' ${agent.home}/.claude.json)
    printf '%s\n' "$claude_json" > ${agent.home}/.claude.json
    while ${readShare}; do
      ${checkShare}
      mkdir -p "$path"
      ${mount} -t virtiofs -o "$mode" "$tag" "$path"
    done < /mnt/launch/shares
    if [ -n "$tag" ]; then
      echo "/mnt/launch/shares ends in an incomplete share" >&2
      exit 1
    fi
  '';

  session = ''
    ${readWorkspace}
    cd "$workspace"
  '';

  # Appends a vhost-user-fs device per share to the array args. Runs with
  # the runtime directory as working directory, like virtiofsd-run.
  qemuDevices = ''
    while IFS= read -r -d "" tag && IFS= read -r -d "" _ && IFS= read -r -d "" _; do
      args+=(
        -chardev "socket,id=$tag,path=$tag.sock"
        -device "vhost-user-fs-pci,chardev=$tag,tag=$tag"
      )
    done < launch/shares
  '';

  # Serves each share of the entry with the serve function of virtiofsd-run,
  # which runs with the runtime directory as working directory.
  serveShares = ''
    while ${readShare}; do
      serve "$tag.sock" "$path" auto "$mode"
    done < launch/shares
  '';
}
