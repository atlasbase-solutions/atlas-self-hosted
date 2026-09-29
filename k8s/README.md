# Kubernetes deployment

The manifests in this directory are a complete, single-cluster reference installation. They run the Atlas application workloads and single-replica PostgreSQL, ClickHouse, Redis, and Kafka workloads. For a production HA installation, replace the bundled data services with managed or operator-managed equivalents and preserve the same connection contracts.

The Kubernetes manifests differ from the Docker Compose stack in two ways. The edge (the `frontend` Deployment) runs in `proxy` mode: your ingress controller terminates TLS. And the network's domains, the first Network Owner and the license are set by configuration (`01-config.yaml`, `02-secrets.yaml`) rather than in the first-run wizard.

## Prerequisites

- a Kubernetes release that is still supported upstream (1.34 or newer at the time of this release);
- a default `StorageClass` or explicit storage classes added to every PVC;
- an ingress controller compatible with `networking.k8s.io/v1`. `06-ingress.yaml` is written for an NGINX-based controller (`ingressClassName: nginx` and its request-body annotation); with another controller, change the class and set the same 50 MB body limit its own way;
- a TLS secret named `atlas-tls` in namespace `atlas`;
- a private registry reachable by every node.

## 1. Build and publish the three local images

Run from the repository root:

```bash
docker build -f images/portal/Dockerfile -t registry.example.com/atlas/portal:1.0.10 .
docker build -f images/gateway/Dockerfile -t registry.example.com/atlas/gateway:1.0.10 .
docker build -f images/frontend/Dockerfile -t registry.example.com/atlas/frontend:1.0.10 .

docker push registry.example.com/atlas/portal:1.0.10
docker push registry.example.com/atlas/gateway:1.0.10
docker push registry.example.com/atlas/frontend:1.0.10
```

Replace `registry.example.com` with your registry in the three `newName` values of `kustomization.yaml` (and in `05-apps.yaml`/`04-jobs.yaml` if you apply them without Kustomize). If the registry is private, add an `imagePullSecret` to the three application Deployments.

## 2. Configure domains and secrets

Replace `portal.example.com` and `track.example.com` in `01-config.yaml` and `06-ingress.yaml`.

```bash
cp k8s/02-secrets.example.yaml k8s/02-secrets.yaml
```

Replace every `CHANGE_ME` value. The Portal and Gateway copies of `ATLAS_CONFIG_SECRET_KEY` are deliberately one key: hardened postback secrets cannot be decrypted if they differ.

### License delivery

Read the "Licensing" section of the top-level `README.md` first: without a confirmed license, Portal and Gateway start but serve no application traffic. Provide the license in one of two ways:

- **License string (default).** Set `ATLAS_LICENSE_TOKEN` in `02-secrets.yaml` to the license string from your Atlas manager. Both Deployments read the same Secret, so one value covers Portal and Gateway. The cluster needs outbound HTTPS to Atlas (see the top-level README's "Firewall policy").
- **Offline license file (clusters with no outbound internet access).** Ask your Atlas contact for an offline license file and create a Secret from it:

  ```bash
  kubectl -n atlas create secret generic atlas-license-file --from-file=atlas.lic=./license/atlas.lic
  ```

  Then, in `05-apps.yaml`, uncomment the `atlas-license-file` volume and the matching `volumeMounts` entry on both the `portal` and `gateway` containers, and in `01-config.yaml` set `ATLAS_LICENSE_FILE: /etc/atlas/license/atlas.lic` and `ATLAS_LICENSE_ISOLATED: "true"`.

In both cases set `ATLAS_LICENSE_PORTAL_DOMAIN` and `ATLAS_LICENSE_TRACKING_DOMAIN(S)` in `01-config.yaml` to exactly the domains of the license. Leaving the license empty is fine for a first look: the pods come up and stay diagnosable.

Create TLS using your normal certificate workflow. A manual example is:

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl -n atlas create secret tls atlas-tls --cert=fullchain.pem --key=privkey.pem
```

## 3. Apply in dependency order

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-config.yaml
kubectl apply -f k8s/02-secrets.yaml
kubectl apply -f k8s/03-data.yaml

kubectl -n atlas rollout status statefulset/portal-postgres --timeout=5m
kubectl -n atlas rollout status statefulset/gateway-postgres --timeout=5m
kubectl -n atlas rollout status statefulset/clickhouse --timeout=5m
kubectl -n atlas rollout status statefulset/redis --timeout=5m
kubectl -n atlas rollout status statefulset/kafka --timeout=5m

kubectl apply -f k8s/04-jobs.yaml
kubectl -n atlas wait --for=condition=complete job/kafka-init --timeout=5m
kubectl -n atlas wait --for=condition=complete job/gateway-migrate --timeout=5m

kubectl apply -f k8s/05-apps.yaml
kubectl -n atlas rollout status deployment/portal --timeout=5m
kubectl -n atlas rollout status deployment/gateway --timeout=5m
kubectl -n atlas rollout status deployment/frontend --timeout=5m
kubectl apply -f k8s/06-ingress.yaml
```

Do not use `kubectl apply -k k8s/` for the first installation unless your deployment controller supports ordered hooks. Kustomize renders the complete set but does not wait for databases and migration Jobs between resources.

## 4. Verify

```bash
kubectl -n atlas get pods,pvc,svc,ingress
kubectl -n atlas port-forward service/portal 11082:11082
curl -fsS http://127.0.0.1:11082/health/ready
curl -fsS http://127.0.0.1:11082/version
```

In another terminal:

```bash
kubectl -n atlas port-forward service/gateway 18080:8080
curl -fsS http://127.0.0.1:18080/health/ready
curl -fsS http://127.0.0.1:18080/version
```

## Scaling notes

- Gateway and the edge (the `frontend` Deployment) are stateless and may be scaled horizontally.
- Portal replicas must share the same promo-file directory. The reference PVC is `ReadWriteOnce`, so the reference manifest intentionally runs one Portal replica. Use `ReadWriteMany` storage before scaling it.
- The bundled data workloads are single replicas. Production HA requires a database/Kafka/ClickHouse design supplied by the customer's platform team.
- Redis persistence is enabled because click attribution and spill queues are operational state, not a disposable cache.
- Keep Portal and Gateway build versions aligned during an upgrade.

## Uninstall

Deleting namespace `atlas` also deletes workloads and may delete dynamically provisioned volumes. Back up PostgreSQL, ClickHouse, Redis, Kafka, and `portal-files` first.


## Shared reputation-package storage

The `antifraud-feed` claim in `05-apps.yaml` requires a storage class supporting `ReadWriteMany` across Portal and Gateway nodes. Select that class before deployment and ensure group `10001` can write to it. Portal publishes packages into the shared parent directory; Gateway mounts it read-only. The subscription endpoint (`https://antifraud.getatlasbase.com`) is built into Portal; allow outbound HTTPS to it. Without a subscription, remove the claim and both mounts and set `ATLAS_ANTIFRAUD_FEED_DIR` to an empty string. Local anti-fraud rules remain available.
