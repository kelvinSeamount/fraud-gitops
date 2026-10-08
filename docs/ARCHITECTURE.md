# Architecture and Design Decisions

This document explains why `fraud-gitops` is shaped the way it is. Not what it
does — the README covers that — but why each structural choice was made, what
the alternatives were, and what they cost.

I wrote it because six months from now I will not remember why the ClusterSecretStore
lives in a bash script instead of in this repo, and I will waste an afternoon
"fixing" it.

---

## 1. The one idea

Everything here follows from a single rule:

> **I never talk to the cluster. I talk to git. Something else makes the cluster
> match.**

That something is ArgoCD, which runs inside the cluster and does one thing
forever:

```
        ┌────────────────────────────────────────────┐
        │                                            │
        │   1. read desired state from git           │
        │   2. read actual state from the cluster    │
        │   3. different?  ──yes──> change cluster   │
        │                  ──no───> do nothing       │
        │   4. wait ~3 minutes, repeat               │
        │                                            │
        └────────────────────────────────────────────┘
```

If I find myself running `kubectl apply`, that is the bug — not a shortcut.

### Why it's worth the ceremony

The alternative is `kubectl apply` from a laptop, which works fine right up until
the moment git and the cluster disagree. Then nobody can say which one is
correct, and there is no record of who changed what.

Three things fall out of the loop for free:

| | |
|---|---|
| **Audit trail** | `git log` *is* the deployment history. Who, what, when, why. |
| **Rollback** | `git revert` *is* a rollback. No special tooling, no runbook. |
| **Drift correction** | Someone runs `kubectl edit deploy` at 2am. ArgoCD puts it back. |

That last one is the infrastructure half of this project's "self-healing" claim.
Phase 3 adds the model half — the platform detecting its own accuracy decay and
retraining. Same principle, different layer: declare the desired state, let a
controller close the gap.

---

## 2. App-of-apps, and why I didn't apply seven Applications

There are roughly seven things to install. The obvious approach is a script that
applies seven Application manifests.

I did that on a previous project. It works. But adding an eighth component means
**editing the script and re-running it against the cluster** — which is
procedural code I now have to maintain, test, and remember to run.

Instead, exactly one object is ever applied by hand:

```
   scripts/02 ──apply──> Application: fraud-platform-root-dev
                                │
                                │  "sync every file in argocd/apps/dev/"
                                ▼
                    ┌─────────────────────────────────┐
                    │      argocd/apps/dev/           │
                    │                                 │
                    │   00-platform-bootstrap.yaml    │──> namespaces, secrets
                    │   10-eck-operator.yaml          │──> Elasticsearch operator
                    │   20-kube-prometheus-stack.yaml │──> Prometheus + Grafana
                    │   21-jaeger.yaml                │──> tracing
                    │   22-otel-collector.yaml        │──> telemetry pipe
                    │   30-elastic-stack.yaml         │──> Elasticsearch + Kibana
                    │   40-hello-platform.yaml        │──> the GitOps canary
                    └─────────────────────────────────┘
                                │
                    each file IS an Application,
                    which installs its own thing
```

The root Application's source is a *folder*. Every file in that folder is itself
an Application. So:

```
   Adding Kafka in Phase 2

   script-based:  edit script 02, commit, re-run it against the cluster
   app-of-apps:   create argocd/apps/dev/50-kafka.yaml, git push.  Done.
```

That is the difference between **automated** (a script does the typing for me)
and **declarative** (there is no typing; the state is the file).

---

## 3. The big one: one cluster per environment

This is the decision that shapes everything else, so it gets the most space.

### What I chose

