# The host data a launch hands the VM. Each input is one file here, one
# entry under /mnt/launch named after that file and at most one block of
# the launch summary, and holds both halves as shell fragments:
#
#   collect  host, before the VM starts: reads, checks and prepares host
#            state and may fail the launch
#   summary  host: its lines of the launch summary
#   write    host: writes its entry under $runtime/launch and nothing else
#   setup    guest, as root in claudevm-home, before the session
#   session  guest, as agent in claude-session, just before the exec
#
# The launcher runs every collect, then every summary, then every write,
# each in the order of this list, all in the launcher's one shell, so an
# input's summary and write use what its collect set and an input may use
# what an earlier one defined. In the guest, claudevm-home runs every setup
# and claude-session every session, each in list order and each in a shell
# of its own, so setup and session share nothing and each reads the entry
# itself. Every input relies on the launcher's runtime; each names the
# other variables and functions it uses from outside at its top.
{ config, lib, pkgs }:

let
  call = file: import file { inherit config lib pkgs; };
in
rec {
  descriptorBudget = call ./descriptor-budget.nix;
  shares = call ./shares.nix;
  transcripts = call ./transcripts.nix;
  plugins = call ./plugins.nix;
  forwardPackages = call ./forward-packages.nix;
  gitIdentity = call ./git-identity.nix;
  brokerAccess = call ./broker-access.nix;
  terminal = call ./terminal.nix;
  command = call ./command.nix;

  # transcripts and plugins add their directories through the add_share of
  # shares, and the setup of transcripts binds the share that shares
  # mounts. add_share also reads session_dir, which the launcher sets
  # empty and transcripts, though later in this list, sets before it calls
  # add_share. The session fragment of shares cds into the workspace, and
  # command, whose session fragment execs into Claude Code with the
  # plugin_args of plugins or into the debug shell, comes last.
  ordered = [
    descriptorBudget
    shares
    transcripts
    plugins
    forwardPackages
    gitIdentity
    brokerAccess
    terminal
    command
  ];
}
