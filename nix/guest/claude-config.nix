{ config, lib, pkgs, ... }:

let
  agent = config.users.users.agent;

  # The Claude Code config of the image, which every session starts from
  # and nothing from the host adds to. Claude Code asks once per
  # installation to accept bypass permissions mode and records the answer
  # in settings.json; syncClaudeAiPlugins = false keeps the plugins enabled
  # on the claude.ai account out of the VM.
  claudeSettings = pkgs.writeText "claude-settings.json" (builtins.toJSON {
    skipDangerousModePermissionPrompt = true;
    syncClaudeAiPlugins = false;
  });
  # claudevm-home adds the guest key of the launch to the approved custom
  # API keys. Claude Code looks an approved key up by its last 20
  # characters; the full key is approved as well so that either lookup
  # matches. claudevm-home also sets hasTrustDialogAccepted for the
  # workspace, the record of an accepted workspace trust dialog. Claude
  # Code requires it, in an interactive session and in a -p run alike,
  # before it applies the hooks, permissions, extraKnownMarketplaces and
  # enabledPlugins of a repository's .claude/settings.json and loads the
  # plugins under its .claude/skills/<name>/.
  claudeState = pkgs.writeText "claude.json" (builtins.toJSON {
    hasCompletedOnboarding = true;
    theme = "dark";
    customApiKeyResponses.rejected = [ ];
  });
in
{
  options.claudevm.homeSteps.claudeConfig = lib.mkOption {
    type = lib.types.str;
    internal = true;
    readOnly = true;
    description = "Step of the claudevm-home script that installs the Claude Code config of the image for agent.";
  };

  config.claudevm.homeSteps.claudeConfig = ''
    install -d -o ${agent.name} -g ${agent.group} -m 0700 ${agent.home}/.claude
    install -o ${agent.name} -g ${agent.group} -m 0600 ${claudeSettings} ${agent.home}/.claude/settings.json
    install -o ${agent.name} -g ${agent.group} -m 0600 /dev/null ${agent.home}/.claude.json
    jq --arg key "$CLAUDEVM_GUEST_KEY" --arg workspace "$CLAUDEVM_WORKSPACE" \
      '.customApiKeyResponses.approved = [$key, $key[-20:]]
       | .projects[$workspace].hasTrustDialogAccepted = true' \
      ${claudeState} > ${agent.home}/.claude.json
  '';
}