```
   ┌──────────────────────────┐   ┌──────────────────────────┐
   │   fraud-dev-cluster      │   │   fraud-qa-cluster       │
   │                          │   │                          │
   │   its OWN ArgoCD ────┐   │   │   its OWN ArgoCD ────┐   │
   │                      │   │   │                      │   │
   │   ┌──────────────────▼─┐ │   │   ┌──────────────────▼─┐ │
   │   │ monitoring         │ │   │   │ monitoring         │ │
   │   │ logging            │ │   │   │ logging            │ │
   │   │ observability      │ │   │   │ observability      │ │
   │   │ platform-demo      │ │   │   │ platform-demo      │ │
   │   └────────────────────┘ │   │   └────────────────────┘ │
   └──────────────────────────┘   └──────────────────────────┘
        reads argocd/apps/dev/         reads argocd/apps/qa/
```

Separate clusters. Separate ArgoCD in each. Separate Terraform state
(`envs/dev/terraform.tfstate`, `envs/qa/terraform.tfstate`), which is what makes
them genuinely independent — `terraform destroy` on dev cannot reach qa.

### The alternative I rejected

The cheaper pattern is one cluster where the environments are namespaces:

```
   ┌────────────────────────────────────────────┐
   │              ONE CLUSTER                   │
   │  ┌──────┐  ┌──────┐  ┌──────┐              │
   │  │ dev  │  │  qa  │  │ prod │              │
   │  └──────┘  └──────┘  └──────┘              │
   │  ┌──────────────────────────────────────┐  │
   │  │ SHARED: CRDs, ClusterRoles, webhooks,│  │
   │  │ nodes, API server, ingress controller│  │
   │  └──────────────────────────────────────┘  │
   └────────────────────────────────────────────┘
```

I used this on a previous project and it was the right call there. It is the
wrong call here.

### Why

**A namespace is a soft boundary.** These things are cluster-wide no matter how
many namespaces you draw:

```
   shared across ALL namespaces in a cluster:

   ├─ CustomResourceDefinitions   ← one bad CRD upgrade breaks every namespace
   ├─ Admission webhooks          ← a failing webhook blocks ALL deployments
   ├─ ClusterRoles / bindings     ← one RBAC mistake crosses environments
   ├─ The Kubernetes version      ← can't test a 1.33 upgrade in dev first
   ├─ Nodes and kernel            ← a memory-hungry dev pod evicts prod pods
   └─ The API server              ← one client hammering it degrades everyone
```

This platform installs **operators**, which makes that concrete rather than
theoretical. The ECK operator registers an `Elasticsearch` CRD cluster-wide. In
a shared cluster, upgrading ECK "just in dev" changes the CRD that prod's
Elasticsearch depends on. No namespace boundary stops it, because CRDs do not
live in namespaces.

Two more reasons specific to this project:

- **It handles payment data.** Anything in PCI-DSS scope is expected to have
  structural environment separation. "Dev and prod share a Kubernetes API
  server" is an audit finding, not a design choice.
- **Phase 3 deploys itself.** The retraining loop autonomously pushes new models
  to the cluster. I want the blast radius of an autonomous deployer to be a
  cluster I can destroy and rebuild in fifteen minutes — not a namespace sitting
  next to production.

### What it costs

This is not free and I want the number written down:

```
   EKS control plane:  $0.10/hour  ≈  $73/month  PER CLUSTER
                                      ^^^^^^^^^^
                       nodes, EBS volumes and load balancers on top
```

For this project, one running cluster is roughly **$16/day** all-in. Standing up
qa alongside dev doubles it. There is also operational multiplication: three
clusters means three ArgoCDs, three Prometheus stacks, three sets of secrets to
rotate.

I mitigate this by **destroying the cluster when I am not using it**. The whole
platform is code; `terraform apply` rebuilds it in about fifteen minutes. That
only works because nothing lives outside git — which is itself an argument for
the GitOps model.

### The pattern I'd move to next

There is a third option I did not choose, and it is the one large organisations
actually run:

