# claudevm

Runs Claude Code with `--dangerously-skip-permissions` in an ephemeral QEMU
microVM (microvm.nix). The VM can write the current directory and the extra
directories `claudevm.toml` marks writable; it can read the host nix store,
the read-only extra directories and the plugin directories `claudevm.toml`
lists; nothing else on the host filesystem is shared. Claude Code in the VM
starts from the image's own defaults and gets nothing from `~/.claude`. Your
login token stays on the host, behind a broker that the VM reaches with a
per-session dummy key. When the session ends the VM powers off and all its
state outside the shared directories is gone.

## Usage

```
nix run /path/to/claudevm -- login                  # store your token, once
cd ~/projects/some-repo
nix run /path/to/claudevm -- init                   # write ./claudevm.toml
nix run /path/to/claudevm                           # start Claude Code
nix run /path/to/claudevm -- "summarize this repo"  # arguments go to claude
```

To install `claudevm`, use `nix profile install /path/to/claudevm`, or add
the flake as an input and its `packages.x86_64-linux.default` to your
packages. The commands are then `claudevm`, `claudevm init`,
`claudevm login` and `claudevm shell`.

`claudevm` takes what `claude` takes: every argument other than the `init`,
`login` and `shell` subcommands goes to the Claude Code running in the VM.

Boot waits for the guest network and takes about ten seconds. When Claude
Code exits, the VM powers off and `claudevm` cleans up; a failed guest mount
also powers it off. Processes that Claude Code leaves running get SIGTERM
and three seconds to exit; any still running then are killed, and the VM
powers off five seconds later. Nothing else in the VM delays the power-off,
and every write a process in the VM completed has reached the host before
it; a file that a killed process was still writing stays as far as it got.
SIGINT, SIGHUP or SIGTERM stops QEMU, virtiofsd and the broker.

- `claudevm shell` gives a debug shell instead of Claude Code, and takes no
  arguments. `claude` works in it with the same API access as the session.
- The guest boots quietly: kernel and firmware messages stay off the console
  so that the launch output above them remains readable.
- The terminal size is applied once at launch; resizes do not reach the
  serial console. Host environment variables other than `TERM` stay out.
- The exit status is QEMU's, not Claude Code's; 1 if a launch check fails, a
  `forward_packages` build fails, or virtiofsd or the broker dies
  mid-session; 2 on a usage error; 129/130/143 on SIGHUP/SIGINT/SIGTERM.

### Token

Every launch requires a token in `~/.config/claudevm/token`
(`$XDG_CONFIG_HOME/claudevm/token` when `XDG_CONFIG_HOME` is an absolute
path) and refuses to start without one. `claudevm login` stores it:

- On a terminal it runs `claude setup-token` on the host, which signs you in
  through the browser and prints a long-lived OAuth token, and then asks you
  to paste that token; the input is hidden.
- Otherwise it reads the token as one line from stdin and runs nothing, for
  example `claudevm login < token.txt`.
- The token must start with `sk-ant-oat` and consist of printable ASCII
  without whitespace, as the one `claude setup-token` prints does. API keys
  (`sk-ant-api...`) are refused. The token replaces any stored token and is
  written with mode 0600 into a directory with mode 0700.
- A launch refuses a token file that it cannot read or that grants group or
  other any access.

The token is never copied into the VM. Each launch starts a broker on the
host loopback and gives the guest only a random API key made for that
session. Claude Code in the guest sends its API requests to the broker,
which accepts those that carry the session key, swaps the key for the token
and passes them on to `api.anthropic.com`.

## Configuration

Every start of the VM requires a `claudevm.toml` in the working directory.
`claudevm init` writes one with the defaults and refuses to overwrite an
existing file. `claudevm` reads it once at launch, so edits made during a
session apply from the next launch. Every key is optional:

```toml
vcpu = 4          # default 4, clamped to 1..host CPUs
memory = 4096     # MiB, default 4096, clamped to 512..host MemTotal
forward_packages = ["nixpkgs#ripgrep", ".#mytool", "~/code/tool#cli"]
plugin_mounts = ["~/code/some-plugin", "/opt/claude-plugins/review"]

[[mounts]]        # one table per extra host directory
path = "~/data"   # absolute, or starting with ~/
writable = false  # default false: read-only
```

- Unknown keys, wrong types, values that are not positive integers and empty
  `forward_packages` or `plugin_mounts` entries are errors, reported before
  anything starts. `graphics` and `resolution` are reserved and rejected as
  not implemented yet.
