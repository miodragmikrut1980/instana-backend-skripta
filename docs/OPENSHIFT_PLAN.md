# Instana self-hosted backend on Red Hat OpenShift — research and plan

**Status:** plan only, nothing implemented. **Audience:** internal (Instana support), so support can
reproduce and test Custom Edition on OpenShift. Not a customer-facing tool.
**Researched:** 2026-10-19 against IBM Custom Edition docs (product code SSO4JPD, pages dated Aug–Oct 2026).
Items marked **(not verified)** must be checked on a real cluster or against newer docs before relying on them.

---

## 1. Summary

1. Feasible as a **separate platform mode** (`install-openshift.sh`), not as a third provider: the provider
   layer (`providers/*.sh`) is about VMs, disks and SSH, none of which applies to OpenShift. It reuses the
   shared UI, progress, `--config`/JSON, resume and report code.
2. IBM documents one install path for the backend operator: the **`kubectl instana` plug-in**
   (`operator apply` / `operator template`). Datastores are installed with **Helm charts** from IBM's repo.
   OLM/OperatorHub for the *backend* operator is not documented (the *agent* operator is on OperatorHub — do not confuse them).
3. Current release: **Custom Edition 1.12.x ↔ backend 3.325** (compatibility matrix, 2026-10-05).
   Minimum OpenShift **4.13**, Kubernetes **1.22**, every node **x86-64-v3**.
4. IBM publishes a bash installer for this: `github.com/instana/self-hosted-custom-edition-setup` (`shce.sh`,
   Apache-2.0, has an `ocp` mode). Its OpenShift specifics (SCC, UIDs, Routes) can be borrowed with
   attribution; its UX (no hints, no resume, generic errors) does not meet our rules.
5. **Heavy:** IBM gives no x86 sizing. IBM repo defaults for datastores alone ≈ 55 vCPU / 230 GiB requests /
   several TB of PVCs. Estimated demo cluster: 4–5 workers × 16 vCPU / 64 GB, ~1.5–2 TB block storage.
6. OpenShift specifics: **Routes** instead of LoadBalancers; custom **SCC for Cassandra**; Postgres UID and
   BeeInstana fsGroup from the namespace UID range; raw spans need **RWX storage or S3**.
7. 12 phases like the VM installer; resume re-checks the cluster (Helm status, CR status, existing secrets,
   cluster ID) — never trusts the state file on its own.
8. Most testing works without a cluster (fake `oc`/`kubectl`/`helm`/`kubectl-instana`); five scenarios need a
   real cluster. OpenShift Local (CRC) is far too small.
9. Effort: **~35–45 person-days** online MVP, **+8–12** for air-gapped.
10. Main risks: test-cluster cost/size, version churn every CE release, doc gaps, managed OpenShift restrictions.

---

## 2. Install method (as documented)

| Method | Status |
|---|---|
| `kubectl instana operator apply --values values.yaml -n instana-operator` (or `operator template` + `kubectl apply`) | Only documented method for the operator |
| `Core` / `Unit` CRs (`instana.io/v1beta2`) via `kubectl apply` | Documented |
| Datastores via Helm from `https://artifact-public.instana.io/artifactory/rel-helm-customer-virtual` (user `_`, password = download key) | Documented |
| Helm charts `instana-enterprise-operator`, `instana-core`, `instana-unit` | Used by IBM's `shce.sh`, not in the docs |
| OLM / OperatorHub for the backend operator | Not documented **(not verified)** |

Relevant deprecations: `agentAcceptorConfig` → `gatewayConfig.acceptors`; Kafka ZooKeeper mode gone
(KRaft only, Strimzi ≥ 0.46); `downloadKey` moved from Core Secret to Unit Secret (1.5.0).

## 3. Prerequisites

- **Versions:** OpenShift ≥ 4.13, x86-64-v3 CPUs. No published maximum **(not verified)**.
- **Permissions:** cluster-admin, on a **dedicated** cluster (IBM: no application workloads).
- **Storage:** RWO block storage for all datastores, a **default StorageClass**; raw spans on **RWX**
  (ODF CephFS / NFS) or **object storage** (S3-compatible / GCS / Azure). IOPS for the smallest tier:
  20–30k read / 2.5–4k write.
- **Registry:** `artifact-public.instana.io`, user `_`. Docs conflict on the password (agent key vs download
  key); IBM's repo uses the download key → try download key first, fall back to agent key, stop clearly if both fail.
