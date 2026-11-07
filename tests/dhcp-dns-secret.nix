{ lib, ... }:
{
  # Public fixture identity and ciphertext; never use this key outside tests.
  sops.age.keyFile = "/var/lib/sops-test/age-key.txt";
  sops.age.generateKey = false;
  sops.age.sshKeyPaths = [ ];
  sops.secrets.gateway-ddns.sopsFile = lib.mkForce ./fixtures/dhcp-dns-secret.yaml;
  systemd.tmpfiles.rules = [
    "d /var/lib/sops-test 0700 root root -"
    "C /var/lib/sops-test/age-key.txt 0600 root root - ${./fixtures/dhcp-dns-age-key.txt}"
  ];
  systemd.services.sops-install-secrets = {
    requires = [ "systemd-tmpfiles-setup.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
  };
}
