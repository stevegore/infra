# Source this to set up Vault env for interactive use.
# Add this line to ~/.bashrc (or ~/.zshrc) to make it permanent:
#
#     source ~/code/infra/scripts/vault-env.sh
#
# Provides:
#   VAULT_ADDR — always exported (just a URL, safe to be set)
#   vlogin     — function: load root token from ~/code/infra/vault-root.token
#   vlogout    — function: clear VAULT_TOKEN from this shell

export VAULT_ADDR="${VAULT_ADDR:-https://vault.stevegore.au}"

vlogin() {
  if [[ -n "$VAULT_TOKEN" ]] && vault token lookup >/dev/null 2>&1; then
    local name
    name=$(vault token lookup -format=json 2>/dev/null | jq -r '.data.display_name // .data.id')
    echo "✓ already logged in as $name (VAULT_ADDR=$VAULT_ADDR)"
    return 0
  fi

  local token_file="${VAULT_ROOT_TOKEN_FILE:-$HOME/code/infra/vault-root.token}"
  if [[ ! -r "$token_file" ]]; then
    echo "✗ no token file at $token_file"
    echo "  set VAULT_ROOT_TOKEN_FILE=<path> to override"
    return 1
  fi

  export VAULT_TOKEN="$(<"$token_file")"
  if vault token lookup >/dev/null 2>&1; then
    echo "✓ logged in via $token_file (VAULT_ADDR=$VAULT_ADDR)"
  else
    unset VAULT_TOKEN
    echo "✗ token rejected by $VAULT_ADDR"
    return 1
  fi
}

vlogout() {
  unset VAULT_TOKEN
  echo "✓ cleared VAULT_TOKEN (VAULT_ADDR=$VAULT_ADDR still set)"
}
