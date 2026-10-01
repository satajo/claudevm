{ lib, writeShellApplication, coreutils, findutils, jq, toml2json, guest }:

let
  runner = guest.microvm.declaredRunner;
  sockets = map (share: share.socket)
    (builtins.filter (share: share.proto == "virtiofs") guest.microvm.shares);

  # Guest paths the VM itself relies on. An extra mount appears in the guest
  # at its host path, so it must not overlap any of them.
  guestPaths = [ "/nix" guest.users.users.agent.home ]
    ++ map (share: share.mountPoint) guest.microvm.shares;

  configTemplate = ''
    # claudevm reads this file once at launch.
    vcpu = ${toString guest.claudevm.vcpu}
    memory = ${toString guest.claudevm.memory}  # MiB

    # [[mounts]]
    # path = "~/data"
    # writable = false
  '';

  # Checks the JSON form of claudevm.toml. On errors it prints them and
  # exits 1; otherwise it emits NUL-terminated vcpu and memory followed by
  # a path and mode (ro or rw) pair per mount.
  parseConfig = ''
    def is_positive_integer: type == "number" and (tojson | test("^[1-9][0-9]*$"));
    def unknown_keys($known): keys_unsorted[] | select(IN($known[]) | not);
    def errors:
      (unknown_keys(["vcpu", "memory", "mounts", "graphics", "resolution"]) | "unknown key '\(.)'"),
      (("graphics", "resolution") as $key | select(has($key)) | "'\($key)' is not implemented yet"),
      (("vcpu", "memory") as $key
        | select(has($key) and (.[$key] | is_positive_integer | not))
        | "'\($key)' must be a positive integer"),
      (select(has("mounts")) | .mounts
        | if type != "array" then "'mounts' must be an array of tables ([[mounts]])"
          else to_entries[] | "[[mounts]] entry \(.key + 1)" as $entry | .value
            | if type != "object" then "\($entry) must be a table"
              else
                (unknown_keys(["path", "writable"]) | "\($entry): unknown key '\(.)'"),
                (if has("path") | not then "\($entry): 'path' is missing"
                 elif .path | type != "string" then "\($entry): 'path' must be a string"
                 elif .path | explode | any(. == 0) then "\($entry): 'path' must not contain NUL"
                 else empty end),
                (select(has("writable") and (.writable | type != "boolean"))
                  | "\($entry): 'writable' must be true or false")
              end
          end);
    [errors] as $errors
    | if $errors != [] then
        $errors | map("claudevm: claudevm.toml: \(.)\n") | add | halt_error(1)
      else
        (.vcpu // ${toString guest.claudevm.vcpu}),
        (.memory // ${toString guest.claudevm.memory}),
        ((.mounts // [])[] | .path, (if .writable then "rw" else "ro" end))
      end
  '';
in
writeShellApplication {
  name = "claudevm";
  runtimeInputs = [ coreutils findutils jq toml2json ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: claudevm launch [claude-args...]  run Claude Code on this directory in a VM
           claudevm shell                    run a debug shell instead of Claude Code
           claudevm init                     write a default claudevm.toml here
    EOF
    }

    case ''${1-} in
      launch)
        session=claude
        shift
        ;;
      shell)
        session=shell
        shift
        if [ "$#" -ne 0 ]; then
          usage
          exit 2
        fi
        ;;
      init)
        if [ "$#" -ne 1 ]; then
          usage
          exit 2
        fi
        if [ -e claudevm.toml ] || [ -L claudevm.toml ]; then
          echo "claudevm: claudevm.toml already exists" >&2
          exit 1
        fi
        printf '%s' ${lib.escapeShellArg configTemplate} > claudevm.toml
        echo "claudevm: created claudevm.toml" >&2
        exit 0
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 2
        ;;
    esac

    # Succeeds when canonical path $2 equals canonical path $1 or lies
    # inside it.
    contains() {
      case $1 in
        /) return 0 ;;
      esac
      case $2 in
        "$1" | "$1"/*) return 0 ;;
        *) return 1 ;;
      esac
    }

    overlaps() {
      contains "$1" "$2" || contains "$2" "$1"
    }

    refuse() {
      echo "claudevm: refusing to share $1: $2" >&2
      exit 1
    }

    # Digest of the git metadata through which git runs commands on the
    # host: the .git entry itself, .git/config and .git/hooks.
    git_fingerprint() {
      local git=$workspace/.git path
      {
        if [ -e "$git" ] || [ -L "$git" ]; then
          find "$git" -maxdepth 0 -printf '%p %y %m %l\n' -type f -exec sha256sum {} +
        fi
        for path in "$git/config" "$git/hooks"; do
          if [ -e "$path" ] || [ -L "$path" ]; then
            find "$path" -printf '%p %y %m %l\n' -type f -exec sha256sum {} +
          fi
        done
      } | sort | sha256sum
    }

    if [ ! -e claudevm.toml ]; then
      echo "claudevm: no claudevm.toml in $PWD; run 'claudevm init' to create one" >&2
      exit 1
    fi

    if [ ! -d "$HOME/.claude" ]; then
      echo "claudevm: $HOME/.claude not found; log in with claude on the host first" >&2
      exit 1
    fi

    workspace=$(realpath -e .)
    claude_dir=$(realpath -e "$HOME/.claude")
    protected=("$(realpath -e "$HOME")" "$claude_dir")
    if [ -e "$HOME/.claude.json" ]; then
      protected+=("$(realpath -e "$HOME/.claude.json")")
    fi
    for path in "''${protected[@]}"; do
      if contains "$workspace" "$path"; then
        refuse "$workspace as workspace" "it contains $path"
      fi
    done
    if contains "$claude_dir" "$workspace"; then
      refuse "$workspace as workspace" "it lies inside $claude_dir"
    fi

    if ! config_json=$(toml2json claudevm.toml); then
      echo "claudevm: claudevm.toml is not valid TOML" >&2
      exit 1
    fi
    mapfile -d "" -t config < <(jq --raw-output0 ${lib.escapeShellArg parseConfig} <<< "$config_json")
    wait "$!"

    vcpu=''${config[0]}
    vcpu_note=
    host_vcpu=$(nproc)
    if [ "$vcpu" -gt "$host_vcpu" ]; then
      vcpu_note="  (clamped from $vcpu)"
      vcpu=$host_vcpu
    fi

    memory=''${config[1]}
    memory_note=
    host_memory=
    while read -r key value _; do
      if [ "$key" = MemTotal: ]; then
        host_memory=$((value / 1024))
      fi
    done < /proc/meminfo
    if [ -z "$host_memory" ]; then
      echo "claudevm: cannot read MemTotal from /proc/meminfo" >&2
      exit 1
    fi
    if [ "$memory" -gt "$host_memory" ]; then
      memory_note="  (clamped from $memory)"
      memory=$host_memory
    elif [ "$memory" -lt ${toString guest.microvm.mem} ]; then
      memory_note="  (clamped from $memory)"
      memory=${toString guest.microvm.mem}
    fi
    # QEMU's microvm machine hangs at boot when guest RAM ends exactly at
    # 2 GiB. With 2047 MiB the guest has as much usable memory as with 2049.
    if [ "$memory" -eq 2048 ]; then
      memory_note="$memory_note  (adjusted from 2048, which hangs QEMU's microvm machine)"
      memory=2047
    fi

    mount_paths=()
    mount_modes=()
    for ((i = 2; i < ''${#config[@]}; i += 2)); do
      entry="[[mounts]] entry $((i / 2))"
      path=''${config[i]}
      case $path in
        \~/*) path=$HOME/''${path#\~/} ;;
        /*) ;;
        *)
          echo "claudevm: claudevm.toml: $entry: path '$path' must be absolute or start with ~/" >&2
          exit 1
          ;;
      esac
      if [ ! -e "$path" ]; then
        refuse "$path ($entry)" "it does not exist"
      fi
      mount_path=$(realpath -e -- "$path")
      if [ ! -d "$mount_path" ]; then
        refuse "$mount_path ($entry)" "it is not a directory"
      fi
      for protected_path in "''${protected[@]}"; do
        if contains "$mount_path" "$protected_path"; then
          refuse "$mount_path ($entry)" "it contains $protected_path"
        fi
      done
      if contains "$claude_dir" "$mount_path"; then
        refuse "$mount_path ($entry)" "it lies inside $claude_dir"
      fi
      if overlaps "$workspace" "$mount_path"; then
        refuse "$mount_path ($entry)" "it overlaps the workspace $workspace"
      fi
      for guest_path in ${lib.escapeShellArgs guestPaths}; do
        if overlaps "$guest_path" "$mount_path"; then
          refuse "$mount_path ($entry)" "it overlaps $guest_path, which the VM uses"
        fi
      done
      for other in "''${mount_paths[@]}"; do
        if overlaps "$other" "$mount_path"; then
          refuse "$mount_path ($entry)" "it overlaps $other of an earlier entry"
        fi
      done
      mount_paths+=("$mount_path")
      mount_modes+=("''${config[i + 1]}")
    done

    if [ ! -w /dev/kvm ]; then
      echo "claudevm: /dev/kvm is missing or not writable; the VM requires KVM" >&2
      exit 1
    fi

    if [ -f "$workspace/.git" ]; then
      echo "claudevm: warning: $workspace/.git is a file whose git directory lies outside the workspace; git will not work inside the VM" >&2
    fi

    {
      printf 'claudevm: %-9s  rw  %s\n' workspace "$workspace"
      for i in "''${!mount_paths[@]}"; do
        printf 'claudevm: %-9s  %s  %s  (claudevm.toml)\n' mount "''${mount_modes[i]}" "''${mount_paths[i]}"
      done
      printf 'claudevm: %-9s  %s%s\n' vcpu "$vcpu" "$vcpu_note"
      printf 'claudevm: %-9s  %s MiB%s\n' memory "$memory" "$memory_note"
      echo "claudevm: claude config staged read-only; network: outbound only, host loopback blocked"
    } >&2

    runtime=$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/claudevm.XXXXXXXX")
    qemu_pid=
    virtiofsd_pid=
    git_before=
    saved_stty=$(stty -g 2>/dev/null || true)

    cleanup() {
      local status=$? git_after
      if [ -n "$saved_stty" ]; then
        stty "$saved_stty" 2>/dev/null || true
      fi
      if [ -n "$qemu_pid" ]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
      fi
      if [ -n "$virtiofsd_pid" ]; then
        kill "$virtiofsd_pid" 2>/dev/null || true
        wait "$virtiofsd_pid" 2>/dev/null || true
      fi
      if [ "$status" -ne 0 ] && [ -s "$runtime/virtiofsd.log" ]; then
        cat "$runtime/virtiofsd.log" >&2
      fi
      if [ -n "$git_before" ]; then
        if ! git_after=$(git_fingerprint) || [ "$git_after" != "$git_before" ]; then
          echo "claudevm: NOTICE: $workspace/.git, its config or its hooks changed during the session." >&2
          echo "claudevm: NOTICE: git runs commands configured there; review them before running git on the host." >&2
        fi
      fi
      rm -rf "$runtime"
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ln -s "$workspace" "$runtime/workspace"

    # Only an allowlisted part of the host's Claude config enters the VM.
    # The rest of ~/.claude and the projects map of ~/.claude.json hold
    # cross-project data such as transcripts, history and per-project state.
    mkdir -p "$runtime/launch/claude"
    for entry in settings.json CLAUDE.md keybindings.json .credentials.json \
      agents commands skills plugins hooks output-styles; do
      if [ -e "$HOME/.claude/$entry" ]; then
        cp -rL "$HOME/.claude/$entry" "$runtime/launch/claude/"
      fi
    done
    # Copies of read-only sources such as store paths must stay removable.
    chmod -R u+w "$runtime/launch/claude"
    if [ -e "$HOME/.claude.json" ]; then
      jq 'del(.projects)' "$HOME/.claude.json" > "$runtime/launch/claude.json"
    fi

    {
      printf 'TERM=%q\n' "''${TERM:-xterm-256color}"
      # The serial console carries no window size, so the guest applies the
      # launch-time size once.
      if size=$(stty size 2>/dev/null); then
        printf 'ROWS=%q\n' "''${size% *}"
        printf 'COLS=%q\n' "''${size#* }"
      fi
      printf 'CLAUDEVM_SESSION=%q\n' "$session"
    } > "$runtime/launch/env"

    for arg in "$@"; do printf '%s\0' "$arg"; done > "$runtime/launch/claude-args"

    # Tag, guest path and mode of each extra mount, read by virtiofsd-run,
    # by the QEMU argument script and by the guest. Each tag is served on
    # the socket <tag>.sock.
    extra_sockets=()
    for i in "''${!mount_paths[@]}"; do
      printf 'extra%s\0%s\0%s\0' "$i" "''${mount_paths[i]}" "''${mount_modes[i]}"
      extra_sockets+=("extra$i.sock")
    done > "$runtime/launch/mounts"

    git_before=$(git_fingerprint) || git_before=unreadable

    # Share sources and socket paths are relative to the runtime directory.
    cd "$runtime"

    ${runner}/bin/virtiofsd-run > virtiofsd.log 2>&1 &
    virtiofsd_pid=$!

    # qemu connects to every vhost-user socket at startup and fails if one
    # is missing.
    for sock in ${lib.escapeShellArgs sockets} "''${extra_sockets[@]}"; do
      tries=0
      until [ -S "$sock" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 100 ] || ! kill -0 "$virtiofsd_pid" 2>/dev/null; then
          echo "claudevm: virtiofsd failed to provide $sock" >&2
          exit 1
        fi
        sleep 0.1
      done
    done

    # A non-interactive shell points the stdin of a background job at
    # /dev/null; <&0 keeps the terminal. The QEMU argument script of the
    # runner reads the size of the VM from CLAUDEVM_VCPU and CLAUDEVM_MEM.
    CLAUDEVM_VCPU=$vcpu CLAUDEVM_MEM=$memory ${runner}/bin/microvm-run <&0 &
    qemu_pid=$!

    finished=
    status=0
    wait -n -p finished "$qemu_pid" "$virtiofsd_pid" || status=$?
    if [ "$finished" = "$virtiofsd_pid" ]; then
      virtiofsd_pid=
      # virtiofsd exits with status 0 only once qemu closes its vhost-user
      # connections, which qemu does shortly before it exits.
      if [ "$status" -ne 0 ]; then
        echo "claudevm: virtiofsd exited during the session" >&2
        exit 1
      fi
      status=0
      wait "$qemu_pid" || status=$?
    fi
    qemu_pid=
    if [ "$status" -ne 0 ]; then
      exit "$status"
    fi
  '';

  meta.description = "Start an ephemeral microVM that runs Claude Code with bypassed permissions on the current directory";
}
