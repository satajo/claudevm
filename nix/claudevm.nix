{ lib, writeShellApplication, coreutils, findutils, jq, toml2json, guest, broker }:

let
  runner = guest.microvm.declaredRunner;
  claude = lib.getExe' guest.claudevm.claudeCode "claude";
  sockets = map (share: share.socket)
    (builtins.filter (share: share.proto == "virtiofs") guest.microvm.shares);

  # Guest paths the VM itself relies on. An extra share appears in the guest
  # at its host path, so it must not overlap any of them.
  guestPaths = [ "/nix" guest.users.users.agent.home ]
    ++ map (share: share.mountPoint) guest.microvm.shares;

  configTemplate = ''
    # claudevm reads this file once at launch.
    vcpu = ${toString guest.claudevm.vcpu}
    memory = ${toString guest.claudevm.memory}  # MiB

    # forward_packages = ["nixpkgs#ripgrep", ".#mytool"]

    # plugins = ["./plugins/mine", "~/code/some-plugin", ".#my-plugin"]

    # [[mounts]]
    # path = "~/data"
    # writable = false
  '';

  # Checks the JSON form of claudevm.toml. On errors it prints them and
  # exits 1; otherwise it emits NUL-terminated vcpu, memory, the number of
  # mounts, a path and mode (ro or rw) pair per mount, the number of
  # forward_packages entries, those entries and then the plugins entries.
  parseConfig = ''
    def is_positive_integer: type == "number" and (tojson | test("^[1-9][0-9]*$"));
    def unknown_keys($known): keys_unsorted[] | select(IN($known[]) | not);
    def string_array_errors($key):
      select(has($key)) | .[$key]
      | if type != "array" then "'\($key)' must be an array of strings"
        else to_entries[] | "\($key) entry \(.key + 1)" as $entry | .value
          | if type != "string" then "\($entry) must be a string"
            elif . == "" then "\($entry) must not be empty"
            elif explode | any(. == 0) then "\($entry) must not contain NUL"
            else empty end
        end;
    def errors:
      (unknown_keys(["vcpu", "memory", "forward_packages", "plugins", "mounts", "graphics", "resolution"])
        | "unknown key '\(.)'"),
      (("graphics", "resolution") as $key | select(has($key)) | "'\($key)' is not implemented yet"),
      (("vcpu", "memory") as $key
        | select(has($key) and (.[$key] | is_positive_integer | not))
        | "'\($key)' must be a positive integer"),
      string_array_errors("forward_packages"),
      string_array_errors("plugins"),
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
        ((.mounts // []) | length),
        ((.mounts // [])[] | .path, (if .writable then "rw" else "ro" end)),
        ((.forward_packages // []) | length),
        ((.forward_packages // [])[]),
        ((.plugins // [])[])
      end
  '';
in
writeShellApplication {
  name = "claudevm";
  runtimeInputs = [ coreutils findutils jq toml2json ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: claudevm [claude-args...]  run Claude Code on this directory in a VM
           claudevm init             write a default claudevm.toml here
           claudevm login            store the Claude token the VM sessions use
           claudevm shell            run a debug shell in the VM
    EOF
    }

    # A relative XDG_CONFIG_HOME is invalid and leaves the default in place.
    case ''${XDG_CONFIG_HOME-} in
      /*) config_dir=$XDG_CONFIG_HOME/claudevm ;;
      *) config_dir=$HOME/.config/claudevm ;;
    esac
    # The long-lived OAuth token of the user. Only the broker on the host
    # reads it; the VM never sees it.
    token_file=$config_dir/token

    # Everything that is not one of the subcommands is an argument of the
    # Claude Code the VM runs, so that claudevm takes what claude takes.
    session=claude
    case ''${1-} in
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
      login)
        if [ "$#" -ne 1 ]; then
          usage
          exit 2
        fi
        # On a terminal, claude setup-token signs in through the browser and
        # prints a token for pasting. Otherwise stdin carries the token.
        token=
        if [ -t 0 ]; then
          if ! ${claude} setup-token; then
            echo "claudevm: claude setup-token failed" >&2
            exit 1
          fi
          printf 'Paste the token: ' >&2
          read -rs token || true
          echo >&2
        else
          read -r token || true
        fi
        if [ -z "$token" ]; then
          echo "claudevm: no token given" >&2
          exit 1
        fi
        # The C locale makes the range below the bytes of printable ASCII.
        LC_ALL=C
        if ! [[ $token =~ ^[!-~]+$ ]]; then
          echo "claudevm: the token must consist of printable ASCII characters without whitespace, as the one claude setup-token prints does" >&2
          exit 1
        fi
        # The broker sends the token as an OAuth bearer token. OAuth tokens,
        # among them the long-lived ones of claude setup-token, start with
        # sk-ant-oat; API keys start with sk-ant-api and fail there.
        case $token in
          sk-ant-oat*) ;;
          *)
            echo "claudevm: the token must start with sk-ant-oat, as the one claude setup-token prints does; API keys (sk-ant-api...) do not work" >&2
            exit 1
            ;;
        esac
        umask 077
        mkdir -p "$config_dir"
        chmod 0700 "$config_dir"
        token_tmp=$(mktemp "$config_dir/token.XXXXXXXX")
        trap 'rm -f "$token_tmp"' EXIT
        printf '%s\n' "$token" > "$token_tmp"
        mv -fT "$token_tmp" "$token_file"
        echo "claudevm: token stored in $token_file" >&2
        exit 0
        ;;
      shell)
        session=shell
        shift
        if [ "$#" -ne 0 ]; then
          usage
          exit 2
        fi
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

    config_error() {
      echo "claudevm: claudevm.toml: $1" >&2
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

    if [ ! -e "$token_file" ]; then
      echo "claudevm: no token at $token_file; run 'claudevm login'" >&2
      exit 1
    fi
    if [ ! -f "$token_file" ]; then
      echo "claudevm: $token_file is not a regular file" >&2
      exit 1
    fi
    if [ ! -r "$token_file" ]; then
      echo "claudevm: cannot read the token at $token_file; run 'claudevm login'" >&2
      exit 1
    fi
    token_mode=$(stat -L -c %a "$token_file")
    if (( 8#$token_mode & 8#077 )); then
      echo "claudevm: $token_file has mode $token_mode, which grants group or other access; run chmod 600 $token_file" >&2
      exit 1
    fi

    # Nothing the VM can read or write may contain these.
    workspace=$(realpath -e .)
    protected=(
      "$(realpath -e "$HOME")"
      "$(realpath -e "$config_dir")"
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
    for path in "''${protected[@]}"; do
      if contains "$workspace" "$path"; then
        refuse "$workspace as workspace" "it contains $path"
      fi
    done
    if [ -n "$claude_dir" ] && contains "$claude_dir" "$workspace"; then
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

    mount_count=''${config[2]}
    mount_fields=("''${config[@]:3:2 * mount_count}")
    forward_count=''${config[3 + 2 * mount_count]}
    forward_packages=("''${config[@]:4 + 2 * mount_count:forward_count}")
    plugins=("''${config[@]:4 + 2 * mount_count + forward_count}")

    # Host directories shared with the guest besides the workspace, each at
    # its host path, with the claudevm.toml entry that asked for it and its
    # mode (ro or rw).
    extra_paths=()
    extra_entries=()
    extra_modes=()

    # share_extra PATH ENTRY MODE adds canonical directory PATH to the extra
    # shares unless the VM must not see it.
    share_extra() {
      local path=$1 entry=$2 mode=$3 protected_path guest_path i
      for protected_path in "''${protected[@]}"; do
        if contains "$path" "$protected_path"; then
          refuse "$path ($entry)" "it contains $protected_path"
        fi
      done
      if [ -n "$claude_dir" ] && contains "$claude_dir" "$path"; then
        refuse "$path ($entry)" "it lies inside $claude_dir"
      fi
      if overlaps "$workspace" "$path"; then
        refuse "$path ($entry)" "it overlaps the workspace $workspace"
      fi
      for guest_path in ${lib.escapeShellArgs guestPaths}; do
        if overlaps "$guest_path" "$path"; then
          refuse "$path ($entry)" "it overlaps $guest_path, which the VM uses"
        fi
      done
      for i in "''${!extra_paths[@]}"; do
        if overlaps "''${extra_paths[i]}" "$path"; then
          refuse "$path ($entry)" "it overlaps ''${extra_paths[i]} of ''${extra_entries[i]}"
        fi
      done
      extra_paths+=("$path")
      extra_entries+=("$entry")
      extra_modes+=("$mode")
    }

    mount_paths=()
    mount_modes=()
    for ((i = 0; i < ''${#mount_fields[@]}; i += 2)); do
      entry="[[mounts]] entry $((i / 2 + 1))"
      path=''${mount_fields[i]}
      case $path in
        \~/*) path=$HOME/''${path#\~/} ;;
        /*) ;;
        *) config_error "$entry: path '$path' must be absolute or start with ~/" ;;
      esac
      if [ ! -e "$path" ]; then
        refuse "$path ($entry)" "it does not exist"
      fi
      mount_path=$(realpath -e -- "$path")
      if [ ! -d "$mount_path" ]; then
        refuse "$mount_path ($entry)" "it is not a directory"
      fi
      share_extra "$mount_path" "$entry" "''${mount_fields[i + 1]}"
      mount_paths+=("$mount_path")
      mount_modes+=("''${mount_fields[i + 1]}")
    done

    # A plugins entry that starts with /, ~/ or ./ is a plugin directory on
    # the host, with ./ relative to the workspace. The guest reads one inside
    # the workspace through /workspace and any other through an extra share.
    # Every other entry is a flake installable whose single output is the
    # plugin directory, which the guest reads through its store share.
    #   plugin_kinds[i]        workspace, shared or store
    #   plugin_guest_paths[i]  directory the guest loads the plugin from
    plugin_kinds=()
    plugin_guest_paths=()
    for i in "''${!plugins[@]}"; do
      entry="plugins entry $((i + 1))"
      path=''${plugins[i]}
      case $path in
        /*) ;;
        \~/*) path=$HOME/''${path#\~/} ;;
        ./*) path=$workspace/''${path#./} ;;
        *)
          plugin_kinds[i]=store
          continue
          ;;
      esac
      if [ ! -e "$path" ]; then
        config_error "$entry: $path does not exist"
      fi
      plugin_path=$(realpath -e -- "$path")
      if [ ! -d "$plugin_path" ]; then
        config_error "$entry: $plugin_path is not a directory"
      fi
      if [ ! -f "$plugin_path/.claude-plugin/plugin.json" ]; then
        config_error "$entry: $plugin_path is not a Claude Code plugin: .claude-plugin/plugin.json is missing"
      fi
      if contains "$workspace" "$plugin_path"; then
        plugin_kinds[i]=workspace
        plugin_guest_paths[i]=/workspace''${plugin_path#"$workspace"}
      else
        share_extra "$plugin_path" "$entry" ro
        plugin_kinds[i]=shared
        plugin_guest_paths[i]=$plugin_path
      fi
    done

    if [ ! -w /dev/kvm ]; then
      echo "claudevm: /dev/kvm is missing or not writable; the VM requires KVM" >&2
      exit 1
    fi

    runtime=$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/claudevm.XXXXXXXX")
    qemu_pid=
    virtiofsd_pid=
    broker_pid=
    git_before=
    saved_stty=$(stty -g 2>/dev/null || true)

    cleanup() {
      local status=$? git_after log
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
      if [ -n "$broker_pid" ]; then
        kill "$broker_pid" 2>/dev/null || true
        wait "$broker_pid" 2>/dev/null || true
      fi
      if [ "$status" -ne 0 ]; then
        for log in virtiofsd.log broker.log; do
          if [ -s "$runtime/$log" ]; then
            cat "$runtime/$log" >&2
          fi
        done
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

    # The guest sees the host's /nix/store, so a package built here needs no
    # download in the VM. The working directory is still the workspace, so
    # relative flake references resolve against it. Each out-link in the
    # runtime directory is a GC root that keeps the build for the session;
    # nix names it fwd<entry> or plg<entry>, plus -<output> for an output
    # other than out.
    forward_installables=()
    forward_dirs=()
    for i in "''${!forward_packages[@]}"; do
      entry="forward_packages entry $((i + 1))"
      installable=''${forward_packages[i]}
      case $installable in
        \~/*) installable=$HOME/''${installable#\~/} ;;
      esac
      if ! out_paths=$(nix build --print-out-paths --out-link "$runtime/fwd$((i + 1))" -- "$installable"); then
        config_error "$entry: building '$installable' failed"
      fi
      bin_dirs=()
      while IFS= read -r out_path; do
        case $out_path in
          /nix/store/*) ;;
          *) config_error "$entry: '$installable' built $out_path, which lies outside /nix/store, the only store the VM sees" ;;
        esac
        if [ -d "$out_path/bin" ]; then
          bin_dirs+=("$out_path/bin")
        fi
      done <<< "$out_paths"
      if [ "''${#bin_dirs[@]}" -eq 0 ]; then
        config_error "$entry: '$installable' provides no executables; none of its outputs has a bin directory: ''${out_paths//$'\n'/ }"
      fi
      forward_installables+=("$installable")
      forward_dirs+=("''${bin_dirs[@]}")
    done

    for i in "''${!plugins[@]}"; do
      if [ "''${plugin_kinds[i]}" != store ]; then
        continue
      fi
      entry="plugins entry $((i + 1))"
      installable=''${plugins[i]}
      if ! out_paths=$(nix build --print-out-paths --out-link "$runtime/plg$((i + 1))" -- "$installable"); then
        config_error "$entry: building '$installable' failed"
      fi
      mapfile -t plugin_outputs <<< "$out_paths"
      if [ "''${#plugin_outputs[@]}" -ne 1 ]; then
        config_error "$entry: '$installable' built ''${#plugin_outputs[@]} outputs, ''${plugin_outputs[*]}; a plugin must be exactly one"
      fi
      plugin_path=''${plugin_outputs[0]}
      case $plugin_path in
        /nix/store/*) ;;
        *) config_error "$entry: '$installable' built $plugin_path, which lies outside /nix/store, the only store the VM sees" ;;
      esac
      if [ ! -f "$plugin_path/.claude-plugin/plugin.json" ]; then
        config_error "$entry: '$installable' built $plugin_path, which is not a Claude Code plugin: .claude-plugin/plugin.json is missing"
      fi
      plugin_guest_paths[i]=$plugin_path
    done

    if [ -f "$workspace/.git" ]; then
      echo "claudevm: warning: $workspace/.git is a file whose git directory lies outside the workspace; git will not work inside the VM" >&2
    fi

    # The guest authenticates to the broker with this per-session key, which
    # the broker replaces with the token on the way to the Anthropic API.
    guest_key=sk-ant-api03-claudevm-$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    (umask 077 && printf '%s\n' "$guest_key" > "$runtime/guest-key")

    # The broker listens on a free port of the host loopback, which it writes
    # to the port file atomically once it accepts connections.
    ${broker}/bin/claudevm-broker \
      --port-file "$runtime/broker.port" \
      --token-file "$token_file" \
      --guest-key-file "$runtime/guest-key" \
      > "$runtime/broker.log" 2>&1 &
    broker_pid=$!
    tries=0
    until [ -s "$runtime/broker.port" ]; do
      if ! kill -0 "$broker_pid" 2>/dev/null; then
        echo "claudevm: broker exited before it reported its port" >&2
        exit 1
      fi
      tries=$((tries + 1))
      if [ "$tries" -gt 100 ]; then
        echo "claudevm: broker reported no port within 10 seconds" >&2
        exit 1
      fi
      sleep 0.1
    done
    broker_port=$(< "$runtime/broker.port")
    if ! [[ $broker_port =~ ^[1-9][0-9]{0,4}$ ]] || [ "$broker_port" -gt 65535 ]; then
      echo "claudevm: broker reported '$broker_port', which is not a port" >&2
      exit 1
    fi

    {
      printf 'claudevm: %-9s  rw  %s\n' workspace "$workspace"
      for i in "''${!mount_paths[@]}"; do
        printf 'claudevm: %-9s  %s  %s  (claudevm.toml)\n' mount "''${mount_modes[i]}" "''${mount_paths[i]}"
      done
      for i in "''${!plugins[@]}"; do
        if [ "''${plugin_kinds[i]}" = shared ]; then
          printf 'claudevm: %-9s  ro  %s  (claudevm.toml)\n' plugin "''${plugin_guest_paths[i]}"
        else
          printf 'claudevm: %-9s  %s  (claudevm.toml)\n' plugin "''${plugin_guest_paths[i]}"
        fi
      done
      for installable in "''${forward_installables[@]}"; do
        printf 'claudevm: %-9s  %s  (claudevm.toml)\n' forward "$installable"
      done
      printf 'claudevm: %-9s  %s%s\n' vcpu "$vcpu" "$vcpu_note"
      printf 'claudevm: %-9s  %s MiB%s\n' memory "$memory" "$memory_note"
      printf 'claudevm: %-9s  127.0.0.1:%s -> api.anthropic.com  (token %s)\n' broker "$broker_port" "$token_file"
      echo "claudevm: claude config: image defaults only; token stays on the host; network: outbound only, host loopback blocked except the broker"
    } >&2

    ln -s "$workspace" "$runtime/workspace"
    mkdir "$runtime/launch"

    {
      printf 'TERM=%q\n' "''${TERM:-xterm-256color}"
      # The serial console carries no window size, so the guest applies the
      # launch-time size once.
      if size=$(stty size 2>/dev/null); then
        printf 'ROWS=%q\n' "''${size% *}"
        printf 'COLS=%q\n' "''${size#* }"
      fi
      printf 'CLAUDEVM_SESSION=%q\n' "$session"
      printf 'CLAUDEVM_BROKER_PORT=%q\n' "$broker_port"
      printf 'CLAUDEVM_GUEST_KEY=%q\n' "$guest_key"
    } > "$runtime/launch/env"

    for arg in "$@"; do printf '%s\0' "$arg"; done > "$runtime/launch/claude-args"

    # Tag, guest path and mode of each extra share, read by virtiofsd-run,
    # by the QEMU argument script and by the guest. Each tag is served on
    # the socket <tag>.sock.
    extra_sockets=()
    for i in "''${!extra_paths[@]}"; do
      printf 'extra%s\0%s\0%s\0' "$i" "''${extra_paths[i]}" "''${extra_modes[i]}"
      extra_sockets+=("extra$i.sock")
    done > "$runtime/launch/mounts"

    # Bin directories of the forward_packages, read by the guest, which puts
    # them first on PATH in this order.
    for dir in "''${forward_dirs[@]}"; do printf '%s\0' "$dir"; done > "$runtime/launch/forward-path"

    # Guest paths of the plugin directories, read by the guest, which loads
    # each into Claude Code in this order.
    for dir in "''${plugin_guest_paths[@]}"; do printf '%s\0' "$dir"; done > "$runtime/launch/plugin-dirs"

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
    wait -n -p finished "$qemu_pid" "$virtiofsd_pid" "$broker_pid" || status=$?
    if [ "$finished" = "$broker_pid" ]; then
      broker_pid=
      echo "claudevm: broker exited during the session" >&2
      exit 1
    fi
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