```
              ┌──────────────────────┐
              │  MANAGEMENT CLUSTER  │
              │       ArgoCD         │
              └──────────┬───────────┘
                         │ clusters registered as destinations
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
   ┌───────────┐   ┌───────────┐   ┌───────────┐
   │    dev    │   │    qa     │   │   prod    │
   └───────────┘   └───────────┘   └───────────┘
```

One ArgoCD, many clusters. One pane of glass, one RBAC model. ArgoCD was built
for this — `destination.server` takes a *cluster URL*, not just a namespace, and
that field exists precisely so one ArgoCD can drive many clusters.

I did not choose it because the economics invert at this size. Hub-and-spoke
needs a management cluster that **never** gets destroyed, running 24/7 at ~$90/month,
to orchestrate clusters that exist for a few hours a day.

But the repo is laid out so the move is small:

```
   argocd/apps/dev/    ← dev's ArgoCD reads this
   argocd/apps/qa/     ← qa's ArgoCD reads this

   moving to hub-and-spoke = one central ArgoCD reads BOTH, and each
   Application's destination.server changes from

       https://kubernetes.default.svc     (the cluster I'm running in)
   to
       https://<qa-cluster-endpoint>      (a named remote cluster)

   Nothing else moves.
```

One field. That is the entire difference between the two patterns, and it is
worth knowing — being able to say exactly what scaling would take is a better
answer than defending either pattern as universally correct.

---

## 4. Namespaces are components, not environments

This follows directly from section 3, but it trips people up so it is worth
stating on its own.

In a shared-cluster setup, namespaces answer *"which environment?"* — `dev`,
`qa`, `prod`. Here, the cluster already answers that. So namespaces answer a
different question: *"which part of the platform?"*

| Namespace | Holds |
|---|---|
| `argocd` | ArgoCD itself, and every Application object |
| `external-secrets` | External Secrets Operator |
| `monitoring` | Prometheus, Grafana, Alertmanager |
| `logging` | Elasticsearch, Kibana |
| `elastic-system` | The ECK operator |
| `observability` | Jaeger, OpenTelemetry Collector |
| `platform-demo` | hello-platform, the GitOps canary |

The same seven names exist in every cluster. `fraud-qa-cluster` has a
`monitoring` namespace too.

**Consequence:** there is no per-environment RBAC in Phase 0. In a shared
cluster, RBAC is the only thing stopping a dev workload from reading prod
secrets — it is load-bearing. Here the cluster boundary already does that job.
RBAC returns in Phase 4, but for a different purpose: controlling which *humans*
can do what, not which environments can see each other.

`elastic-system` being separate from `logging` is deliberate too. The operator
outlives any individual Elasticsearch cluster and has cluster-wide scope; the
Elasticsearch instance is a workload. Different lifecycles, different namespaces.

---

## 5. Where the bootstrap ends and GitOps begins

Not everything can live in this repo, and the reason is a genuine deadlock
rather than laziness.

```
   To create an ExternalSecret via ArgoCD, you need:
        │
        ├─ the ExternalSecret CRD ────┐
        └─ a ClusterSecretStore ──────┤
                                      │  both installed by
                                      ▼
                          External Secrets Operator
                                      │
                                      │  which must be installed by...
                                      ▼
                              ArgoCD? ──── but ArgoCD can't create an
                                           ExternalSecret until ESO
                                           already exists  ⟲ deadlock
```

Something outside the loop has to break it. That something is
`fraud-infra/scripts/01-bootstrap-argocd-eso.sh`, which installs ArgoCD, ESO and
the ClusterSecretStore with plain Helm and `kubectl`. It runs exactly once per
cluster and then hands over.

There is a second reason the ClusterSecretStore cannot live here: it names an
IAM role ARN that Terraform creates. It is welded to the AWS layer, not the
Kubernetes layer.

```
   fraud-infra (Terraform)   ──> creates IAM role fraud-dev-eso-role
             │
   script 01 (bootstrap)     ──> installs ArgoCD + ESO, annotates the ESO
             │                   ServiceAccount with that ARN, creates the
             │                   ClusterSecretStore
             │
             ▼                ══════════ HANDOVER ══════════
             │
   fraud-gitops (declarative) ──> everything from here on
```

