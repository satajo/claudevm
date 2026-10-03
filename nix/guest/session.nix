{ config, lib, pkgs, ... }:

let
  cfg = config.claudevm;
  agent = config.users.users.agent;

  claudeSession = pkgs.writeShellApplication {
    name = "claude-session";
    runtimeInputs = [
      cfg.claudeCode
      pkgs.coreutils
      pkgs.bashInteractive
    ];
    text = ''
      set -a
      # shellcheck disable=SC1091
      . /mnt/launch/env
      set +a
      # Claude Code shows no workspace trust dialog when this says it runs
      # in a sandbox. The trust that repository content needs comes from
      # hasTrustDialogAccepted in ~/.claude.json, which claudevm-home sets.
      export CLAUDE_CODE_SANDBOXED=1
      # The guest key is all the guest holds, and the session's
      # environment carries it only as ANTHROPIC_API_KEY. The broker on the
      # host loopback, which QEMU forwards 10.0.2.2 to, swaps it for the
      # token.
      export ANTHROPIC_API_KEY=$CLAUDEVM_GUEST_KEY
      unset CLAUDEVM_GUEST_KEY
      export ANTHROPIC_BASE_URL=http://10.0.2.2:$CLAUDEVM_BROKER_PORT
      export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      export DISABLE_AUTOUPDATER=1
      export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
      ${cfg.prependForwardPath}
      if [ -n "''${ROWS:-}" ] && [ -n "''${COLS:-}" ]; then
        stty rows "$ROWS" cols "$COLS" || true
      fi
      mapfile -d "" -t args < /mnt/launch/claude-args
      # The launch input "plugin-dirs" lists the guest paths of the plugin
      # directories of the launch as NUL-terminated paths.
      mapfile -d "" -t plugin_dirs < /mnt/launch/plugin-dirs
      plugin_args=()
      for dir in "''${plugin_dirs[@]}"; do
        plugin_args+=(--plugin-dir "$dir")
      done
      cd "$CLAUDEVM_WORKSPACE"
      case $CLAUDEVM_SESSION in
        claude) exec claude --dangerously-skip-permissions "''${plugin_args[@]}" "''${args[@]}" ;;
        shell) exec bash -l ;;
      esac
      echo "claude-session: unknown CLAUDEVM_SESSION '$CLAUDEVM_SESSION'" >&2
      exit 1
    '';
  };
in
{
  # The session owns the serial console instead of a login prompt.
  systemd.services."serial-getty@ttyS0".enable = false;

  # A failed mount starts emergency mode, which with the locked root
  # account would leave the VM running with no session.
  systemd.services.emergency.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${config.systemd.package}/bin/systemctl --no-block poweroff"
  ];

  systemd.services.claude-session = {
    description = "Claude Code session on the VM console";
    requires = [ "claudevm-home.service" ];
    wants = [ "network-online.target" ];
    after = [ "claudevm-home.service" "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = [ "/mnt/launch" ];
      # The end of the session is the end of the VM. Once the unit is
      # inactive or failed, PID 1 syncs and powers off with the reboot
      # system call without stopping any other unit, so nothing else
      # running in the guest delays it; for a failed unit it waits 5 s
      # first. Nothing in the guest needs an orderly shutdown: the root
      # file system lives in RAM, and virtiofsd-run serves the shares
      # without writeback caching, so a write to a shared directory has
      # reached the host when the write call returns.
      SuccessAction = "poweroff-immediate";
      FailureAction = "poweroff-immediate";
    };
    wantedBy = [ "multi-user.target" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      Type = "idle";
      User = agent.name;
      Group = agent.group;
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/ttyS0";
      TTYReset = true;
      TTYVHangup = true;
      # "-" makes every end of the session a success, a non-zero exit
      # status or a fatal signal alike, which spares it the 5 s wait of
      # FailureAction.
      ExecStart = "-${lib.getExe claudeSession}";
      # When the session exits, the processes it leaves running get
      # SIGTERM and this long to exit before SIGKILL. A unit whose
      # processes need the SIGKILL fails.
      TimeoutStopSec = 3;
      Slice = "agent.slice";
      # systemd's default OOM policy, stop, ends a unit once the kernel
      # has killed any of its processes for lack of memory. continue
      # keeps the session, and with it the VM, running for as long as its
      # main process lives.
      OOMPolicy = "continue";
      # Every process of the session inherits both, so no program it runs
      # gains privileges, setuid or file capabilities notwithstanding.
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
    };
  };
}
