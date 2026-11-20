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

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 3

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

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
