# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):

`./scenario.sh up` created the namespace, then Helm refused to install the chart. The migrate Job was never created.

```
==> installing the broken chart
Release "debug-lab" does not exist. Installing it now.
Error: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

**Cause** (the actual root cause, not the symptom restated):

`lab/broken-chart/templates/migrate-job.yaml` set `spec.template.spec.restartPolicy: Always`. A Job pod may only use `OnFailure` or `Never`. `Always` is valid for Deployments, not for Jobs, so the API server rejected the object and the release did not install.

**Fix** (what you changed, and why this over alternatives):

Changed `restartPolicy` from `Always` to `OnFailure`. `OnFailure` retries the container in the same pod when the migration exits non-zero, and stops when it exits 0. `Never` is also legal, but each retry would be a new pod; `OnFailure` matches a one-shot migration that should retry in place up to `backoffLimit`.

**How I found it** (the sequence of commands/reasoning that led you here):

`./scenario.sh up` printed the API validation error and named `spec.template.spec.restartPolicy`. I opened `migrate-job.yaml` and found `restartPolicy: Always` on the Job pod template. The error listed the only two legal values, `OnFailure` and `Never`.

---

## Defect 2

**Symptom:**

After the Job was accepted, `kubectl get pods -n debug-lab` showed every pod, including `migrate-q6rzw`, stuck in `CreateContainerConfigError`. Describing the backend pod:

```
kubectl describe pod backend-7948fd6b4b-hz6nr -n debug-lab
```

```
State:          Waiting
  Reason:       CreateContainerConfigError
Warning  Failed  kubelet  spec.containers{backend}: Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

The image pull itself succeeded (`Successfully pulled image "docker.io/ebinterview/eb-debug-app:1.0.1"`). The container never started.

**Cause:**

Each workload sets `securityContext.runAsNonRoot: true` and does not set `runAsUser`. The image user is the name `nonroot`, not a uid. Kubelet will only honour `runAsNonRoot` when it can check a numeric uid, so it refuses to create the container. The same `securityContext` is on the migrate Job and on backend, gateway, worker, reporter, and metrics.

**Fix:**

Added `runAsUser: 65532` next to `runAsNonRoot: true` on every workload that sets it: `migrate-job.yaml`, `backend.yaml`, `gateway.yaml`, `worker.yaml`, `reporter.yaml`, and `metrics.yaml`. `65532` is the numeric uid for the image user named `nonroot`, confirmed by the migrate Job reaching `Completed` after the same line was applied there. Removing `runAsNonRoot` would also let the pods start, but it would drop the non-root check. The image repository and tag were left unchanged.

**How I found it:**

`kubectl get pods -n debug-lab` showed `CreateContainerConfigError` on every pod, including the migrate pod created after Defect 1. `kubectl describe pod` on the backend pod had a kubelet `Failed` event that named `runAsNonRoot` and the non-numeric user `nonroot`. The templates set `runAsNonRoot: true` with no `runAsUser`.

---

## Defect 3

**Symptom:**

After `runAsUser` was set, new backend, gateway, and reporter pods reached `Running` but stayed `0/1` ready. `./scenario.sh verify` still failed `backend does not answer on http://backend:8080/healthz`. Describing a new backend pod:

```
Warning  Unhealthy  kubelet  spec.containers{backend}: Readiness probe failed: Get "http://10.244.0.22:8080/healthz": dial tcp 10.244.0.22:8080: connect: connection refused
```

The container log said it was not listening on that port:

```
kubectl -n debug-lab logs backend-794c558bfb-khvwd --tail=5
2026/11/20 18:17:01 eb-debug-app 2.0.0 starting: mode=api pod=backend-794c558bfb-khvwd listening on :8081 (image default is 8081; set PORT to override)
```

Gateway and reporter logged the same line with `listening on :8081`.

**Cause:**

The image listens on 8081 only when `PORT` is unset. That 8081 in the log is the image default from before the fix, not a port the chart was changed to. The chart never set `PORT`. Probes, `containerPort`, the backend and reporter Services, and `./scenario.sh verify` all use `common.port`, which is 8080, so every probe connected to a port with nothing on it.

**Fix:**

`common.port` stayed `8080`. Nothing was moved to 8081. Added this env entry to `backend.yaml`, `gateway.yaml`, `worker.yaml`, `reporter.yaml`, and `metrics.yaml` so the process listens on the same port the probes and Services already use:

