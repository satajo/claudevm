{ config, lib, pkgs, ... }:

let
  agent = config.users.users.agent;
in
{
  options.claudevm.homeSteps = {
    storeAcl = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      description = "Step of the claudevm-home script that lets agent reach store paths by name but not list the store.";
    };
    storeCover = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      description = "Step of the claudevm-home script that hides the store share under an empty file system.";
    };
  };

  config = {
    microvm.writableStoreOverlay = "/nix/.rw-store";

    claudevm.homeSteps = {
      storeAcl = ''
        # The guest's /nix/store shows the host's whole store. Its ACL lets
        # agent traverse it, so that every store path stays reachable by its
        # name, but not list it. The same goes for /nix/store/.links, where
        # a host that optimises its store keeps a link to every distinct
        # file of it; the ACL copies up only the directory itself. /nix/store
        # is a read-only bind mount for every process but the Nix processes
        # of root, the daemon among them, each of which remounts it
        # read-write in a mount namespace of its own; the ACLs are set the
        # same way. Their chmod of the store directory changes the ACL's
        # mask and keeps the entry for agent.
        unshare --mount -- ${pkgs.runtimeShell} -euc '
          mount -o remount,bind,rw /nix/store
          setfacl -m u:${agent.name}:x /nix/store
          if [ -e /nix/store/.links ]; then
            setfacl -m u:${agent.name}:x /nix/store/.links
          fi
        '
      '';

      storeCover = ''
        # /nix/.ro-store is the host's store itself, the lower layer of the
        # /nix/store overlay. The overlay holds its own reference to it, so
        # /nix/store keeps working under this empty root-only file system.
        # systemd counts the cover as part of the mount unit of
        # /nix/.ro-store, so only root stopping that unit removes it.
        mount -t tmpfs -o ro,nosuid,nodev,noexec,mode=0700 tmpfs /nix/.ro-store
      '';
    };

    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };
}
