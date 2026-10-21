# Rehearsal of the front door (modules/nixos/front-door.nix): an HAProxy on
# fuji and the thinkcentre in front of the site's Traefik, passing traffic to
# a Traefik that has its routes loaded, this site's or the other's.
#
#   nix build .#checks.x86_64-linux.front-door -L
#
# Traefik as in production (k3s's own, two copies, one per node, replaced one
# at a time), on its own host ports behind the front door, and the
# traefik-ready.invalid route the checks ask for.
#   1. a site is served through the front door, with the visitor's address
#      passed on; the edge's PROXY header is taken from the edge only
#   2. Traefik restarts on both nodes, one after the other, under steady
#      traffic: not one request fails (before the front door, every restart
#      gave half a minute of 404s for every site, 2026-10-21)
#   3. fuji's Traefik is gone: fuji's front door sends everything to the
#      thinkcentre's
{ pkgs, k3sPackage }:

let
  lib = pkgs.lib;
  token = pkgs.writeText "k3s-token" "rehearsal-token";
  mesh = { edge = 1; fuji = 2; thinkcentre = 3; };
  meshIP = name: "10.99.0.${toString mesh.${name}}";
  certs = pkgs.runCommand "nebula-test-certs" { nativeBuildInputs = [ pkgs.nebula ]; } ''
    mkdir $out && cd $out
    nebula-cert ca -name rehearsal -duration 8760h
    ${lib.concatStrings (lib.mapAttrsToList (name: _: ''
      nebula-cert sign -name ${name} -ip ${meshIP name}/24 -groups servers
    '') mesh)}
  '';
  addr = node: (lib.head node.networking.interfaces.eth1.ipv4.addresses).address;
  isLighthouse = name: name == "edge";
  nebulaNode = name: { nodes, ... }: {
    virtualisation.vlans = [ 1 ];
    services.nebula.networks.mesh = {
      enable = true;
      ca = "${certs}/ca.crt";
      cert = "${certs}/${name}.crt";
      key = "${certs}/${name}.key";
      isLighthouse = isLighthouse name;
      lighthouses = lib.optionals (!isLighthouse name) [ (meshIP "edge") ];
      listen.port = 4242;
      staticHostMap.${meshIP "edge"} = [ "${addr nodes.edge}:4242" ];
      firewall = {
        outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
        inbound = [ { port = "any"; proto = "any"; group = "servers"; } ];
      };
    };
    networking.hosts = lib.mkMerge (map (s: { ${meshIP s} = [ "k3s-api" ]; })
      (lib.filter (s: s != name) [ "fuji" "thinkcentre" ]));
  };

  serverFlags = name: [
    "--node-ip=${meshIP name}" "--node-external-ip=${meshIP name}" "--advertise-address=${meshIP name}"
    "--tls-san=k3s-api" "--egress-selector-mode=disabled" "--flannel-backend=wireguard-native"
    "--flannel-iface=nebula.mesh" "--flannel-external-ip"
  ];

  # Traefik as in infrastructure's kubernetes/argocd/traefik-config.yaml, on
  # the front door's ports, with a middleware on every entry point (retry
  # there): a Traefik that hasn't loaded it answers 404 for every site.
  traefikConfig = pkgs.writeText "traefik-config.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChartConfig
    metadata:
      name: traefik
      namespace: kube-system
    spec:
      valuesContent: |-
        deployment:
          replicas: 2
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - {key: kubernetes.io/hostname, operator: In, values: [fuji, thinkcentre]}
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: traefik
        updateStrategy:
          type: RollingUpdate
          rollingUpdate: {maxUnavailable: 1, maxSurge: 0}
        service:
          spec:
            type: ClusterIP
        ports:
          web:
            hostPort: 10080
            proxyProtocol:
              trustedIPs: [10.99.0.0/24]
          websecure:
            hostPort: 10443
            proxyProtocol:
              trustedIPs: [10.99.0.0/24]
        additionalArguments:
          - --entryPoints.web.http.middlewares=kube-system-retry@kubernetescrd
          - --entryPoints.websecure.http.middlewares=kube-system-retry@kubernetescrd
          # Who Traefik thinks the visitor is, for the test to read.
          - --accesslog=true
          - --accesslog.format=json
    ---
    apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: retry
      namespace: kube-system
    spec:
      retry:
        attempts: 3
        initialInterval: 100ms
  '';

  # The ready route (infrastructure's kubernetes/argocd/traefik-ready.yaml).
  readyRoute = pkgs.writeText "traefik-ready.yaml" ''
    apiVersion: v1
    kind: Service
    metadata:
      name: traefik-ping
      namespace: kube-system
    spec:
      selector:
        app.kubernetes.io/name: traefik
      ports:
        - {name: ping, port: 8080, targetPort: 8080}
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: traefik-ready
      namespace: kube-system
    spec:
      rules:
        - host: traefik-ready.invalid
          http:
            paths:
              - path: /ping
                pathType: Exact
                backend:
                  service: {name: traefik-ping, port: {number: 8080}}
  '';

  k3sNode = name: peer: { ... }: {
    imports = [ (nebulaNode name) ../modules/nixos/front-door.nix ];
    virtualisation = { memorySize = 3072; cores = 2; diskSize = 8192; };
    environment.systemPackages = [ pkgs.kubectl pkgs.jq pkgs.curl ];
    environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    # The firewall stays on: the front door has to open its own ports.
    networking.firewall.allowedTCPPorts = [ 6443 2379 2380 10250 10080 10443 ];
    networking.firewall.trustedInterfaces = [ "nebula.mesh" "flannel-wg" "cni0" ];
    networking.firewall.allowedUDPPorts = [ 4242 51820 ];
    services.k3s = {
      enable = true;
      package = k3sPackage;
      role = "server";
      tokenFile = token;
      clusterInit = name == "fuji";
      serverAddr = lib.mkIf (name != "fuji") "https://k3s-api:6443";
      images = [ k3sPackage."airgap-images-amd64-tar-zst" ];
      extraFlags = serverFlags name;
    };
    systemd.services.k3s = { after = [ "nebula@mesh.service" ]; wants = [ "nebula@mesh.service" ]; };
    dotfiles.frontDoor = { enable = true; inherit peer; };
  };