- A clamped value is shown as `(clamped from N)`. `memory = 2048` launches
  with 2047 MiB, because QEMU's microvm machine hangs at boot with exactly
  2 GiB.
- A mount appears in the guest at its host path with symlinks resolved.
  Read-only mounts are enforced by virtiofsd on the host. Files written to a
  writable mount are owned by you on the host.
- `claudevm` refuses a mount path that does not exist, is not a directory,
  is or contains `$HOME` (directories under it are fine), contains
  `~/.claude`, `~/.claude.json`, the token file or its directory, lies
  inside `~/.claude`, contains a directory the guest system needs, such as
  `/etc`, `/tmp` or `/var` (directories under them are fine), or overlaps
  the workspace, `/nix`, a guest path the VM uses (`/mnt/launch`,
  `/home/agent`) or another mount.
- `forward_packages` puts programs on the agent's PATH. Each entry is a nix
  flake installable, passed as written to `nix build` on the host except
  that a leading `~/` is expanded, so `ripgrep` alone fails where
  `nixpkgs#ripgrep` works. Relative references such as `.#mytool` resolve
  against the workspace.
- The builds run at launch, before the VM starts, with your nix settings
  and under nix's normal build sandbox. The first build of an entry may
  need network access and take a while; later launches reuse what is already
  in the host store. A failed build aborts the launch with nix's error.
- Every `bin` directory among the outputs `nix build` produces for an entry
  goes on the agent's PATH, ahead of the rest of PATH and in the order
  listed; an entry without one is an error. The VM reads them through its
  share of the host nix store and downloads nothing. The built paths are
  kept from garbage collection until the session ends.
- `plugin_mounts` lists host plugin directories for the session's Claude
  Code. Each entry is a path written like a mount path, absolute or starting
  with `~/`, and names a directory that contains
  `.claude-plugin/plugin.json`; the launch fails on one that does not. The
  directory is shared read-only at its host path, with symlinks resolved and
  the same refusals as a mount, and Claude Code loads the plugins in the
  order listed, each with `--plugin-dir`. A directory inside the workspace
  or a mount is already visible at its path, so it gets no share of its own
  and keeps that share's mode; entries must not overlap one another.
- The plugins reach the Claude Code that the session starts. `claude` run by
  hand in `claudevm shell` loads them only when given `--plugin-dir` itself.
- A plugin shipped inside the repository needs no mount: Claude Code loads a
  plugin placed at `.claude/skills/<name>/` with its own
  `.claude-plugin/plugin.json`. It does so only in a trusted workspace, and
  the image's defaults trust the workspace.
- `claudevm.toml` lives in the workspace, so it is visible and editable
  inside the VM by design. Every launch prints the effective configuration
  after the builds and before the VM starts: the workspace, each mount with
  `ro` or `rw`, one `plugin` line per `plugin_mounts` entry, with `ro` when
  the entry has a share of its own, each `forward_packages` entry, vcpu,
  memory, and the broker's port and token file.

## What the VM can and cannot do

```
Host                            Guest
----                            -----
$PWD                rw   --->   same path
[[mounts]] dirs     ro   --->   same path             rw with writable = true
plugin_mounts dirs  ro   --->   same path
/nix/store          ro   --->   /nix/.ro-store        plus a writable overlay
token               brokered    the guest holds a per-session dummy key
~/.claude           not shared
~/.claude.json      not shared
host loopback       blocked except the broker's port and DNS
LAN                 blocked except DNS, as are CGNAT, link-local, multicast
host's resolver     DNS through 10.0.2.3, which QEMU forwards to it
internet            outbound over IPv4 only, nothing inbound
everything else     not shared
```

- Paths: every shared directory, the workspace included, appears in the
  guest where it is on the host, at its path with symlinks resolved, so
  absolute paths and symlinks between shared directories keep their meaning
  in the VM. The session starts in the workspace.
- Workspace: shared read-write over virtiofs, live in both directions. Files
  the agent creates are owned by you on the host. `claudevm` refuses a
  workspace whose path, after resolving symlinks, is or contains `$HOME`,
  `~/.claude`, `~/.claude.json`, the token file or its directory, lies
  inside `~/.claude`, contains a directory the guest system needs, such as
  `/etc`, `/tmp` or `/var`, or overlaps `/nix` or a guest path the VM uses
  (`/mnt/launch`, `/home/agent`).
