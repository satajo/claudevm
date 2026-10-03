{ config, lib, pkgs, ... }:

let
  cfg = config.claudevm;
in
{
  options.claudevm = {
    vcpu = lib.mkOption {
      type = lib.types.ints.positive;
      description = "vCPUs of a launch whose claudevm.toml sets no vcpu.";
    };
    memory = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Guest RAM in MiB of a launch whose claudevm.toml sets no memory.";
    };
    claudeCode = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "Claude Code package of the guest, also used by claudevm login on the host.";
    };
  };

  config = {
    networking.hostName = "claudevm";
    system.stateVersion = lib.trivial.release;

    nixpkgs.config.allowUnfreePredicate = pkg:
      lib.getName pkg == "claude-code";

    claudevm = {
      vcpu = 4;
      memory = 4096;
    };

    assertions = [
      {
        assertion = cfg.memory >= config.microvm.mem;
        message = "claudevm.memory must be at least microvm.mem (${toString config.microvm.mem} MiB)";
      }
    ];

    microvm = {
      hypervisor = "qemu";
      mem = 512;
      # The host CPU without the virtualization extensions svm and vmx, so
      # the guest kernel cannot run a hypervisor, and without sgx, with
      # which QEMU's microvm machine crashes.
      cpu = "host,+x2apic,-sgx,-svm,-vmx";
      qemu = {
        # microvm.nix defaults to the QEMU of every target architecture once
        # microvm.cpu is set; qemu_kvm, built for the host's architecture
        # only, keeps the closure about 600 MiB smaller.
        package = pkgs.qemu_kvm;
        # The runner's own serial console adds earlyprintk=ttyS0 to the
        # kernel command line, which makes the boot loader and the kernel
        # report their progress on the console the session appears on.
        # Serving the same chardev here leaves the command line to
        # boot.kernelParams.
        serialConsole = false;
        extraArgs = [
          # qboot, unlike the SeaBIOS that QEMU loads by default, prints no
          # version banner and resets no terminal, so the launch output
          # stays on screen.
          "-bios"
          "${config.microvm.qemu.package}/share/qemu/qboot.rom"
          "-serial"
          "chardev:stdio"
          # -enable-kvm, which the runner passes only while microvm.cpu is
          # unset, makes KVM required rather than tried before TCG.
          "-enable-kvm"
        ];
      };
    };

    # quiet also silences systemd's unit status lines. Log level 3 keeps
    # kernel messages less severe than critical off the console, among them
    # the harmless "PCI: Fatal: No config space access function found" of the
    # microvm machine; the journal still has them all. Mount failures and the
    # emergency shutdown come from systemd, which writes to the console
    # itself.
    boot.kernelParams = [ "console=ttyS0" "quiet" ];
    boot.consoleLogLevel = 3;

    # virtiofsd translates this uid and the gid of the users group (100) to
    # the invoking host user's ids, so the host ids are free to differ.
    users.users.agent = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };

    environment.systemPackages = [
      cfg.claudeCode
      pkgs.git
    ];
  };
}
