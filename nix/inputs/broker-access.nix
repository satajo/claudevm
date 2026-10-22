# Access to the broker on the host loopback, which QEMU's user networking
# forwards 10.0.2.2 to: the broker's port and the session's guest key,
# which the broker swaps for the token. The guest key is all the guest
# holds of the API access.
#
# Uses from the launcher: broker_port, guest_key, token_file and quoted.
{ config, lib, pkgs }:

let
  agent = config.users.users.agent;

  # The entry holds the port and the guest key as NUL-terminated fields.
  # This sets broker_port and guest_key.
  readEntry = ''
    if ! { IFS= read -r -d "" broker_port && IFS= read -r -d "" guest_key && ! IFS= read -r -d "" rest && [ -z "$rest" ]; } < /mnt/launch/broker-access \
        || ! [[ $broker_port =~ ^[1-9][0-9]{0,4}$ ]] || [ "$broker_port" -gt 65535 ] \
        || ! [[ $guest_key =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "/mnt/launch/broker-access holds no port and guest key" >&2
      exit 1
    fi
  '';
in
{
  collect = "";

  summary = ''
    printf 'claudevm: %-9s  127.0.0.1:%s -> api.anthropic.com  (token %s)\n' broker "$broker_port" "$(quoted "$token_file")"
  '';

  write = ''
    printf '%s\0%s\0' "$broker_port" "$guest_key" > "$runtime/launch/broker-access"
  '';

  # The rule goes into the output chain of the egress table, ahead of the
  # rule that rejects 10.0.2.2. Claude Code looks an approved custom API key
  # up by its last 20 characters; the full key is approved as well so that
  # either lookup matches.
  setup = ''
    ${readEntry}
    ${lib.getExe pkgs.nftables} insert rule inet egress output \
      ip daddr 10.0.2.2 tcp dport "$broker_port" accept
    claude_json=$(${lib.getExe pkgs.jq} --arg key "$guest_key" \
      '.customApiKeyResponses.approved = [$key, $key[-20:]]' ${agent.home}/.claude.json)
    printf '%s\n' "$claude_json" > ${agent.home}/.claude.json
  '';

  # The session's environment carries the guest key only as
  # ANTHROPIC_API_KEY.
  session = ''
    ${readEntry}
    export ANTHROPIC_API_KEY=$guest_key
    export ANTHROPIC_BASE_URL=http://10.0.2.2:$broker_port
  '';
}
