# DevOps take-home

Python HTTP service, Helm chart, one-command kind setup, and the Part 4 lab debug.

Needs Docker, kind, kubectl, and helm.

## Run

```bash
chmod +x setup.sh
./setup.sh
```

`./setup.sh` is safe to run again. It reuses a kind cluster named `demo` when one already exists, reapplies ingress-nginx, rebuilds `demo-service:1.0.0`, loads it into the node, and runs `helm upgrade --install` as release `demo` in namespace `demo`.

The first run publishes host ports 80 and 443 on the kind node. If a cluster named `demo` was created some other way, delete it first (`kind delete cluster --name demo`) so those port mappings exist.

## Verify

```bash
kubectl --context kind-demo -n demo get pods,svc,ingress

curl -sS --resolve demo.local:80:127.0.0.1 http://demo.local/healthz
curl -sS --resolve demo.local:80:127.0.0.1 http://demo.local/
```

`GET /healthz` returns `200` and the body `ok`. `GET /` returns JSON:

```json
{"app": "demo", "version": "1.0.0", "pod": "<pod name>"}
```

`app` and `version` come from the release ConfigMap (`config.appName` and `config.version`). The process reads those files on each request, so a ConfigMap patch shows up on `GET /` after kubelet refreshes the volume. The same keys are also injected as environment variables for a freshly started container.

Through the Service, without Ingress:

```bash
kubectl --context kind-demo -n demo port-forward svc/demo 8080:80
curl -sS localhost:8080/healthz
curl -sS localhost:8080/
```

Override check (what the harness does):

```bash
helm upgrade demo ./chart \
  --kube-context kind-demo \
  --namespace demo \
  --reuse-values \
  --set replicaCount=3 \
  --set config.appName=harness \
  --set-string config.version=9.9.9 \
  --set ingress.host=other.local \
  --wait --timeout 5m

kubectl --context kind-demo -n demo get deploy demo -o jsonpath='{.spec.replicas}{"\n"}'
curl -sS --resolve other.local:80:127.0.0.1 http://other.local/
```

## Part 4 lab

The demo cluster from `./setup.sh` is the cluster the lab uses. `lab/cluster-state/` is unchanged. The image repository and tag in `lab/broken-chart` are still `docker.io/ebinterview/eb-debug-app:1.0.1`.

