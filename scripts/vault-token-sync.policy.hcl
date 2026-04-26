# Allows the pico AppRole to write *.token files into kv/homelab/*.
path "kv/data/homelab/*" {
  capabilities = ["create", "update", "read"]
}

path "kv/metadata/homelab/*" {
  capabilities = ["read", "list"]
}