```yaml
- name: PORT
  value: {{ .Values.common.port | quote }}
```

`./scenario.sh verify` calls `http://backend:8080/healthz` and `http://reporter:8080/report`, so the Service port has to stay 8080. The image repository and tag were left unchanged.

**How I found it:**

`kubectl get pods -n debug-lab` showed the new pods `Running` and the Deployments still `0/1` ready. `kubectl describe pod` on the new backend pod showed the readiness probe failing with `connection refused` on port 8080. `kubectl logs` on that pod, and on the gateway and reporter pods, said the process was listening on 8081 and that `PORT` overrides that default. `values.yaml` has `common.port: 8080`, and the templates pass that to `containerPort` and the probe port, but did not pass it to `PORT`.

---

## Defect 4

**Symptom:**

The reporter pod stayed `0/1` ready and `./scenario.sh verify` reported `ServiceAccount debug-lab/reporter cannot list pods`. The reporter log showed the denial:

```
2026/11/20 18:32:48 pod list failed: kubernetes API returned HTTP 403: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods is forbidden: User \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" in API group \"\" in the namespace \"debug-lab\"","reason":"Forbidden","details":{"kind":"pods"},"code":403}
```

**Cause:**

`lab/broken-chart/templates/rbac.yaml` created the `reporter-read` Role, which grants `get` and `list` on `pods`, and a RoleBinding to it. The RoleBinding's subject was `ServiceAccount` `default`, but the reporter pod runs as `reporter` (`serviceAccountName` in `values.yaml`). The `reporter` ServiceAccount therefore had no permission, and the Role was granted to a different account.

**Fix:**

Changed the RoleBinding subject in `rbac.yaml` from `name: default` to `name: reporter`. The Role itself was already correct. After the change, `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` returned `yes`, and the reporter's 403 errors stopped.

**How I found it:**

`./scenario.sh verify` reported the RBAC check failing while the pods were otherwise running. The reporter log gave the 403 with the exact ServiceAccount. `kubectl auth can-i` reproduced the failure, and reading `rbac.yaml` and `reporter.yaml` showed the subject and the pod's `serviceAccountName` did not match.

---

## Defect 5

**Symptom:**

The gateway pod stayed `0/1` ready with a readiness probe returning `503`. Its log showed the backend lookup failing:

```
2026/11/20 18:32:45 readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: Get "http://backend.default.svc:8080/healthz": dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
```

**Cause:**

`lab/broken-chart/values.yaml` set the gateway's `BACKEND_URL` to `http://backend.default.svc:8080`. The lab is deployed to the `debug-lab` namespace, so the backend Service is `backend.debug-lab.svc`. The `default` namespace has no `backend` Service, so DNS returned `no such host`.

**Fix:**

Changed `BACKEND_URL` in `values.yaml` to `http://backend.debug-lab.svc:8080`. After the change the gateway reached `1/1 Running`.

**How I found it:**

The gateway readiness probe returned `503`, and `kubectl logs` on the gateway pod showed the DNS lookup failing for `backend.default.svc`. The `kubectl describe` events showed the `Unhealthy` readiness events for the same pod. Checking `values.yaml` showed the hostname used the `default` namespace.

---

## Defect 6

**Symptom:**

The worker pods went into `CrashLoopBackOff` with `Error`, then `CrashLoopBackOff` with rising restart counts. The previous container's log showed the cause:

```
2026/11/20 18:31:53 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:**

The worker's container sets `readOnlyRootFilesystem: true`, which makes the whole root filesystem read-only. The app needs to create `/var/cache/app` at startup. The chart provided no writable volume there, so the process exited with status 1 each time it started.

**Fix:**

In `lab/broken-chart/templates/worker.yaml`, added an `emptyDir` volume named `cache` and mounted it at `/var/cache/app`. `readOnlyRootFilesystem: true` was left in place, so the root filesystem is still read-only and only the cache directory is writable. After the change the worker reached `1/1 Running`.

**How I found it:**

The pod list showed `CrashLoopBackOff` on the worker, and `kubectl logs --previous` on the crashed container showed the `FATAL` line. The message named `/var/cache/app`, and the chart's `readOnlyRootFilesystem: true` explained why the directory could not be created.

---

## Defect 7

**Symptom:**

`./scenario.sh verify` reported `deployment metrics: 0/1 ready`, and `kubectl -n debug-lab get pods` showed no metrics pod at all. The ReplicaSet could not create one:

```
kubectl -n debug-lab get events --sort-by=.lastTimestamp
Warning  FailedCreate  replicaset/metrics-7664f6554c  Error creating: pods "metrics-7664f6554c-9ndpc" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:**

