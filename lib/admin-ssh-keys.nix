# Public SSH keys of the admin devices. Every server trusts exactly these for
# interactive login, including early-boot disk unlock. Servers do not trust
# each other: purpose-limited keys (e.g. Borg's forced `borg serve`) are set
# where they are used. To add or revoke a device, edit this list and rebuild.
{
  nixpad = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHzmOPD3cWDvEfnVfzAlvDA29wqEH+YNUCJmZneE+K3k fuji-server";
  workstation = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIP0XJEU56o+KB9aZkRR+hGRotn5tbnHd7xfqGFXJt2U nixa@nix-wks";
  phone = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFXk0DZv+Bya+P8YvT9maRontQ4QGaDiDDvnuxcLuanN ed25519-key-20260928";
}