**The rule:** if a thing is needed to make GitOps work, it belongs in the
bootstrap. If GitOps can manage it, it belongs here. There is no third category.

Things that live in the bootstrap for this reason:

- ArgoCD itself (cannot install itself before it exists)
- External Secrets Operator and the ClusterSecretStore (the deadlock above)
- The EKS access entry for my local IAM user (Terraform, so it survives rebuilds)

---

## 6. Repo layout

```
fraud-gitops/
│
├── argocd/                    ArgoCD CONTROL objects. Nothing else.
│   ├── projects/                 who may deploy what, where
│   └── apps/
│       ├── root-app-dev.yaml     the ONE object applied by hand
│       └── dev/                  the child Applications
│
├── envs/                      ALL TUNING lives here
│   └── dev/                      values-*.yaml, one per component
│                                 qa/ and prod/ get added beside it
│
├── helm-charts/               charts I own
│   └── fraud-service/            one generic chart; every first-party service
│                                 is a values file against it
│
└── manifests/                 raw YAML with nothing to parameterise
    └── dev/                      namespaces, StorageClass, ExternalSecret,
                                  the Elasticsearch CR
```

### Why `manifests/` is not inside `argocd/apps/dev/`

The root Application syncs `argocd/apps/dev/` and treats **every file it finds
there** as a child Application. A Deployment dropped in that folder gets applied
straight into the `argocd` namespace — because that is the root app's
destination. The workload lands in the wrong place with no error anywhere.

The folder split is what prevents that. It is not organisational tidiness.

### Why values live in `envs/`, not inside each Application

An Application with a 90-line inline `values:` block works fine for one
environment. Adding qa means forking those 90 lines. Adding prod means forking
them again, and now a change has to be made in three places and will eventually
be made in two.

With values externalised, adding qa is:

```
   cp -r envs/dev envs/qa       # change what differs
   cp -r argocd/apps/dev argocd/apps/qa   # change two lines per file
```

The Application becomes pure wiring — repo, chart, version, namespace, sync
behaviour. Changing Prometheus retention no longer means editing an ArgoCD
object.

### Why `manifests/` and not `k8s/`

I considered `k8s/`, which is what I called it on a previous project.
**Everything in this repo is Kubernetes**, so `k8s/` does not distinguish
anything. `manifests/` earns its name: it means *un-templated YAML applied
as-is*, which is a real distinction from `helm-charts/` (templated) and
`argocd/` (control plane).

Each top-level directory name says what *kind* of thing is inside it.

---

## 7. Ordering: sync waves

Here is a failure that is guaranteed without explicit ordering:

```
   ArgoCD tries to create:   kind: Elasticsearch
                                    │
                                    ▼
              Kubernetes API: "no matches for kind Elasticsearch"
                                    │
                                    ▼
                            because the CRD that TEACHES
                            Kubernetes what an "Elasticsearch"
                            is has not been installed yet
```

That CRD comes from the ECK operator, so the operator must be *fully running*
before the Elasticsearch resource is even attempted.

ArgoCD's mechanism is the `argocd.argoproj.io/sync-wave` annotation. Lowest
number first; wave *N+1* does not start until everything in wave *N* is Healthy.

```
  time ──────────────────────────────────────────────────────────────────>

  wave -1   ┃ namespaces, StorageClass, Grafana ExternalSecret
            ┃ (everything else assumes these exist)
            ┗━━━━━━━━━┓
  wave  0             ┃ ECK operator
                      ┃ ← installs the Elasticsearch + Kibana CRDs
                      ┗━━━━━━━━━┓
  wave  1                       ┃ kube-prometheus-stack ┐
                                ┃ jaeger                ├ parallel, independent
                                ┃ otel-collector        ┘
                                ┗━━━━━━━━━┓
  wave  2                                 ┃ Elasticsearch + Kibana
                                          ┃ ← needs wave 0's CRDs
                                          ┗━━━━━━━━━┓
  wave  3                                           ┃ hello-platform
```