in
pkgs.testers.runNixOSTest {
  name = "front-door";

  nodes = {
    edge = { ... }: {
      imports = [ (nebulaNode "edge") ];
      networking.firewall.enable = false;
      environment.systemPackages = [ pkgs.curl ];
    };
    fuji = k3sNode "fuji" "thinkcentre";
    thinkcentre = k3sNode "thinkcentre" "fuji";
  };

  testScript = { nodes, ... }: ''
    import time

    FUJI = "${addr nodes.fuji}"
    app = """
    apiVersion: apps/v1
    kind: Deployment
    metadata: {name: app}
    spec:
      replicas: 2
      selector: {matchLabels: {app: app}}
      template:
        metadata: {labels: {app: app}}
        spec:
          containers:
            - name: app
              image: IMAGE
              imagePullPolicy: Never
              # Answers with who the visitor is, as Traefik passes it on.
              command: [sh, -c, 'mkdir -p /www/cgi-bin && printf "#!/bin/sh\\necho Content-Type: text/plain\\necho\\necho ok from $HTTP_X_FORWARDED_FOR\\n" > /www/cgi-bin/ip && chmod +x /www/cgi-bin/ip && httpd -f -p 8080 -h /www']
    ---
    apiVersion: v1
    kind: Service
    metadata: {name: app}
    spec:
      selector: {app: app}
      ports: [{port: 80, targetPort: 8080}]
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata: {name: app}
    spec:
      rules:
        - host: app.test
          http:
            paths:
              - {path: /, pathType: Prefix, backend: {service: {name: app, port: {number: 80}}}}
    """

    def client_of(tag):
        # The visitor's address as Traefik logged it, for a request carrying tag.
        return fuji.succeed(
            "kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=-1 --prefix=false | "
            f"grep -F '{tag}' | jq -r .ClientHost | tail -1").strip()

    def get(via, url, extra=""):
        return edge.succeed(f"curl -sk -m 10 {extra} --resolve app.test:443:{via} --resolve app.test:80:{via} {url}").strip()

    with subtest("1. a site through the front door, with the visitor's address"):
        start_all()
        fuji.wait_until_succeeds("kubectl get node thinkcentre | grep -w Ready", timeout=900)
        fuji.succeed("cp ${traefikConfig} /var/lib/rancher/k3s/server/manifests/traefik-config.yaml")
        fuji.wait_until_succeeds("kubectl -n kube-system get middleware retry", timeout=600)
        fuji.wait_until_succeeds(
            "[ $(kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running -o name | wc -l) -eq 2 ] && "
            "kubectl -n kube-system rollout status deploy/traefik --timeout=10s", timeout=900)
        fuji.succeed("kubectl apply -f ${readyRoute}")
        image = fuji.succeed("k3s crictl images -o json | jq -r '.images[].repoTags[]' | grep busybox | head -1").strip()
        thinkcentre.succeed("k3s crictl images | grep -q busybox")
        fuji.succeed(f"cat > /tmp/app.yaml <<'YAML'\n{app.replace('IMAGE', image)}\nYAML")
        fuji.succeed("kubectl apply -f /tmp/app.yaml && kubectl rollout status deploy/app --timeout=300s")
        edge_lan = "${addr nodes.edge}"
        fuji.wait_until_succeeds(f"curl -sk -m 5 --resolve app.test:443:{FUJI} https://app.test/cgi-bin/ip | grep -q 'ok from'", timeout=300)
        assert get(FUJI, "https://app.test/cgi-bin/ip?t=https1").startswith("ok")
        assert get(FUJI, "http://app.test/cgi-bin/ip?t=http1").startswith("ok")
        assert get("${meshIP "fuji"}", "https://app.test/cgi-bin/ip?t=edge1", "--haproxy-protocol").startswith("ok")
        time.sleep(3)
        seen = {t: client_of(f"t={t}") for t in ("https1", "http1", "edge1")}
        print("Traefik saw the visitors as:", seen)
        assert seen["https1"] == edge_lan and seen["http1"] == edge_lan, f"the visitor's address didn't come through: {seen}"
        # The edge says who the visitor is with a PROXY header, over the mesh.
        assert seen["edge1"] == "${meshIP "edge"}", seen
        # A PROXY header from anyone else is not believed: no answer at all.
        fuji.fail(f"curl -sk -m 5 --haproxy-protocol --resolve app.test:443:{FUJI} https://app.test/cgi-bin/ip")
        # The ready route answers through Traefik on both nodes.
        for m, ip in ((fuji, "${meshIP "fuji"}"), (thinkcentre, "${meshIP "thinkcentre"}")):
            m.succeed(f"curl -sk -m 5 --haproxy-protocol --resolve traefik-ready.invalid:10443:{ip} https://traefik-ready.invalid:10443/ping | grep -qx OK")

    with subtest("2. Traefik restarts on both nodes under steady traffic: nothing fails"):
        edge.succeed(
            "(end=$(( $(date +%s) + 240 )); while [ $(date +%s) -lt $end ]; do "
            f"curl -sk -m 5 -o /dev/null -w '%{{http_code}}\\n' --resolve app.test:443:{FUJI} https://app.test/cgi-bin/ip >> /tmp/codes || echo 000 >> /tmp/codes; "
            "sleep 0.2; done; touch /tmp/codes.done) >/dev/null 2>&1 &")
        time.sleep(15)
        t0 = time.time()
        fuji.succeed("kubectl -n kube-system rollout restart deploy/traefik")
        fuji.succeed("kubectl -n kube-system rollout status deploy/traefik --timeout=600s")
        print(f"TIME restart: both Traefiks replaced in ~{time.time() - t0:.0f} s")
        edge.wait_until_succeeds("test -e /tmp/codes.done", timeout=300)
        codes = edge.succeed("sort /tmp/codes | uniq -c").strip()
        print("answers during the restarts:", codes)
        bad = [l for l in codes.splitlines() if not l.strip().endswith(" 200")]
        assert not bad, f"requests failed while Traefik restarted: {bad}"

    with subtest("3. fuji's Traefik is gone: fuji's front door uses the thinkcentre's"):
        fuji.succeed("kubectl cordon fuji")
        fuji.succeed("kubectl -n kube-system delete pod -l app.kubernetes.io/name=traefik --field-selector spec.nodeName=fuji --wait=true")
        t0 = time.time()
        fuji.wait_until_succeeds(f"curl -sk -m 5 --resolve app.test:443:{FUJI} https://app.test/cgi-bin/ip | grep -q 'ok from'", timeout=60)
        print(f"TIME gone: served through the thinkcentre after ~{time.time() - t0:.0f} s")
        for _ in range(20):
            assert get(FUJI, "https://app.test/cgi-bin/ip").startswith("ok from"), "a request failed with fuji's Traefik gone"
        fuji.succeed("kubectl uncordon fuji")
        fuji.wait_until_succeeds("kubectl -n kube-system rollout status deploy/traefik --timeout=10s", timeout=600)
  '';
}
