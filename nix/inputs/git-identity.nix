# The identity that git on the host gives a commit made in the workspace,
# which becomes the agent's global git config.
#
# Uses from the launcher: quoted.
{ config, lib, pkgs }:

let
  agent = config.users.users.agent;
  git = lib.getExe pkgs.git;
in
{
  # user.name and user.email as the config files that apply in the
  # workspace set them together. Mostly the user's global config sets them,
  # which the VM does not see. git config exits with status 1 for a key
  # that no file sets, which the guest then lacks as well.
  collect = ''
    git_identity_keys=()
    git_identity_values=()
    for key in user.name user.email; do
      key_status=0
      value=$(git config --get "$key") || key_status=$?
      case $key_status in
        0)
          git_identity_keys+=("$key")
          git_identity_values+=("$value")
          ;;
        1) ;;
        *)
          echo "claudevm: cannot read $key from the git config" >&2
          exit 1
          ;;
      esac
    done
  '';

  summary = ''
    for i in "''${!git_identity_keys[@]}"; do
      printf 'claudevm: %-9s  %s  (git config)\n' "''${git_identity_keys[i]}" "$(quoted "''${git_identity_values[i]}")"
    done
  '';

  # The entry is a git config file that holds each identity key the host
  # sets.
  write = ''
    : > "$runtime/launch/git-identity"
    for i in "''${!git_identity_keys[@]}"; do
      git config --file "$runtime/launch/git-identity" "''${git_identity_keys[i]}" "''${git_identity_values[i]}"
    done
  '';

  # The config of the repository still takes precedence over the global
  # git config.
  setup = ''
    if ! git_identity_keys=$(${git} config --file /mnt/launch/git-identity --name-only --list); then
      echo "/mnt/launch/git-identity is not a git config file" >&2
      exit 1
    fi
    while IFS= read -r key; do
      case $key in
        "" | user.name | user.email) ;;
        *)
          echo "/mnt/launch/git-identity sets $key, which is not an identity key" >&2
          exit 1
          ;;
      esac
    done <<< "$git_identity_keys"
    install -o ${agent.name} -g ${agent.group} -m 0600 /mnt/launch/git-identity ${agent.home}/.gitconfig
  '';

  session = "";
}
