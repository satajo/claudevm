{ config, lib, pkgs, ... }:

let
  agent = config.users.users.agent;

  claudeSession = pkgs.writeShellApplication {
    name = "claude-session";
    text = ''
      # Claude Code shows no workspace trust dialog when this says it runs
      # in a sandbox. The trust that repository content needs comes from
      # hasTrustDialogAccepted in ~/.claude.json, which claudevm-home sets.
      export CLAUDE_CODE_SANDBOXED=1
      export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      export DISABLE_AUTOUPDATER=1
      export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
      ${lib.concatMapStrings (input: input.session) config.claudevm.inputs.ordered}
    '';
  };
in
{
  # The session owns the serial console instead of a login prompt.
  systemd.services."serial-getty@ttyS0".enable = false;

  # A failed mount starts emergency mode, in the initrd and in stage 2
  # alike, which with the locked root account would leave the VM running
  # with no session. The initrd has no logind, which systemctl poweroff
  # asks first, printing an error, so there emergency mode starts
  # poweroff.target itself.
  systemd.services.emergency.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${config.systemd.package}/bin/systemctl --no-block poweroff"
  ];
  boot.initrd.systemd.services.emergency.serviceConfig.ExecStart = [
    ""
    "systemctl --no-block start poweroff.target"
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
      # file system lives in RAM, the disk's content is discarded with the
      # launch, and virtiofsd-run serves the shares without writeback
      # caching, so a write to a shared directory has reached the host
      # when the write call returns.
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
