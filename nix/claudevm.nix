{ lib, writeShellApplication, coreutils, findutils, git, jq, toml2json, guest, broker }:

let
  runner = guest.microvm.declaredRunner;
  claude = lib.getExe' guest.claudevm.claudeCode "claude";
  sockets = map (share: share.socket)
    (builtins.filter (share: share.proto == "virtiofs") guest.microvm.shares);
  inputs = guest.claudevm.inputs.ordered;
  phase = name: lib.concatMapStrings (input: input.${name}) inputs;

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
  runtimeInputs = [ coreutils findutils git jq toml2json ];
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

    # Digest of claudevm.toml: the entry itself and the content that the
    # launcher reads from it, the target's when it is a symlink.
    config_fingerprint() {
      local config=$workspace/claudevm.toml
      {
        if [ -e "$config" ] || [ -L "$config" ]; then
          find "$config" -maxdepth 0 -printf '%p %y %m %l\n' -xtype f -exec sha256sum {} +
        fi
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

    workspace=$(realpath -e .)

    # The digest of claudevm.toml as this launch reads it, which the NOTICE
    # at exit compares against.
    config_before=$(config_fingerprint) || config_before=unreadable
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
      local status=$? git_after config_after log
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
      if ! config_after=$(config_fingerprint) || [ "$config_after" != "$config_before" ]; then
        echo "claudevm: NOTICE: $workspace/claudevm.toml changed since this launch read it." >&2
        echo "claudevm: NOTICE: the next launch reads it to decide which host directories the VM shares and which packages the host builds; review it before launching again." >&2
      fi
      rm -rf "$runtime"
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ${phase "collect"}

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
      ${phase "summary"}
      printf 'claudevm: %-9s  %s%s\n' vcpu "$vcpu" "$vcpu_note"
      printf 'claudevm: %-9s  %s MiB%s\n' memory "$memory" "$memory_note"
      echo "claudevm: claude config: image defaults only; token stays on the host; network: IPv4 internet only; LAN, CGNAT, link-local, multicast and host loopback blocked except the broker and DNS"
    } >&2

    # From here on the launcher creates files and directories that only
    # their owner can access; virtiofsd sets its own umask for the files
    # the guest creates. The guest sees the launch directory at /mnt/launch
    # with its owner mapped to agent, so in the guest only agent and root
    # can read it, the guest key included.
    umask 077
    mkdir "$runtime/launch"
    ${phase "write"}

    git_before=$(git_fingerprint) || git_before=unreadable

    # Share sources and socket paths are relative to the runtime directory.
    cd "$runtime"

    # share_nofile and share_threads come from the descriptor-budget input.
    CLAUDEVM_SHARE_NOFILE=$share_nofile CLAUDEVM_SHARE_THREADS=$share_threads \
      ${runner}/bin/virtiofsd-run > virtiofsd.log 2>&1 &
    virtiofsd_pid=$!

    # qemu connects to every vhost-user socket at startup and fails if one
    # is missing. share_sockets holds those of the shares input.
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