The `00-`, `10-`, `20-` filename prefixes mirror the waves. **ArgoCD ignores
filenames entirely** — it reads only the annotation. The numbers exist so `ls`
shows the install order to a human.

The Grafana secret is in wave -1 for a subtle reason. If the ExternalSecret and
the Grafana Helm release landed in the same wave, Grafana would *sometimes* start
first, find no secret, and generate a random admin password. Nothing would error.
The wave turns "usually fine" into "guaranteed".

---

## 8. Node pools and the taint

The cluster has two pools. The memory pool is **tainted**
`workload=memory:NoSchedule`.

| Pool | Instances | Label | Runs |
|---|---|---|---|
| general | m5.large × 2 | `workload=general` | ArgoCD, Prometheus, Grafana, Jaeger, OTel, services |
| memory | r5.large × 2 | `workload=memory` | Elasticsearch, and Kafka from Phase 2 |

The taint is the entire point of the split:

```
   memory pool carries taint:  workload=memory:NoSchedule
                                        │
                     ┌──────────────────┴──────────────────┐
                     │                                     │
          pod WITHOUT toleration              pod WITH toleration
                     │                          + nodeSelector
                     ▼                                     │
              ┌──────────────┐                             ▼
              │   Pending    │  ◄── forever          ┌──────────┐
              │              │                       │ Running  │
              └──────────────┘                       └──────────┘
```

**Why bother:** an Elasticsearch heap spike or a Kafka rebalance creates node
memory pressure, and the kubelet responds by evicting pods. Without the taint,
the pod it evicts might be the latency-critical scoring service. The taint makes
that co-scheduling impossible rather than merely unlikely.

**The cost of getting it wrong:** anything targeting the memory pool needs
**both** a `nodeSelector` and a matching `toleration`. Miss either and the pod
sits `Pending` with a message that does not obviously explain why.

One exception: `node-exporter` is a DaemonSet and must run on *every* node,
including tainted ones, or there are no host metrics from the nodes running
Elasticsearch. It carries a blanket `tolerations: [{operator: Exists}]`.

---

## 9. Secrets

No credential is ever committed to this repo. Not encrypted, not sealed, not
base64'd. Absent.

```
   AWS Secrets Manager
   /fraud/dev/grafana-admin
   {"admin-user":"admin","admin-password":"..."}
            │
            │  ① ESO asks AWS for it
            │
            │     ┌─────────────────────────────────────────┐
            │     │  Authenticated how?                     │
            │     │  NOT with an AWS key — there are none   │
            │     │  in the cluster.                        │
            │     │                                         │
            │     │  ServiceAccount token (a JWT signed by  │
            │     │  the cluster) ──> AWS STS ──> temporary │
            │     │  credentials for fraud-dev-eso-role     │
            │     │                                         │
            │     │  This is IRSA.                          │
            │     └─────────────────────────────────────────┘
            ▼
   ② ESO creates a normal Kubernetes Secret
      namespace: monitoring, name: grafana-admin
            │
            ▼
   ③ Grafana reads it via grafana.admin.existingSecret
```

What is in git is only the *instruction to fetch*:

```yaml
data:
  - secretKey: admin-password
    remoteRef:
      key: /fraud/dev/grafana-admin
      property: admin-password
```

Rotating the password means changing it in AWS. ESO picks it up within
`refreshInterval`. No redeploy, no commit.

### Two things that will bite

**`apiVersion: external-secrets.io/v1` — not `v1beta1`.** ESO 2.x stopped
*serving* v1beta1. The CRD still *lists* it with `served: false`, so the API
server reports `no matches for kind ExternalSecret` — which reads like the CRD is
missing rather than deprecated. Check what is actually served with:

