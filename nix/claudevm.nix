{ lib, writeShellApplication, coreutils, findutils, jq, toml2json, guest, broker }:

let
  runner = guest.microvm.declaredRunner;
  claude = lib.getExe' guest.claudevm.claudeCode "claude";
  sockets = map (share: share.socket)
    (builtins.filter (share: share.proto == "virtiofs") guest.microvm.shares);

  # Guest paths the VM itself relies on. Every shared host directory, the
  # workspace included, appears in the guest at its host path, so none may
  # overlap any of them.
  guestPaths = [ "/nix" guest.users.users.agent.home ]
    ++ map (share: share.mountPoint) guest.microvm.shares;

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
    "/tmp/claude-${toString guest.users.users.agent.uid}"
  ];

  configTemplate = ''
    # claudevm reads this file once at launch.
    vcpu = ${toString guest.claudevm.vcpu}
    memory = ${toString guest.claudevm.memory}  # MiB

    # forward_packages = ["nixpkgs#ripgrep", ".#mytool"]

    # plugin_mounts = ["~/code/some-plugin"]

    # [[mounts]]
    # path = "~/data"
    # writable = false
  '';

  # Checks the JSON form of claudevm.toml. On errors it prints them and
  # exits 1; otherwise it emits NUL-terminated vcpu, memory, the number of
  # mounts, a path and mode (ro or rw) pair per mount, the number of
  # forward_packages entries, those entries and then the plugin_mounts
  # entries.
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
      (unknown_keys(["vcpu", "memory", "forward_packages", "plugin_mounts", "mounts", "graphics", "resolution"])
        | "unknown key '\(.)'"),
      (("graphics", "resolution") as $key | select(has($key)) | "'\($key)' is not implemented yet"),
      (("vcpu", "memory") as $key
        | select(has($key) and (.[$key] | is_positive_integer | not))
        | "'\($key)' must be a positive integer"),
      string_array_errors("forward_packages"),
      string_array_errors("plugin_mounts"),
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
        ((.plugin_mounts // [])[])
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

    # The host directories shared with the guest at their host paths, in
    # the order of the launch input "mounts": virtiofs tag, canonical path,
    # mode (ro or rw), and the name a refusal of a later, overlapping share
    # gives it.
    share_tags=()
    share_paths=()
    share_modes=()
    share_names=()

    # add_share TAG PATH MODE SUBJECT NAME adds canonical directory PATH to
    # the shares unless the VM must not see it. SUBJECT names PATH in its own
    # refusal and NAME in the refusal of a later share that overlaps it.
    add_share() {
      local tag=$1 path=$2 mode=$3 subject=$4 name=$5 protected_path guest_path i
      for protected_path in "''${protected[@]}"; do
        if contains "$path" "$protected_path"; then
          refuse "$subject" "it contains $protected_path"
        fi
      done
      if [ -n "$claude_dir" ] && contains "$claude_dir" "$path"; then
        refuse "$subject" "it lies inside $claude_dir"
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
      share_tags+=("$tag")
      share_paths+=("$path")
      share_modes+=("$mode")
      share_names+=("$name")
    }

    add_share workspace "$workspace" rw "$workspace as workspace" "the workspace $workspace"

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
    plugin_mounts=("''${config[@]:4 + 2 * mount_count + forward_count}")

    # resolve_entry_dir ENTRY PATH sets entry_dir to the canonical path of
    # the directory that claudevm.toml entry ENTRY names by PATH, which is
    # absolute or starts with ~/.
    resolve_entry_dir() {
      local entry=$1 path=$2
      case $path in
        \~/*) path=$HOME/''${path#\~/} ;;
        /*) ;;
        *) config_error "$entry: path '$path' must be absolute or start with ~/" ;;
      esac
      if [ ! -e "$path" ]; then
        refuse "$path ($entry)" "it does not exist"
      fi
      entry_dir=$(realpath -e -- "$path")
      if [ ! -d "$entry_dir" ]; then
        refuse "$entry_dir ($entry)" "it is not a directory"
      fi
    }

    mount_paths=()
    mount_modes=()
    for ((i = 0; i < ''${#mount_fields[@]}; i += 2)); do
      entry="[[mounts]] entry $((i / 2 + 1))"
      mode=''${mount_fields[i + 1]}
      resolve_entry_dir "$entry" "''${mount_fields[i]}"
      add_share "extra''${#share_paths[@]}" "$entry_dir" "$mode" "$entry_dir ($entry)" "$entry_dir of $entry"
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

    # The plugin_mounts directories in claudevm.toml order, each with "own"
    # when it has a read-only share of its own and "within" when the guest
    # sees it through the workspace or a [[mounts]] share.
    plugin_dirs=()
    plugin_shares=()
    for i in "''${!plugin_mounts[@]}"; do
      entry="plugin_mounts entry $((i + 1))"
      resolve_entry_dir "$entry" "''${plugin_mounts[i]}"
      if [ ! -f "$entry_dir/.claude-plugin/plugin.json" ]; then
        config_error "$entry: $entry_dir is not a Claude Code plugin: .claude-plugin/plugin.json is missing"
      fi
      for j in "''${!plugin_dirs[@]}"; do
        if overlaps "''${plugin_dirs[j]}" "$entry_dir"; then
          refuse "$entry_dir ($entry)" "it overlaps ''${plugin_dirs[j]} of plugin_mounts entry $((j + 1))"
        fi
      done
      if in_shared_dir "$entry_dir"; then
        plugin_shares+=(within)
      else
        add_share "extra''${#share_paths[@]}" "$entry_dir" ro "$entry_dir ($entry)" "$entry_dir of $entry"
        plugin_shares+=(own)
      fi
      plugin_dirs+=("$entry_dir")
    done

    if [ ! -w /dev/kvm ]; then
      echo "claudevm: /dev/kvm is missing or not writable; the VM requires KVM" >&2
      exit 1
    fi

    # virtiofsd holds a host descriptor for every inode of its share that
    # the guest holds and another for every file the guest has open. QEMU's
    # user networking holds a host socket for every guest connection, every
    # ICMP echo request and every guest UDP source port, the last two for up
    # to 240 s each; the guest's fs.file-max does not bound these, and once
    # QEMU has spent its limit, new guest connections fail until old ones
    # expire. Each virtiofsd gets the hard limit of open files as
    # --rlimit-nofile and QEMU as its soft limit, raised in the subshell
    # that starts it. The broker and everything else the launcher runs keep
    # the soft limit claudevm starts with, which bounds the broker's
    # connections. Each virtiofsd runs a thread per host CPU, keeps
    # claudevm.virtiofsdReservedFds descriptors and one per thread for
    # itself and answers the guest with ENFILE once the guest holds the
    # rest, share_fds, which the guest reads from the launch input "env". A
    # booted guest holds about 2500 descriptors on the store share; the VM
    # requires a hard limit of at least 65536 so that this stays a small
    # part of share_fds.
    share_nofile=$(ulimit -Hn)
    if ! [[ $share_nofile =~ ^[1-9][0-9]*$ ]]; then
      echo "claudevm: the hard limit of open files is '$share_nofile', not a number" >&2
      exit 1
    fi
    if [ "$share_nofile" -lt 65536 ]; then
      echo "claudevm: the hard limit of open files (ulimit -Hn) is $share_nofile; the VM requires at least 65536" >&2
      exit 1
    fi
    share_threads=$host_vcpu
    share_fds=$((share_nofile - ${toString guest.claudevm.virtiofsdReservedFds} - share_threads))

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
        config_error "$entry: building '$installable' failed"
      fi
      bin_dirs=()
      while IFS= read -r out_path; do
        case $out_path in
          /nix/store/*) ;;
          *) config_error "$entry: '$installable' built $out_path, which lies outside /nix/store, the only store the VM sees" ;;
        esac
        forward_outputs+=("$out_path")
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
      for i in "''${!plugin_dirs[@]}"; do
        case ''${plugin_shares[i]} in
          own) printf 'claudevm: %-9s  ro  %s  (claudevm.toml)\n' plugin "''${plugin_dirs[i]}" ;;
          within) printf 'claudevm: %-9s  %s  (claudevm.toml)\n' plugin "''${plugin_dirs[i]}" ;;
        esac
      done
      for installable in "''${forward_installables[@]}"; do
        printf 'claudevm: %-9s  %s  (claudevm.toml)\n' forward "$installable"
      done
      printf 'claudevm: %-9s  %s%s\n' vcpu "$vcpu" "$vcpu_note"
      printf 'claudevm: %-9s  %s MiB%s\n' memory "$memory" "$memory_note"
      printf 'claudevm: %-9s  127.0.0.1:%s -> api.anthropic.com  (token %s)\n' broker "$broker_port" "$token_file"
      echo "claudevm: claude config: image defaults only; token stays on the host; network: IPv4 internet only; LAN, CGNAT, link-local, multicast and host loopback blocked except the broker and DNS"
    } >&2

    # From here on the launcher creates files and directories that only
    # their owner can access; virtiofsd sets its own umask for the files
    # the guest creates. The guest sees the launch input at /mnt/launch with
    # its owner mapped to agent, so in the guest only agent and root can
    # read it, the guest key in env included.
    umask 077
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
      printf 'CLAUDEVM_WORKSPACE=%q\n' "$workspace"
      printf 'CLAUDEVM_BROKER_PORT=%q\n' "$broker_port"
      printf 'CLAUDEVM_GUEST_KEY=%q\n' "$guest_key"
      printf 'CLAUDEVM_SHARE_FDS=%q\n' "$share_fds"
    } > "$runtime/launch/env"

    for arg in "$@"; do printf '%s\0' "$arg"; done > "$runtime/launch/claude-args"

    # Tag, path and mode of each share, read by virtiofsd-run, by the QEMU
    # argument script and by the guest, which mounts it at the same path as
    # the host has it. Each tag is served on the socket <tag>.sock.
    share_sockets=()
    for i in "''${!share_paths[@]}"; do
      printf '%s\0%s\0%s\0' "''${share_tags[i]}" "''${share_paths[i]}" "''${share_modes[i]}"
      share_sockets+=("''${share_tags[i]}.sock")
    done > "$runtime/launch/mounts"

    # Bin directories of the forward_packages, read by the guest, which puts
    # them first on PATH in this order.
    for dir in "''${forward_dirs[@]}"; do printf '%s\0' "$dir"; done > "$runtime/launch/forward-path"

    # Store paths of the forward_packages outputs, each once, which the
    # guest makes garbage collection roots.
    for out_path in "''${forward_outputs[@]}"; do printf '%s\0' "$out_path"; done \
      | LC_ALL=C sort -zu > "$runtime/launch/forward-outputs"

    # Nix validity registration of the closure of those outputs, which the
    # guest loads into its Nix database; empty without outputs, for which
    # nix-store --query prints nothing. nix-store --dump-db without paths
    # dumps the host's whole database, so xargs -r runs it only when there
    # are paths.
    if ! nix-store --query --requisites "''${forward_outputs[@]}" \
        | xargs -r -d '\n' nix-store --dump-db > "$runtime/launch/forward-registration"; then
      echo "claudevm: cannot read the nix registration of the forward_packages closure" >&2
      exit 1
    fi

    # Paths of the plugin_mounts directories, which the guest sees at their
    # host paths and loads into Claude Code in this order.
    for dir in "''${plugin_dirs[@]}"; do printf '%s\0' "$dir"; done > "$runtime/launch/plugin-dirs"

    git_before=$(git_fingerprint) || git_before=unreadable

    # Share sources and socket paths are relative to the runtime directory.
    cd "$runtime"

    CLAUDEVM_SHARE_NOFILE=$share_nofile CLAUDEVM_SHARE_THREADS=$share_threads \
      ${runner}/bin/virtiofsd-run > virtiofsd.log 2>&1 &
    virtiofsd_pid=$!

    # qemu connects to every vhost-user socket at startup and fails if one
    # is missing.
    for sock in ${lib.escapeShellArgs sockets} "''${share_sockets[@]}"; do
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
    (
      ulimit -Sn "$share_nofile" &&
        CLAUDEVM_VCPU=$vcpu CLAUDEVM_MEM=$memory exec ${runner}/bin/microvm-run
    ) <&0 &
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