`lab/broken-chart/values.yaml` set the metrics container to `requests.cpu: "2"` and `limits.cpu: "4"`. The namespace LimitRange in `lab/cluster-state/limits.yaml` (the environment, not edited) sets `max.cpu: "1"` per container. The API server rejected every metrics pod at admission, so the Deployment stayed at 0 available.

**Fix:**

Changed the metrics CPU in `values.yaml` to `requests.cpu: "50m"` and `limits.cpu: "200m"`, the same values the other workloads use and under the LimitRange max of 1. Memory was already within the 512Mi cap and was left as `64Mi` / `128Mi`. `cluster-state/` was not modified. After `./scenario.sh up`, `./scenario.sh verify` reported `PASS  deployment metrics: 1/1 ready`.

**How I found it:**

`kubectl -n debug-lab get deploy` showed `metrics` at `0/1` with `UP-TO-DATE 0`, and there was no metrics pod. `kubectl -n debug-lab get rs -l app=metrics` showed ReplicaSets with `CURRENT 0`. `kubectl get events` on those ReplicaSets reported `FailedCreate` and named the LimitRange ceiling (`maximum cpu usage per Container is 1, but limit is 4`). `values.yaml` had the metrics CPU limit at `4`.

---

## Defect 8 (unresolved, not fixable in the chart)

**Symptom:**

`reporter` stays `0/1` ready, so `./scenario.sh verify` keeps failing `deployment reporter: 0/1 ready` and `reporter /report does not return a pod count`. Both endpoints return the same body:

```
curl -i http://127.0.0.1:18080/report
HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
```

The reporter log repeats `pod list failed: parse pod list: unexpected end of JSON input`. The API server log shows `Timeout or abort while handling` and `Post-timeout activity` for `GET /api/v1/namespaces/debug-lab/pods?limit=100`, so the connection is closed before the response is complete.

**Cause:**

The request itself is correct. The same URL, with the reporter's ServiceAccount (`kubectl get --raw '/api/v1/namespaces/debug-lab/pods?limit=100' --as=system:serviceaccount:debug-lab:reporter`), returns a 50,715-byte valid `PodList` in about 0.05 s. RBAC, `NAMESPACE`, and `PORT` are correct.

In the reporter binary (`eb-debug-app`, `1.0.1`), the code that calls `parse pod list` is preceded by an instruction that sets a slice length of `0x400` (1024 bytes), `movq $0x400, 0x10(%rax)`. Only that many bytes are read from the API response. One real pod entry is several kilobytes, so the JSON is cut off in the middle of an object, and the parser reports `unexpected end of JSON input`.

The user-reported local test reproduced the same boundary outside the cluster: a 1008-byte PodList returns `200` from `/healthz`, and a 1039-byte PodList returns the same `503`. This was not re-run as part of this write-up.

**Fix:**

No chart change fixes this. The URL and the 1024-byte read are compiled into the image. A single live pod object cannot be made smaller than 1024 bytes, and the image repository and tag must not change, so the chart cannot make the response fit. The reporter cannot pass in this lab without a different image build.

Things ruled out during the investigation:
- RBAC (`can-i list pods` returns `yes`, and the RoleBinding subject is `reporter`).
- The API URL and namespace (`/api/v1/namespaces/debug-lab/pods?limit=100` is correct).
- CPU and memory limits (raising the reporter to 1 CPU / 256Mi did not change the error, so it was reverted).
- Port (`PORT=8080` is set and `/healthz` answers).

Platform note: the node is `arm64` and the image is `amd64`, so the image runs under emulation. That was an early theory and is not the cause of the 1024-byte read. It may affect speed, but the byte limit is the reason the body is cut off.

**How I found it:**

`kubectl -n debug-lab get pods` showed the reporter at `0/1` after every other pod was `Ready`. `kubectl logs` showed the parse error on every 5-second probe. Checking the API server log showed the connection was aborted, not refused, so the problem was on the reporter side. `kubectl get --raw` with the reporter identity returned a valid list, which ruled out the cluster and RBAC. Searching the binary for `parse pod list` and disassembling the code around it found the `0x400` slice length.

---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.