```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

`./scenario.sh verify` is the definition of done. Each defect is written up in `lab/FINDINGS.md` with the command output, the cause, the fix, and how it was found.

The chart fixes are: Job `restartPolicy: OnFailure`, numeric `runAsUser: 65532` on every workload, `PORT` set from `common.port` (8080) so probes and Services stay on 8080, RoleBinding subject `reporter`, gateway `BACKEND_URL` pointed at `backend.debug-lab.svc`, an emptyDir on the worker at `/var/cache/app`, and metrics CPU brought under the LimitRange max of 1.

One check stays red. The reporter reads 1024 bytes of the pod list and then fails JSON parse (`unexpected end of JSON input`). A real PodList in this namespace is about 50 KB. That read size is compiled into the image, and the assignment does not allow changing the image. Details are Defect 8 in `lab/FINDINGS.md`. After the other pods are Ready, verify is 9 passing and 2 failing, both on the reporter.

`lab/part4-session.log` is the `script` recording from the start of the investigation. It was removed in a later commit and restored from that first commit, so it covers the early commands and the first verify, not the whole session. Later steps are in `FINDINGS.md` and the commit history. The file contains terminal control sequences; `less -R lab/part4-session.log` shows them as the terminal did.

## Part 5 answer

The written answer on migrating about 40 `ingress-nginx` Ingresses to the Gateway API is in [`ANSWERS.md`](ANSWERS.md).

## Resources

Requests are `50m` CPU and `64Mi` memory. Limits are `200m` CPU and `128Mi` memory. The chart defaults and the lab workloads that were changed use the same numbers.

The process is one CPython interpreter and a stdlib HTTP server. Idle RSS on this image sits under 64Mi, so the request schedules two replicas on a kind node without asking for a full core. The 128Mi limit is about twice the request: a request spike fits, and a leak is killed before it fills the node. 50m is enough while the pod is idle. 200m lets a short burst of requests finish. The same ceiling matters in the lab: the namespace LimitRange allows at most 1 CPU and 512Mi, and the original metrics limit of 4 CPU was rejected before a pod existed.

## What I skipped, and the risk

- **Part 5 depth.** `ANSWERS.md` answers the Gateway API migration question in about 320 words, above the roughly 200 the assignment suggests. It is a plan on paper, not tested on a real 40-Ingress cluster. The risk is that annotation gaps only show up when each Ingress is converted and compared against the old path.
- **Reporter `/report`.** Left failing on purpose. Hiding the Deployment would make verify quieter and would hide a real bug. The risk is the lab score stays short of a full green verify.
- **Full session recording.** Only the first slice of `part4-session.log` is committed. The risk is a reader cannot replay the later defects from the log alone.
- **Trivy gate is red on unfixed CVEs.** `.github/workflows/ci.yml` lints `chart/`, builds the image, and fails on any HIGH or CRITICAL finding, as the assignment asks. `ignore-unfixed` is false and there is no `.trivyignore`, so nothing is waived. The base image moved from `python:3.12.8-slim-bookworm` to `python:3.12.16-slim-trixie`, and the final stage runs `apt-get upgrade` to take the zlib fix (CVE-2026-85091). The last run reported 48 HIGH findings. The zlib one now has a fix; the others in the trixie base do not: `util-linux` family (CVE-2026-76642, -78408, -78409, -78410, status `affected`), `ncurses` (CVE-2025-69720), `systemd` (CVE-2026-16742), `sqlite` (CVE-2026-119373, -119374, -119379), `libacl1` (CVE-2026-54369), and `perl-base` (CVE-2026-9538, `fix_deferred`). The risk is that CI stays red until Debian ships fixes or the base image changes. I chose not to waive them because the spec does not allow an exception.
- **Tests.** No unit test for `service/app.py`. A broken JSON shape would only show up when the cluster is curled.
- **Supply chain pin.** The chart uses a tag (`1.0.0`), not a digest. A retagged image would roll out on the next install.

## Production

- Pin the image by digest and sign it. Keep the Trivy gate, and record any accepted CVE in `.trivyignore` with a reason and a review date.
- Add a PodDisruptionBudget, a HorizontalPodAutoscaler, and a NetworkPolicy that allows ingress only from ingress-nginx.
- Terminate TLS on the Ingress and stop publishing the app on plain HTTP.
- Replace the stdlib server with a small production server, add request timeouts, and emit structured logs plus a metrics endpoint.
- Give the chart a chart test and a smoke check in CI that renders with the harness overrides (`replicaCount`, `config.appName`, `config.version`, `ingress.host`) before anything is deployed.

## How I used AI

Cursor, with Grok, in this workspace.

It drafted the Python service, Dockerfile, Helm chart, `setup.sh`, the GitHub Actions workflow, and this README. For the lab it explained command output I pasted and proposed the chart edits. I ran `./setup.sh`, `./scenario.sh`, `kubectl`, and `curl` myself and kept or dropped each edit from that output.

The Part 5 answer in `ANSWERS.md` is text I supplied. Cursor only put it into the file and formatted it as Markdown; the content was not rewritten.

Corrections:

- An early guess that the reporter failed because the amd64 image was emulated on an arm64 node was wrong. The failure is a 1024-byte read in the binary.
- The Defect 3 write-up first read as if the listen port had been changed to 8081. 8081 was the image default before `PORT` was set. The chart still uses 8080.
- Raising the reporter CPU and memory did not change the JSON error, so those values were put back.
- `git add .` from `lab/` did not stage `service/Dockerfile`. The base-image change had to be added from the repo root.
- The session log in git is only the portion that survived the first commit. The longer live recording was not in history.
