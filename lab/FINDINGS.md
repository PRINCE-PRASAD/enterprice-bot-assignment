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

The image listens on 8081 unless `PORT` is set. The chart never set `PORT`. Probes, `containerPort`, the backend and reporter Services, and `./scenario.sh verify` all use `common.port`, which is 8080, so every probe connected to a port with nothing on it.

**Fix:**

Added this env entry to `backend.yaml`, `gateway.yaml`, `worker.yaml`, `reporter.yaml`, and `metrics.yaml`:

```yaml
- name: PORT
  value: {{ .Values.common.port | quote }}
```

That makes the process listen on 8080, the same value the probes and Services already use. Changing `common.port` to 8081 would move the probes, but `verify` calls `http://backend:8080/healthz` and `http://reporter:8080/report`, so the Service port has to stay 8080. The image repository and tag were left unchanged.

**How I found it:**

`kubectl get pods -n debug-lab` showed the new pods `Running` and the Deployments still `0/1` ready. `kubectl describe pod` on the new backend pod showed the readiness probe failing with `connection refused` on port 8080. `kubectl logs` on that pod, and on the gateway and reporter pods, said the process was listening on 8081 and that `PORT` overrides it. `values.yaml` has `common.port: 8080`, and the templates pass that to `containerPort` and the probe port, but not to `PORT`.

---

## Defect 4

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 5

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 6

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.
