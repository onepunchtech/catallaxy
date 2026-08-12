{
  name,
  namespace,
  domain,
  cluster,
  accent,
  gatewayIP,
  reach ? "mesh",
}:

let
  viaMesh = reach == "mesh";

  headline = if viaMesh then "Delivered over the mesh" else "Delivered through the lab ingress";

  lede =
    if viaMesh then
      "This page has no public route. It reached you through the NetBird overlay, terminating on the internal gateway inside the cluster."
    else
      "This page is public. It reached you through the lab's ingress on the host, which routes by name into the cluster, with no mesh required.";

  hopA = if viaMesh then "your device" else "your browser";
  hopB = if viaMesh then "netbird mesh" else "lab ingress";
  hopC = if viaMesh then "internal gateway" else "cluster gateway";

  hopLabel = if viaMesh then "Gateway" else "Ingress";

  footer =
    if viaMesh then
      "Leave the mesh and this name stops resolving: the lab's authoritative DNS answers <code>NXDOMAIN</code> for it, and the host ingress has no route to it."
    else
      "This name lives in the lab's public zone and resolves whether or not you are on the mesh. The <code>internal</code> names alongside it do not.";

  page = ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>${cluster}: ${headline}</title>
    <style>
      :root { --accent: ${accent}; }
      * { box-sizing: border-box; }
      body {
        margin: 0; min-height: 100vh; display: grid; place-items: center;
        font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
        color: #e8ecf4;
        background: radial-gradient(1200px 800px at 50% -10%, #1b2438 0%, #0b0f17 60%);
      }
      .card { width: min(760px, 92vw); padding: 40px 44px 32px; text-align: center; }
      .eyebrow {
        text-transform: uppercase; letter-spacing: .18em; font-size: 12px;
        color: var(--accent); margin-bottom: 18px;
      }
      h1 { margin: 0 0 10px; font-size: clamp(30px, 6vw, 52px); font-weight: 650; letter-spacing: -.02em; }
      .lede { margin: 0 auto 30px; max-width: 46ch; color: #9fb0c9; }
      svg { width: 100%; height: auto; max-height: 190px; display: block; margin: 8px 0 26px; }
      .link { stroke: var(--accent); stroke-width: 2; fill: none; opacity: .85;
              stroke-dasharray: 8 10; animation: flow 1.4s linear infinite; }
      @keyframes flow { to { stroke-dashoffset: -36; } }
      .node { fill: #0b0f17; stroke: var(--accent); stroke-width: 2; }
      .pulse { fill: var(--accent); transform-origin: center; animation: pulse 2s ease-in-out infinite; }
      @keyframes pulse { 0%,100% { opacity: .25; r: 20; } 50% { opacity: .12; r: 30; } }
      .label { fill: #7f8ea6; font-size: 11px; letter-spacing: .08em; text-transform: uppercase; }
      dl { display: grid; grid-template-columns: auto 1fr; gap: 8px 18px;
           margin: 0 0 26px; text-align: left; font-size: 14px; }
      dt { color: #7f8ea6; }
      dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #cfe0f5; }
      .foot { font-size: 13px; color: #6f7f97; border-top: 1px solid #1c2434; padding-top: 18px; }
      .foot code { color: #9fb0c9; }
      @media (prefers-reduced-motion: reduce) { .link, .pulse { animation: none; } }
    </style>
    </head>
    <body>
      <main class="card">
        <div class="eyebrow">${cluster}</div>
        <h1>${headline}</h1>
        <p class="lede">${lede}</p>

        <svg viewBox="0 0 640 150" role="img" aria-label="${hopA} to ${hopB} to ${hopC}">
          <circle class="pulse" cx="70" cy="75" r="20"></circle>
          <circle class="node" cx="70" cy="75" r="13"></circle>
          <text class="label" x="70" y="118" text-anchor="middle">${hopA}</text>

          <path class="link" d="M88 75 H300"></path>

          <circle class="pulse" cx="320" cy="75" r="20" style="animation-delay:.5s"></circle>
          <circle class="node" cx="320" cy="75" r="13"></circle>
          <text class="label" x="320" y="118" text-anchor="middle">${hopB}</text>

          <path class="link" d="M340 75 H552" style="animation-delay:.35s"></path>

          <circle class="pulse" cx="570" cy="75" r="20" style="animation-delay:1s"></circle>
          <circle class="node" cx="570" cy="75" r="13"></circle>
          <text class="label" x="570" y="118" text-anchor="middle">${hopC}</text>
        </svg>

        <dl>
          <dt>Host</dt><dd>${domain}</dd>
          <dt>Cluster</dt><dd>${cluster}</dd>
          <dt>${hopLabel}</dt><dd>${gatewayIP}</dd>
        </dl>

        <p class="foot">${footer}</p>
      </main>
    </body>
    </html>
  '';
in
{
  "${name}-content" = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      inherit namespace;
      name = "${name}-content";
    };
    data."index.html" = page;
  };

  "${name}-deployment" = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      inherit namespace;
      name = name;
    };
    spec = {
      replicas = 1;
      selector.matchLabels."app.kubernetes.io/name" = name;
      template = {
        metadata.labels."app.kubernetes.io/name" = name;
        spec = {
          containers = [
            {
              name = "site";
              image = "nginxinc/nginx-unprivileged:1.27-alpine";
              ports = [ { containerPort = 8080; } ];
              volumeMounts = [
                {
                  name = "content";
                  mountPath = "/usr/share/nginx/html";
                  readOnly = true;
                }
              ];
              readinessProbe = {
                httpGet = {
                  path = "/";
                  port = 8080;
                };
                initialDelaySeconds = 2;
                periodSeconds = 5;
              };
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "24Mi";
                };
                limits = {
                  cpu = "200m";
                  memory = "64Mi";
                };
              };
            }
          ];
          volumes = [
            {
              name = "content";
              configMap.name = "${name}-content";
            }
          ];
        };
      };
    };
  };

  "${name}-service" = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      inherit namespace;
      name = name;
    };
    spec = {
      selector."app.kubernetes.io/name" = name;
      ports = [
        {
          port = 80;
          targetPort = 8080;
        }
      ];
    };
  };
}