- **DNS / TLS:** records for base domain, `ingress.`, `opamp-acceptor.`, `otlp-http.`, `otlp-grpc.`,
  `<unit>-<tenant>.`; on OpenShift served by **passthrough Routes** (reencrypt if real client IPs are needed
  for EUM). `instana-tls` secret with all SANs. `config.url.format.pathStyle: "true"` serves all tenants from one host.
  cert-manager v1.21.1 for the operator webhook (or an existing one, e.g. Red Hat's).
- **Keys:** sales key → license download + Core Secret `salesKey`; download key → `repositoryPassword` (Core)
  and `downloadKey` (Unit); agent key → `agentKeys` (Unit); admin user/password → Unit Secret.

## 4. Datastores (x86_64, docs 2026-10-16) — versions change every CE release

| Datastore | Chart / operator | Image | CR | Ready check |
|---|---|---|---|---|
| cert-manager | `cert-manager` 1.21.1 | jetstack v1.21.1 | — | webhook pods Ready |
| Cassandra | `cass-operator` 0.67.0 (op 1.32.0) | cassandra:4.1.11_v0.46.0 | `CassandraDatacenter cassandra` (size 3) | condition Ready **(not verified)**, secret `instana-superuser` |
| ClickHouse Keeper | `ibm-clickhouse-operator` v1.2.0 | clickhouse:25.8.13.73-7-lts-ibm | `ClickHouseKeeperInstallation` | status Completed |
| ClickHouse | same | same | `ClickHouseInstallation instana` | `.status.status == Completed` |
| Elasticsearch | `eck-operator` 3.5.0 | elasticsearch:8.19.20_v0.43.0 | `Elasticsearch instana` | `ReconciliationComplete`, health green |
| Kafka | `strimzi-kafka-operator` 1.9.0 | kafka 4.3.1 (KRaft) | `Kafka instana` + NodePools + `KafkaUser` | condition Ready |
| Postgres | `cloudnative-pg` 0.29.0 | cnpg-containers:15_v0.44.0 | `Cluster postgres` | condition Ready **(not verified)** |
| BeeInstana | `beeinstana-operator` 1.116.0 + `instana-beeinstana` 1.8.0 (repo values) | v1.85.108 | — | pods Ready |

**Order:** Cassandra → Keeper → ClickHouse → Elasticsearch → Kafka (+ user) → Postgres → BeeInstana.
Passwords are read back from each datastore's secrets into the Core Secret `datastoreConfigs`.
The installer needs its own **versions table keyed by CE version** (IBM's repo already lags its docs).

## 5. Operator, Core, Unit, health

- Namespaces `instana-operator`, `instana-core`, `instana-units` (labelled), `instana-registry` pull secret in each.
- Core Secret (`config.yaml`): `dhParams`, `repositoryPassword`, `salesKey`, `tokenSecret`, raw-spans
  credentials, optional SAML/OIDC, proxy, SMTP, custom CA, `datastoreConfigs`.
- Unit Secret: `initialAdminUser`, `initialAdminPassword`, `licenses`, `agentKeys`, `downloadKey`.
- Core: `baseDomain`, `gatewayConfig.acceptors.*`, `storageConfigs.rawSpans`, `datastoreConfigs`,
  `imageConfig.tag`, `operationMode`. Unit: `tenantName` (`^[a-z][a-z0-9]*$`, ≤ 15), `unitName`, `resourceProfile`.
- **Healthy** when Core and Unit show `.status.dbMigrationStatus == Ready` and `.status.componentsStatus == Ready`,
  then the UI answers over HTTPS through the Route.

## 6. Upgrade, uninstall, resume

- **Upgrade:** matching plug-in, re-apply the operator from newly generated manifests, then
  `kubectl instana versions update` or `imageConfig.tag`. Elasticsearch disks must be < 80 %.
  Some releases need `operationMode: maintenance`. **No rollback.**
- **Uninstall:** no IBM page found **(not verified)**. Order used by IBM's repo: Units (remove finalizers) →
  Core (same) → operator → datastores (Helm + PVCs) → cert-manager → Routes. Old PVCs must be removed before reinstalling.
- **Resume:** every step idempotent (`helm upgrade --install`, `kubectl apply`). Each phase re-checks Helm
  status, CR status, that secrets exist (**never regenerate** `tokenSecret`, DH params, ClickHouse/admin
  passwords — read them back), a manifest hash, and that the **cluster ID** and API URL still match the state
  (catches a changed `oc` context).

## 7. Air-gapped

On a connected bastion: `skopeo copy` the ~18 datastore images plus backend/operator images from
`kubectl instana versions list-images`, keeping image names; `helm pull` the charts; copy the plug-in and
the license file. In the cluster: point every Helm image value, the operator values and Core
`imageConfig.registry` at the mirror; create the internal pull secret. `oc-mirror` + ImageDigestMirrorSet
would also work but is **not validated with Instana**. Bundle size **not documented** (expect tens of GB).

---

## 8. Design for the installer

**Separate mode:** `install-openshift.sh`, offered in the `install.sh` start menu as
"OpenShift cluster (Custom Edition)"; `PLATFORM=openshift` in the input schema and state.
Prerequisite: move the shared UI helpers (`log`, `die_with_steps`, `prompt_*`, `hint`, `spin_run`,
`on_exit_report`, report writer) into `lib/ui.sh` with no behaviour change. New modules under `openshift/`
(`preflight`, `datastores`, `backend`, `routes`, `destroy`, `airgap`, `versions`). Follow the documented path;
do not shell out to `shce.sh`.

| # | Phase | What it does / checks | Resume rule |
|---|---|---|---|
| 1 | Tools, lock, login | `oc`, `kubectl`, `helm` v3, `jq`, `yq`, `kubectl-instana` (version = chosen CE), `openssl` (+ `skopeo` air-gapped); `oc whoami`, `--show-server`, `oc auth can-i '*' '*' -A`, cluster ID; **show API URL, user, cluster ID and ask to confirm** | cluster ID must match state |
| 2 | Parameters, versions, plan | input file or questions, CE/backend version first, plan with namespaces, storage classes, PVC totals, DNS names | locked after first apply |
| 3 | Cluster preflight | OpenShift ≥ 4.13, nodes Ready, allocatable vs profile, default + RWX storage class or S3, x86-64-v3 flags via `oc debug node`, ingress domain, DNS | always re-run (read-only) |
| 4 | cert-manager | reuse existing, else Helm install + wait for webhooks | Helm status |
| 5 | Namespaces, pull secrets, SCC | create/label, test pull with a probe pod, `cassandra-scc`, read UID ranges | idempotent apply |
| 6 | Datastore operators | six `helm upgrade --install`, wait Deployments Available | Helm + Deployment |
| 7 | Datastore instances | in order, each with its readiness check and a heartbeat label | skip only if Ready **and** spec hash matches |
| 8 | Credentials, secrets, TLS | read datastore passwords, generate-or-read DH/token/ClickHouse, `instana-tls`, Core Secret | never regenerate |
| 9 | Enterprise operator | `kubectl instana operator apply`, wait pods + webhook caBundle | re-check |
| 10 | License, Core | license download (file when air-gapped), apply Core, wait Ready (≤ 45 min, heartbeat) | Core status |
| 11 | Unit | Unit Secret + CR, wait Ready | Unit status |
| 12 | Routes, DNS, verify, report | passthrough Routes (`--dry-run=client -o yaml \| oc apply -f -`), DNS lookups, `curl -k` UI, TLS to acceptor, `.install-report.txt` with DNS lines (no indentation) | always re-run |

**Lab DNS shortcut (not verified):** use the cluster's `*.apps.<domain>` wildcard — `baseDomain:
instana.apps.<domain>` with `pathStyle: true`, acceptors on single-level names — so no DNS changes are needed.

**HOW TO RESOLVE stops (what / why / fix / continue), examples:**
- Wrong `oc` login / cluster ID differs → `oc login https://api.<expected>:6443`, `oc whoami --show-server` → `--resume`.
- Not cluster-admin → `oc adm policy add-cluster-role-to-user cluster-admin <user>` (by an admin) → `--resume`.
- No default / RWX storage class → `oc get sc`, `oc patch storageclass … is-default-class=true`, or `RAW_SPANS_MODE=s3` → `--resume`.
- Not enough capacity → "Allocatable X < profile Y" → `oc scale machineset …` or smaller profile → `--resume`.
- Datastore not Ready after timeout → `oc get pods,pvc -n <ns>`, `oc describe pod`, usual causes (PVC Pending, SCC denial) → `--resume` re-runs only that datastore.
- Pull secret wrong (probe pod 401) → check key, `oc delete secret instana-registry -n <ns>` → `--resume`.
- Route DNS missing → print the exact DNS lines, `dig +short` → `--resume` (phase 12 only).

**`--config` additions:** `PLATFORM`, `OCP_API_URL`, `OCP_CONTEXT`, `OCP_EXPECT_CLUSTER_ID`, `CE_VERSION`,
`BACKEND_VERSION`, `SIZE_PROFILE` (demo/small/production), `NS_OPERATOR`/`NS_CORE`/`NS_UNITS`/`NS_PREFIX`,
`STORAGE_CLASS_DEFAULT` + per-datastore overrides, `RAW_SPANS_MODE` (pvc/s3/gcs) + S3 fields, `KEEPER_MODE`,
`BEEINSTANA`, `DNS_MODE` (apps-wildcard/custom), `BASE_DOMAIN`, `PATH_STYLE`, `TLS_MODE`, `ROUTE_TERMINATION`,
air-gapped registry fields, `LICENSE_FILE`; new masked secrets `REGISTRY_PASSWORD`, `S3_SECRET_ACCESS_KEY`.
`config-generator.html` gets a third target card "Existing OpenShift cluster" with live vCPU/RAM/PVC totals
and the list of DNS records/Routes to create.

## 9. Testing

**Without a cluster:** one fake dispatcher symlinked as `oc`, `kubectl`, `helm`, `kubectl-instana`, driven by
scenario files (argv pattern → stdout/exit code, status changes after N calls), every call logged — same idea
as the existing mock `gcloud`. Suites: preflight stops, datastore order/readiness/timeouts, resume after
phase 7 and 10 (no secret regeneration, context-change stop), config schema, dry-run, air-gapped image list.

**Needs a real cluster:** SCC/UID behaviour, webhook + cert-manager, real Core/Unit status timing, Routes/TLS,
storage performance. Five runs: fresh online, resume mid-datastore, resume mid-Core, uninstall, air-gapped.

**Where to get a cluster (estimates, not verified):**
- **IBM TechZone OpenShift reservation** — likely cheapest for support; check sizes and cluster-admin.
- OpenShift on GCP (IPI, 60-day trial): 3 × n2-standard-4 control plane + 5 × n2-standard-16 workers,
  ~$4.5–6/h + ~2 TB pd-ssd → ~$15–25 per full test run; destroy right after.
- Single Node OpenShift on one n2-standard-64 (~$3–4/h) — script testing only, not an Instana topology.
- ROSA ≈ $7.5/h before storage. OpenShift Local (CRC): unusable (too small, no nested virtualization on GCP).

## 10. Effort (person-days)

| Part | Days |
|---|---|
| Shared helpers into `lib/` (no behaviour change) | 2–3 |
| Skeleton, menu entry, state, report, cluster-ID lock | 2–3 |
| Preflight | 3 |
| Datastores (7, incl. BeeInstana) | 6–8 |
| Secrets, TLS, license, operator, Core, Unit | 4 |
| Routes, DNS, verify, report | 2 |
| Resume / idempotency hardening | 3–4 |
| Uninstall | 2 |
| `--config`, generator section, examples | 3 |
| Fake kube + test suites | 5–6 |
| Real-cluster iterations | 5–8 |
| Docs | 1–2 |
| **Online MVP** | **~35–45** |
| Air-gapped | +8–12 |

## 11. Risks

Cluster cost and size; version churn every CE release; doc gaps (x86 sizing, uninstall, readiness conditions,
agent vs download key); managed OpenShift may restrict SCCs or cluster-admin; RWX/S3 requirement and IOPS;
overlap with IBM's `shce.sh`; x86-64-v3 on old hypervisors; scope creep toward provisioning the cluster itself.

## 12. Open decisions

1. ~~Audience~~ — **decided: internal support use** (2026-10-19).
2. Test clusters: TechZone, own OpenShift on GCP, or ROSA? Should the tool create the cluster? (Recommended: not in v1.)
3. Air-gapped in v1 or v2?
4. Smaller-than-documented demo profile acceptable for labs?
5. Own implementation of the documented path (recommended) or a thin wrapper around `shce.sh` as a prototype?
6. Raw spans default: S3/GCS or RWX PVC?
7. State in the same `.install-state.json` with `platform: openshift`, or a separate folder per lab?
8. Apps-wildcard + path-style DNS shortcut acceptable for labs?
9. Version policy: latest CE only, or a choosable list?

## Sources

- CE overview and compatibility matrix: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/index.html
- Requirements: https://www.ibm.com/docs/en/SSO4JPD/src/pages/setup_and_manage/backend_requirements.html
- Storage considerations: https://www.ibm.com/docs/en/SSE1JP5_current/src/pages/self_hosted/kubernetes_operator/datastores/storage_considerations.html
- Operator install: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/installing/operator.html
- Install workflow: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/installing/index.html
- Backend (Core/Unit/secrets/raw spans): https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/installing/backend.html
- Ingress, DNS, Routes: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/installing/ingress.html
- kubectl plug-in: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/installing/kubectl_plugin.html
- Datastore preparation (x86): https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/datastores/amd/preparing.html
- Datastore order: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/datastores/amd/deploying.html
- Upgrading: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/upgrading.html
- Air-gapped upgrade / mirroring: https://www.ibm.com/docs/en/SSO4JPD/src/pages/self_hosted/kubernetes_operator/Upgrading/upgrading-custom-edition-in-an-air-gapped-environment.html
- IBM setup repo: https://github.com/instana/self-hosted-custom-edition-setup
- OpenShift Local requirements: https://access.redhat.com/documentation/id-id/red_hat_openshift_local/2.13/html/release_notes_and_known_issues/minimum-system-requirements_rn-ki
- oc-mirror v2: https://docs.okd.io/4.18/disconnected/about-installing-oc-mirror-v2.html
- ROSA pricing: https://aws.amazon.com/rosa/pricing/
