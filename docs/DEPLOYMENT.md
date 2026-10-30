# Deployment

The plugin is a custom Kong image, not a sidecar. It calls the hosted Next
Moca API immediately before Kong forwards an LLM request upstream.

## Kubernetes With Helm

The supplied [`deploy/helm/values.yaml`](../deploy/helm/values.yaml) targets
the official `kong/kong` chart in DB-less mode. It uses the release-tagged
`ghcr.io/nextmoca/kong-nextmoca-runtime-defense:0.1.1` image and reads
`NEXTMOCA_API_KEY` from a Kubernetes Secret.

For a production deployment, pin the exact digest printed in the matching
GitHub release rather than a mutable tag.

Create a secret through your existing secret manager, or for a development
environment:

```sh
kubectl create secret generic nextmoca-runtime-defense \
  --from-literal=NEXTMOCA_API_KEY="$NEXTMOCA_API_KEY"
```

Install the official chart with the supplied values:

```sh
helm repo add kong https://charts.konghq.com
helm repo update
helm upgrade --install kong kong/kong \
  --namespace kong --create-namespace \
  --values deploy/helm/values.yaml
```

The chart converts `env.nginx_main_env` to `KONG_NGINX_MAIN_ENV`. This is
required because Kong runs plugins in Nginx workers: the worker must inherit
the secret's name, while the secret value remains outside declarative Kong
configuration.

## Configure The Route

The example creates one `/openai` route and starts in `shadow` mode. Set the
service URL and route to match the LLM provider path your application already
uses. Leave the upstream provider credential in its existing gateway secret
mechanism; this plugin does not manage provider credentials.

Roll out deliberately:

1. Start in `shadow` and inspect receipt headers and Kong logs.
2. Enable `active` to deliver selected context without security scanning.
3. Run `make live-security-smoke` against a non-production Next Moca key.
4. Enable `quarantine`; use `enforce` only after your team has validated the
   block behavior against representative requests.

## Other Container Deployments

Use `ghcr.io/nextmoca/kong-nextmoca-runtime-defense:0.1.1` as the Kong base
image. Set both variables on the Kong container:

```text
NEXTMOCA_API_KEY=<secret-manager reference>
KONG_NGINX_MAIN_ENV=NEXTMOCA_API_KEY
```

Enable `bundled,nextmoca-runtime-defense` in `KONG_PLUGINS`, then add the
plugin configuration shown in the Helm example to the relevant Kong service
or route.