- Claude config: Claude Code starts from the image's defaults, which mark
  onboarding as completed, the bypass permissions prompt as accepted and the
  workspace as trusted, select the dark theme, turn off syncing of the
  plugins enabled on your claude.ai account, and turn off nonessential
  traffic and auto-updates. Nothing comes from the host's `~/.claude` or
  `~/.claude.json`. Project config comes from the workspace, where Claude
  Code reads `CLAUDE.md`, `.claude/` and `.mcp.json` as it does on the host
  in a trusted folder. Transcripts, prompt history and the rest of the VM's
  own Claude state are discarded with the VM, so `claude --resume` does not
  work across runs.
- Token: the guest holds only the session's dummy key. Its Claude Code sends
  API requests to the broker on the host loopback, which QEMU's user-mode
  networking exposes at 10.0.2.2. The broker swaps the key for the token and
  passes the requests on; the token itself never enters the VM.
- Startup prompts: the session starts without the onboarding, the trust
  prompt, the bypass permissions prompt and the API key approval prompt. The
  guest tells Claude Code that it runs in a sandbox, which keeps the trust
  prompt away, and the image's defaults carry the answers, including the
  trust of the workspace and the approval of the session's key.
- Network: QEMU user-mode networking with DHCP and DNS, over IPv4 only;
  IPv6 is off. QEMU sends guest traffic out through the host's network
  stack, so the guest firewall rejects the destinations that are the host
  or its LAN: private, CGNAT, link-local, multicast and broadcast
  addresses, among them 10.0.2.2, through which QEMU reaches the host's
  loopback services. It makes three exceptions: the DHCP client's requests
  to QEMU at 10.0.2.2; DNS through 10.0.2.3, which QEMU forwards to the
  first nameserver in the host's `/etc/resolv.conf`, such as
  systemd-resolved on the host's loopback or a router on the LAN; and the
  broker's TCP port on 10.0.2.2, which the guest admits at boot.
- Nix: flakes are enabled; `nix develop` and `nix build` work inside.
- Hardening: the guest has no nested virtualization, no user namespaces, no
  io_uring and no setuid or file-capability programs, `sudo` included. Its
  kernel loads no line discipline on demand and none of the blacklisted
  modules of unused devices, socket families and netlink protocols. Claude
  Code's own sandbox mode and other tools built on bubblewrap therefore do
  not work in the VM; `nix build` does.
- Git: `claudevm` warns at launch if `.git` is a file (linked worktrees,
  submodules); git will not work inside the VM then. After the session it
  prints a NOTICE if `.git`, `.git/config` or `.git/hooks` changed.

## What the sandbox does not protect

- The workspace is fully writable, including `.git`. The NOTICE reports git
  metadata changes; it does not prevent them. Writable mounts are as exposed
  as the workspace.
- Workspace content can steer tools you later run there on the host, such as
  git hooks and config or build scripts. Treat it after a session as you
  would a freshly cloned repository.
- A launch with `forward_packages` builds whatever the named flakes define,
  including a workspace flake the agent may have edited: the same trust as
  running `nix build` in that repository yourself.
- The internet is open, so anything readable inside the VM, including the
  entire host nix store, can in principle be sent out.
- A host service listening on a public IPv4 address of the host is
  reachable: the guest firewall tells destinations apart by address range
  and cannot tell the host's public address from the rest of the internet.
- Everything that runs in the VM is one trust domain with one guest key: a
  dependency, a build script or an MCP server there can do whatever the
  agent can.
- Anything running in the VM can send API requests through the broker while
  the session lasts, and so use your account; it cannot read the token.
- The workspace and writable mounts can grow until the host filesystem they
  live on is full, so a runaway process in the VM can fill the host disk.
- Shared directories are shared as they are, so a symlink inside one
  resolves inside the VM, not on the host: it reaches a host file only when
  that file lies in a shared directory too.

## Requirements

- x86_64 Linux host with Nix and flakes enabled.
- `/dev/kvm` writable by you. There is no software-emulation fallback.
- Unprivileged user namespaces for virtiofsd's sandbox (Ubuntu 24.04's
  AppArmor policy blocks them by default).
- A token stored with `claudevm login`. `claude setup-token`, which makes
  one, requires a Claude subscription.

## Tuning

VM size, extra mounts, plugin mounts and forwarded packages are set per
project in `claudevm.toml` and take effect at the next launch without rebuilding
`claudevm`. `claudevm.vcpu` and `claudevm.memory` in `nix/guest.nix` are the
defaults that `claudevm init` writes and that apply to a key the file leaves
out. `claudevm.claudeCode` is the Claude Code of the VM and of
`claudevm login`, by default the `claude-code` of the nixpkgs in
`flake.lock`.
