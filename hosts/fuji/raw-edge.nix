# Public raw TCP/UDP edge for services hosted on ThinkCentre.
# Router forwards these ports to Fuji; Fuji relays them over Tailscale.
{ ... }:

{
  networking.firewall.interfaces.eno1 = {
    allowedTCPPorts = [
      6767   # Minecraft HC
      51751  # Minecraft HC SFTP
      25565  # Minecraft Skyblock
    ];

    allowedUDPPorts = [
      19132  # Minecraft Bedrock
      24545  # MegaBopl3D
      5520   # Hytale
    ];
  };

  services.nginx = {
    enable = true;
    virtualHosts = {};

    streamConfig = ''
      server {
        listen 6767;
        proxy_pass 100.64.0.4:6767;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
      }

      server {
        listen 51751;
        proxy_pass 100.64.0.4:51751;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
      }

      server {
        listen 25565;
        proxy_pass 100.64.0.4:25565;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
      }

      server {
        listen 19132 udp reuseport;
        proxy_pass 100.64.0.4:19132;
        proxy_timeout 2m;
      }

      server {
        listen 24545 udp reuseport;
        proxy_pass 100.64.0.4:24545;
        proxy_timeout 2m;
      }

      server {
        listen 5520 udp reuseport;
        proxy_pass 100.64.0.4:5520;
        proxy_timeout 2m;
      }
    '';
  };
}
