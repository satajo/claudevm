{ lib, writeShellApplication, coreutils, findutils, git, jq, toml2json, guest, broker }:

let
  runner = guest.microvm.declaredRunner;
  claude = lib.getExe' guest.claudevm.claudeCode "claude";
  sockets = map (share: share.socket)
    (builtins.filter (share: share.proto == "virtiofs") guest.microvm.shares);
  inputs = guest.claudevm.inputs.ordered;
  diskFds = guest.claudevm.diskFds;
  phase = name: lib.concatMapStrings (input: input.${name}) inputs;

  configTemplate = ''
    # claudevm reads this file once at launch.
    vcpu = ${toString guest.claudevm.vcpu}
    memory = ${toString guest.claudevm.memory}  # MiB
    disk = ${toString guest.claudevm.disk}  # MiB

    # forward_packages = ["nixpkgs#ripgrep", ".#mytool"]

    # plugin_mounts = ["~/code/some-plugin"]

    # [[mounts]]
    # path = "~/data"
    # writable = false
  '';

  # Checks the JSON form of claudevm.toml. On errors it prints them and
  # exits 1; otherwise it emits NUL-terminated vcpu, memory, disk, the
  # number of mounts, a path and mode (ro or rw) pair per mount, the number
  # of forward_packages entries, those entries and then the plugin_mounts
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
      (unknown_keys(["vcpu", "memory", "disk", "forward_packages", "plugin_mounts", "mounts", "graphics", "resolution"])
        | "unknown key '\(.)'"),
      (("graphics", "resolution") as $key | select(has($key)) | "'\($key)' is not implemented yet"),
      (("vcpu", "memory", "disk") as $key
        | select(has($key) and (.[$key] | is_positive_integer | not))
        | "'\($key)' must be a positive integer"),
      (select(has("disk") and (.disk | is_positive_integer) and .disk < ${toString guest.claudevm.diskMinimum})
        | "'disk' must be at least ${toString guest.claudevm.diskMinimum} (MiB)"),
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
        (.disk // ${toString guest.claudevm.disk}),
        ((.mounts // []) | length),
        ((.mounts // [])[] | .path, (if .writable then "rw" else "ro" end)),
        ((.forward_packages // []) | length),
        ((.forward_packages // [])[]),
        ((.plugin_mounts // [])[])
      end
  '';

  # The commands of claudevm, in the order that the help lists them. A
  # command runs with the arguments after its name as its positional
  # parameters; one without arguments refuses any.
  commands = [
    {
      name = "launch";
      arguments = "[claude-args...]";
      description = "run Claude Code with claude-args on this directory in a VM";
      run = ''start_vm claude "$@"'';
    }
    {
      name = "shell";
      description = "run a debug shell on this directory in a VM";
      run = "start_vm shell";
    }
    {
      name = "init";
      description = "write a default claudevm.toml here";
      run = ''
        if [ -e claudevm.toml ] || [ -L claudevm.toml ]; then
          echo "claudevm: claudevm.toml already exists" >&2
          exit 1
        fi
        printf '%s' ${lib.escapeShellArg configTemplate} > claudevm.toml
        echo "claudevm: created claudevm.toml" >&2
      '';
    }
    {
      name = "login";
      description = "store the Claude token the VM sessions use";
      run = ''
        find_claudevm_home
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
        mkdir -p "$claudevm_home"
        chmod 0700 "$claudevm_home"
        token_tmp=$(mktemp "$claudevm_home/token.XXXXXXXX")
        trap 'rm -f "$token_tmp"' EXIT
        printf '%s\n' "$token" > "$token_tmp"
        mv -fT "$token_tmp" "$token_file"
        echo "claudevm: token stored in $token_file" >&2
      '';
    }
    {
      name = "help";
      description = "print this help";
      run = "print_help";
    }
  ];

  synopsis = command:
    command.name + lib.optionalString (command ? arguments) " ${command.arguments}";
  synopsisWidth = lib.foldl' lib.max 0 (map (command: lib.stringLength (synopsis command)) commands);

  # Runs the command that the first argument names.
  dispatch = ''
    if [ "$#" -eq 0 ]; then
      usage_error "no command given"
    fi
    case $1 in
  '' + lib.concatMapStrings (command: ''
      ${command.name})
        shift
        ${lib.optionalString (!(command ? arguments)) ''
          if [ "$#" -ne 0 ]; then
            usage_error "${command.name} takes no arguments"
          fi
        ''}${command.run}
        ;;
  '') commands + ''
      *) usage_error "unknown command '$1'" ;;
    esac
  '';
in
writeShellApplication {
  name = "claudevm";
  runtimeInputs = [ coreutils findutils git jq toml2json ];
  text = ''
    print_help() {
      printf '%s\n' "usage: claudevm COMMAND" "" "commands:"
      printf '  %-${toString synopsisWidth}s  %s\n' ${lib.escapeShellArgs (lib.concatMap (command: [ (synopsis command) command.description ]) commands)}
    }

    # usage_error MESSAGE reports MESSAGE and the help and exits.
    usage_error() {
      echo "claudevm: $1" >&2
      print_help >&2
      exit 1
    }

    # Sets claudevm_home to the claudevm directory, which holds the token,
    # the disks directory and the sessions directory: CLAUDEVM_HOME, or
    # ~/claudevm when it is not set, with symlinks resolved.
    find_claudevm_home() {
      if [ -v CLAUDEVM_HOME ]; then
        case $CLAUDEVM_HOME in
          /*) ;;
          *)
            echo "claudevm: CLAUDEVM_HOME is '$CLAUDEVM_HOME', which is not an absolute path" >&2
            exit 1
            ;;
        esac
        claudevm_home=$(realpath -m "$CLAUDEVM_HOME")
      else
        claudevm_home=$(realpath -m "$HOME/claudevm")
      fi
      # The long-lived OAuth token of the user. Only the broker on the host
      # reads it; the VM never sees it.
      token_file=$claudevm_home/token
      # Where each launch creates the disk image of its VM.
      disks_dir=$claudevm_home/disks
    }

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

    # start_vm SESSION ARG... starts the VM on the working directory, with
    # the session kind SESSION, claude or shell, and the arguments ARG... of
    # claude, and waits until it powers off.
    start_vm() {
      session=$1
      shift
      find_claudevm_home

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

      # claudevm_home has its symlinks resolved; a disks directory that is a
      # symlink would put the disk images, and what chmod and the sweep of
      # stale images act on, outside it.
      if [ -L "$disks_dir" ]; then
        echo "claudevm: $disks_dir is a symlink; the disks directory must be a directory" >&2
        exit 1
      fi
      if ! mkdir -p "$disks_dir"; then
        echo "claudevm: cannot create the disks directory $disks_dir" >&2
        exit 1
      fi
      if ! chmod 0700 "$disks_dir"; then
        echo "claudevm: cannot set $disks_dir to mode 0700" >&2
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

      disk=''${config[2]}

      mount_count=''${config[3]}
      mount_fields=("''${config[@]:4:2 * mount_count}")
      forward_count=''${config[4 + 2 * mount_count]}
      forward_packages=("''${config[@]:5 + 2 * mount_count:forward_count}")
      plugin_mounts=("''${config[@]:5 + 2 * mount_count + forward_count}")

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

      # The VM sees the launch directory inside the runtime directory through
      # a share of its own, which the share checks of the inputs do not
      # cover.
      runtime_parent=$(realpath -e "''${XDG_RUNTIME_DIR:-/tmp}")
      if contains "$claudevm_home" "$runtime_parent"; then
        refuse "the launch directory under $runtime_parent" "it lies inside $claudevm_home"
      fi
      runtime=$(mktemp -d "$runtime_parent/claudevm.XXXXXXXX")
      qemu_pid=
      # The name of the disk image while it has one.
      disk_image=
      virtiofsd_pid=
      broker_pid=
      git_before=
      # The transcripts input sets this once it has created the directory.
      session_dir=
      saved_stty=$(stty -g 2>/dev/null || true)

      cleanup() {
        local status=$? git_after config_after log
        # Signals that arrive during cleanup, which would end it early, are
        # ignored; the exit status stays that of the first.
        trap "" HUP INT TERM
        if [ -n "$disk_image" ]; then
          rm -f -- "$disk_image" || true
        fi
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
        if [ -n "$session_dir" ]; then
          rmdir --ignore-fail-on-non-empty "$session_dir" || true
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
        printf 'claudevm: %-9s  %s MiB  (sparse file in %s)\n' disk "$disk" "$disks_dir"
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

      # The VM's disk is a sparse file of disk MiB that QEMU holds through
      # the only descriptors of it. It has a name only between mktemp and rm
      # and holds no data until after the rm, and the host frees it once
      # QEMU exits. A launch that ends between mktemp and rm without its
      # cleanup leaves an empty file, which a later launch deletes once it
      # is a minute old; a running launch holds its name for a few system
      # calls only.
      find "$disks_dir" -mindepth 1 -maxdepth 1 -type f -name 'disk.*' -empty -mmin +1 -delete
      if ! disk_image=$(mktemp "$disks_dir/disk.XXXXXXXX"); then
        echo "claudevm: cannot create the VM's disk image in $disks_dir" >&2
        exit 1
      fi
      # shellcheck disable=SC2094 # QEMU needs the image open read-write and read-only
      if ! exec {disk_rw}<>"$disk_image" {disk_ro}<"$disk_image"; then
        echo "claudevm: cannot open the VM's disk image $disk_image" >&2
        exit 1
      fi
      if ! rm -- "$disk_image"; then
        echo "claudevm: cannot delete the name of the VM's disk image $disk_image" >&2
        exit 1
      fi
      disk_image=
      if ! truncate -s "''${disk}M" "/proc/self/fd/$disk_rw"; then
        echo "claudevm: cannot size the VM's disk image to $disk MiB in $disks_dir" >&2
        exit 1
      fi

      # A non-interactive shell points the stdin of a background job at
      # /dev/null; <&0 keeps the terminal. The QEMU argument script of the
      # runner reads the size of the VM from CLAUDEVM_VCPU and CLAUDEVM_MEM,
      # and QEMU takes the disk image from the descriptors of
      # claudevm.diskFds.
      (
        exec ${toString diskFds.readWrite}<&"$disk_rw" ${toString diskFds.readOnly}<&"$disk_ro" {disk_rw}<&- {disk_ro}<&-
        ulimit -Sn "$share_nofile" &&
          CLAUDEVM_VCPU=$vcpu CLAUDEVM_MEM=$memory exec ${runner}/bin/microvm-run
      ) <&0 &
      qemu_pid=$!
      exec {disk_rw}<&- {disk_ro}<&-

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
    }

    ${dispatch}
  '';

  meta.description = "Start an ephemeral microVM that runs Claude Code with bypassed permissions on the current directory";
}