```bash
kubectl api-resources --api-group=external-secrets.io
```

**`secretStoreRef.kind: ClusterSecretStore` — not `SecretStore`.** The store is
cluster-scoped so many namespaces can share one IAM role. Omitting `kind`
defaults to the namespaced `SecretStore`, and ESO reports "SecretStore not
found" while a store with that exact name is plainly visible in
`kubectl get clustersecretstore`.

Both are recorded in `fraud-infra/docs/TROUBLESHOOTING.md` §10.

---

## 10. Conventions, and why each exists

**Pin every chart version. Never `latest`.**
An unpinned chart means the cluster can change because a stranger published a
release. Then git is no longer the only cause of change, which defeats the entire
model.

**`targetRevision: main`, not `HEAD`.**
`HEAD` resolves to whatever the default branch points at right now. It works, but
the deployed version becomes a lookup rather than a value you can read. Phase 3's
retraining job commits image tags to `main`, and I want that to be legible.

**Values in `envs/`, never inline in an Application.**
Applications are wiring. `envs/` is configuration. Mixing them means forking
90-line blocks per environment.

**One owner per resource.**
Namespaces are declared in exactly one file. Two Applications both claiming to
create the same namespace produces a shared-resource conflict and permanent
OutOfSync flapping.

**`allowEmpty: false` on every Application.**
If a typo makes `path:` resolve to an empty directory, ArgoCD would otherwise
conclude "desired state is nothing" and prune the whole platform. This is the one
line that stops a single-character mistake from deleting everything.

**`ignoreDifferences` on webhook `caBundle` fields.**
The Prometheus Operator injects its CA at runtime. Without this, ArgoCD sees
permanent drift and the app flaps OutOfSync forever — noise that trains you to
ignore the sync status.

---

## 11. What is deliberately not here yet

Recorded so I do not wonder later whether I forgot.

| Thing | Where it is | When it arrives |
|---|---|---|
| ArgoCD install | `fraud-infra/scripts/01` | bootstrap — cannot self-install |
| ClusterSecretStore | `fraud-infra/scripts/01` | bootstrap — deadlock, see §5 |
| Ingress / real TLS | nowhere | Phase 4 — ALB + ACM cert for `*.fraud-dev.piroo.online` |
| Human RBAC | nowhere | Phase 4 — cluster boundary covers Phase 0 |
| Kafka (Strimzi) | nowhere | Phase 2 — one new file in `argocd/apps/dev/` |
| Model serving | nowhere | Phase 1 |
| `qa` / `prod` envs | Terraform has `envs/qa` | when there is a reason |

ArgoCD is currently on its own self-signed certificate, reached by
`kubectl port-forward`. The browser warning is expected, not a fault. Real TLS is
a Phase 4 item because it needs an ACM certificate, the AWS Load Balancer
Controller, and an ALB at roughly $0.60/day — none of which teaches anything
Phase 0 is about.

---

## 12. Honest limitations

Things I would do differently with more budget or a real team:

- **One environment actually exists.** `envs/qa` is in Terraform but has never
  been applied. The layout supports multi-environment; it has not been proven at
  multi-environment.
- **`clusterResourceWhitelist` is `*`.** The AppProject permits any cluster-scoped
  resource because operators ship CRDs and ClusterRoles. The real containment is
  the enumerated `destinations` list. I would rather write that down than pretend
  it is locked down.
- **No progressive delivery.** Deployments are rolling updates. Argo Rollouts with
  canary analysis is the obvious next step, and is genuinely important once a
  retraining loop is deploying models autonomously.
- **Single Elasticsearch node in dev.** No quorum, no resilience. Correct for a
  cluster that gets destroyed nightly; wrong for anything else.
- **The cluster is destroyed most of the time.** Everything here is verified on
  rebuild rather than continuously. A long-running environment would surface
  problems this one never gets the chance to.
