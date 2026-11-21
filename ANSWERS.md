# Part 5 — Written question

**Q1.** A platform is running around 40 Ingress objects on `ingress-nginx`, which has reached end-of-life. You need to migrate to the Kubernetes Gateway API with no downtime. Outline your approach, the order you would do things in, and what you expect to break along the way.

## Approach: run both side by side, shift traffic gradually, keep rollback cheap

1. **Inventory first.** Dump all 40 Ingresses and list every `nginx.ingress.kubernetes.io/*` annotation in use. This is where the risk lives, since Gateway API has no 1:1 equivalent for many of them.
2. **Pick a controller** (Envoy Gateway, Cilium, or the cloud-native one). Install the CRDs (pinned version) and the controller in parallel with ingress-nginx, with its own LoadBalancer and IP.
3. **Convert in batches.** Use `ingress2gateway` for a first pass, then hand-review. Start with low-risk internal/staging services, then non-critical prod, then critical ones last.
4. **Validate before cutover.** Hit the new LB directly (`curl` with `--resolve` or a Host header). Compare status codes, headers, redirects, and latency against the old path. Run smoke tests in CI.
5. **Shift traffic via DNS** with weighted records (for example 5% → 25% → 100%) and TTLs lowered in advance. Rollback means setting the weight back to 0.
6. **Decommission ingress-nginx** only after a soak period (a week or more) with zero traffic on it.

## What I expect to break

- **Annotation gaps:** rewrites, regex paths, `proxy-body-size`, timeouts, rate limits, `auth-url`, CORS, snippets. These need HTTPRoute filters or controller-specific policies.
- **TLS and cert-manager:** certs move to Gateway listeners, so the cert-manager Gateway integration must be enabled and certs reissued and validated.
- **Path matching differences** (prefix vs regex semantics) and trailing-slash behavior.
- **Client IP, proxy protocol, and `X-Forwarded-*` headers**, which can break allowlists and logging.
- **Cross-namespace references** need a `ReferenceGrant`; WebSockets, gRPC, and long timeouts behave differently.
- **Observability:** dashboards and alerts built on nginx metrics need rebuilding (Prometheus/Grafana).
