# Cluster Sizing Guide

This guide helps you select the right Kubernetes cluster configuration for your Qualytics deployment based on your data processing volume.

## Overview

Qualytics runs on a Kubernetes cluster organized into **three node pools**:

| Node Pool | Role | Count |
|-----------|------|-------|
| **Application** | Qualytics web application, API, and databases | 1 node (on-demand) |
| **Driver** | Coordinates data processing jobs and schedules parallel work | 1 node (on-demand) |
| **Executor** | Performs data scanning, profiling, and quality checks | Up to 12 nodes (recommended default, configurable) |

Qualytics scales by changing the **instance type** of each node pool — not by varying the number of executors. The recommended configuration uses up to **12 executors**, but customers can configure `maxExecutors` to suit their needs. What matters most is the **total resources available** — CPU, RAM, and local SSD across the executor pool.

> **Dynamic allocation**: Spark's dynamic allocation scales executor pods between 1 and `maxExecutors` (default 12) within the node pool. Idle executors are reclaimed automatically, so you only pay for active executor pods — not the full pool — when the cluster is idle.

---

## Sizing Tiers

Choose your tier based on the **total volume of data** Qualytics will monitor across all connected data sources.

### Quick Reference

| Tier | Data Under Management | Per Executor | Total Executor Pool | Max Single Operation |
|------|----------------------|-------------|--------------------|-----------------------|
| **Small** | Up to 1 TB | 4 vCPUs, 32 GB RAM, 237 GB SSD | 48 vCPUs, 384 GB RAM | ~230 GB |
| **Medium** | 1 – 10 TB | 8 vCPUs, 64 GB RAM, 474 GB SSD | 96 vCPUs, 768 GB RAM | ~460 GB |
| **Large** | 10 – 50 TB | 16 vCPUs, 128 GB RAM, 950 GB SSD | 192 vCPUs, 1.5 TB RAM | ~920 GB |
| **X-Large** | 50 – 100 TB | 32 vCPUs, 256 GB RAM, 1.9 TB SSD | 384 vCPUs, 3 TB RAM | ~1.8 TB |
| **2X-Large** | 100 – 500 TB | 48 vCPUs, 384 GB RAM, 2.85 TB SSD | 576 vCPUs, 4.5 TB RAM | ~2.7 TB |
| **4X-Large** | 500+ TB | 64 vCPUs, 512 GB RAM, 3.8 TB SSD | 768 vCPUs, 6 TB RAM | ~3.6 TB |

> Tables exceeding the max single-operation size are automatically chunked — no data is rejected — but chunking introduces sequential overhead.

### Application and Driver Nodes

The application node stays constant across all tiers. The driver node scales with the tier to support more concurrent operations:

| Node Pool | Small / Medium | Large / X-Large | 2X-Large / 4X-Large |
|-----------|---------------|-----------------|---------------------|
| **Application** | 8 vCPUs, 32 GB RAM | 8 vCPUs, 32 GB RAM | 8 vCPUs, 32 GB RAM |
| **Driver** | 8 vCPUs, 64 GB RAM | 16 vCPUs, 128 GB RAM | 32 vCPUs, 256 GB RAM |

---

## On-Premises / Bare-Metal Sizing

For deployments on private datacenter infrastructure, use these cloud-agnostic resource requirements.

### Total Resources by Node Pool

| Tier | Data Volume | Application Pool | Driver Pool | Executor Pool (per node) |
|------|------------|-----------------|-------------|--------------------------|
| | | vCPUs / RAM | vCPUs / RAM | vCPUs / RAM / SSD |
| **Small** | ≤ 1 TB | 8 / 32 GB | 8 / 64 GB | 4 / 32 GB / 250 GB |
| **Medium** | 1 – 10 TB | 8 / 32 GB | 8 / 64 GB | 8 / 64 GB / 500 GB |
| **Large** | 10 – 50 TB | 8 / 32 GB | 16 / 128 GB | 16 / 128 GB / 1 TB |
| **X-Large** | 50 – 100 TB | 8 / 32 GB | 16 / 128 GB | 32 / 256 GB / 2 TB |
| **2X-Large** | 100 – 500 TB | 8 / 32 GB | 32 / 256 GB | 48 / 384 GB / 3 TB |
| **4X-Large** | 500+ TB | 8 / 32 GB | 64 / 512 GB | 64 / 512 GB / 4 TB |

### Total Cluster Resources (All Pools Combined)

Assuming the recommended default of 12 executor nodes:

| Tier | Total Nodes | Total vCPUs | Total RAM | Total SSD (Executors) |
|------|:-----------:|:-----------:|:---------:|:---------------------:|
| **Small** | 14 | 64 | 480 GB | 3 TB |
| **Medium** | 14 | 112 | 864 GB | 6 TB |
| **Large** | 14 | 216 | 1.7 TB | 12 TB |
| **X-Large** | 14 | 408 | 3.2 TB | 24 TB |
| **2X-Large** | 14 | 616 | 4.8 TB | 36 TB |
| **4X-Large** | 14 | 840 | 6.5 TB | 48 TB |

> **SSD requirement**: Each executor node needs fast local storage (NVMe SSD preferred) for Spark scratch space. Network-attached storage (NAS/SAN) is not recommended for scratch space due to latency. Provision at least **5–8× the executor RAM** in local SSD.

### Infrastructure Notes

- **Kubernetes version**: 1.30+ recommended
- **Container runtime**: containerd (recommended) or CRI-O
- **Node labels**: Apply `appNodes=true`, `driverNodes=true`, and `executorNodes=true` to the respective node pools
- **Networking**: 10 Gbps minimum between executor nodes (25 Gbps recommended for Large and above)
- **Scratch storage**: Executor pods write Spark scratch to the node's ephemeral storage; place it on the node-local SSDs (see [Scratch Storage](#scratch-storage))
- **Resource headroom**: Reserve ~10–15% of each node's CPU and RAM for the kubelet and OS

---

## Instance Types by Cloud Provider

All tiers use the **same instance family** per provider, scaling by instance size.

### AWS EKS — r8gd Family

| Tier | Application Node | Driver Node | Executor Node | Executor NVMe SSD | NVMe Disks |
|------|:---:|:---:|:---:|:---:|:---:|
| **Small** | m8g.2xlarge (8 vCPU, 32 GB) | r8g.2xlarge (8 vCPU, 64 GB) | r8gd.xlarge (4 vCPU, 32 GB) | 237 GB | 1 |
| **Medium** | m8g.2xlarge (8 vCPU, 32 GB) | r8g.2xlarge (8 vCPU, 64 GB) | r8gd.2xlarge (8 vCPU, 64 GB) | 474 GB | 1 |
| **Large** | m8g.2xlarge (8 vCPU, 32 GB) | r8g.4xlarge (16 vCPU, 128 GB) | r8gd.4xlarge (16 vCPU, 128 GB) | 950 GB | 1 |
| **X-Large** | m8g.2xlarge (8 vCPU, 32 GB) | r8g.4xlarge (16 vCPU, 128 GB) | r8gd.8xlarge (32 vCPU, 256 GB) | 1,900 GB | 1 |
| **2X-Large** | m8g.2xlarge (8 vCPU, 32 GB) | r8g.8xlarge (32 vCPU, 256 GB) | r8gd.12xlarge (48 vCPU, 384 GB) | 2,850 GB | 3 |
| **4X-Large** | m8g.2xlarge (8 vCPU, 32 GB) | r8g.8xlarge (32 vCPU, 256 GB) | r8gd.16xlarge (64 vCPU, 512 GB) | 3,800 GB | 2 |

> The `r8gd` family uses AWS Graviton4 (arm64) processors. The "d" suffix indicates local NVMe SSD storage. Application and driver nodes use `m8g` and `r8g` (no local SSD needed).

### GCP GKE

| Tier | Application Node | Driver Node | Executor Node | Local SSD |
|------|:---:|:---:|:---:|:---:|
| **Small** | n4-standard-8 (8 vCPU, 32 GB) | n4-highmem-8 (8 vCPU, 64 GB) | n2-highmem-4 + Local SSD (4 vCPU, 32 GB) | 1 × 375 GB |
| **Medium** | n4-standard-8 (8 vCPU, 32 GB) | n4-highmem-8 (8 vCPU, 64 GB) | n2-highmem-8 + Local SSD (8 vCPU, 64 GB) | 1 × 375 GB |
| **Large** | n4-standard-8 (8 vCPU, 32 GB) | n4-highmem-16 (16 vCPU, 128 GB) | n2-highmem-16 + Local SSD (16 vCPU, 128 GB) | 2 × 375 GB |
| **X-Large** | n4-standard-8 (8 vCPU, 32 GB) | n4-highmem-16 (16 vCPU, 128 GB) | n2-highmem-32 + Local SSD (32 vCPU, 256 GB) | 4 × 375 GB |
| **2X-Large** | n4-standard-8 (8 vCPU, 32 GB) | n4-highmem-32 (32 vCPU, 256 GB) | n2-highmem-48 + Local SSD (48 vCPU, 384 GB) | 6 × 375 GB |
| **4X-Large** | n4-standard-8 (8 vCPU, 32 GB) | n4-highmem-32 (32 vCPU, 256 GB) | n2-highmem-64 + Local SSD (64 vCPU, 512 GB) | 8 × 375 GB |

> GKE: Attach local SSDs as ephemeral storage via node pool config (`--ephemeral-storage-local-ssd count=N`). Each local SSD provides 375 GB.

### Azure AKS

| Tier | Application Node | Driver Node | Executor Node | Temp SSD |
|------|:---:|:---:|:---:|:---:|
| **Small** | Standard_D8s_v6 (8 vCPU, 32 GB) | Standard_E8s_v6 (8 vCPU, 64 GB) | Standard_E4ds_v5 (4 vCPU, 32 GB) | 150 GB |
| **Medium** | Standard_D8s_v6 (8 vCPU, 32 GB) | Standard_E8s_v6 (8 vCPU, 64 GB) | Standard_E8ds_v5 (8 vCPU, 64 GB) | 300 GB |
| **Large** | Standard_D8s_v6 (8 vCPU, 32 GB) | Standard_E16s_v6 (16 vCPU, 128 GB) | Standard_E16ds_v5 (16 vCPU, 128 GB) | 600 GB |
| **X-Large** | Standard_D8s_v6 (8 vCPU, 32 GB) | Standard_E16s_v6 (16 vCPU, 128 GB) | Standard_E32ds_v5 (32 vCPU, 256 GB) | 1,200 GB |
| **2X-Large** | Standard_D8s_v6 (8 vCPU, 32 GB) | Standard_E32s_v6 (32 vCPU, 256 GB) | Standard_E48ds_v5 (48 vCPU, 384 GB) | 1,800 GB |
| **4X-Large** | Standard_D8s_v6 (8 vCPU, 32 GB) | Standard_E32s_v6 (32 vCPU, 256 GB) | Standard_E64ds_v5 (64 vCPU, 512 GB) | 2,400 GB |

Executor nodes can use **spot/preemptible instances** to reduce costs. Application and driver nodes should use on-demand instances.

---

## Helm Configuration by Tier

The values that change between tiers are the sizes of the driver and executor pods. Set each one under `resources` in Kubernetes units, the same way you size any other pod. The chart derives the JVM heap and Spark's memory overhead from it: with the default `memoryOverheadFactor: 0.1`, the heap is the pod's memory divided by 1.1.

> **Resource headroom**: The `cpu` and `memory` values are set below node capacity to leave room for the kubelet and OS.

> **Existing deployments**: `dataplane.driver.cores` / `memory` and `dataplane.executor.cores` / `memory` (Spark heap, such as `55000m`) keep working while `resources` is not set. `dataplane.numVolumes` is deprecated and has no effect, because the chart no longer mounts host disks (see [Scratch Storage](#scratch-storage)); remove it from your values when convenient.

### Small

```yaml
dataplane:
  driver:
    resources:
      cpu: 3
      memory: "26400Mi"
  executor:
    resources:
      cpu: 3
      memory: "26400Mi"
```

### Medium (Default)

```yaml
dataplane:
  driver:
    resources:
      cpu: 7
      memory: "60500Mi"
  executor:
    resources:
      cpu: 7
      memory: "60500Mi"
```

### Large

```yaml
dataplane:
  driver:
    resources:
      cpu: 15
      memory: "121000Mi"
  executor:
    resources:
      cpu: 15
      memory: "121000Mi"
```

### X-Large

```yaml
dataplane:
  driver:
    resources:
      cpu: 31
      memory: "242000Mi"
  executor:
    resources:
      cpu: 31
      memory: "242000Mi"
```

### 2X-Large

```yaml
dataplane:
  driver:
    resources:
      cpu: 31
      memory: "242000Mi"
  executor:
    resources:
      cpu: 47
      memory: "363000Mi"
```

### 4X-Large

```yaml
dataplane:
  driver:
    resources:
      cpu: 31
      memory: "242000Mi"
  executor:
    resources:
      cpu: 63
      memory: "484000Mi"
```

---

## Scratch Storage

Spark writes its scratch data (shuffle and spill files) to an `emptyDir` volume, which lives on the node's ephemeral storage. The chart does this the same way on every platform and mounts no host disks, so point the executor nodes' ephemeral storage at their local NVMe or SSD:

| Platform | How ephemeral storage lands on local disks |
|----------|--------------------------------------------|
| **EKS Auto Mode** | Automatic. Auto Mode formats the instance-store NVMe (RAID 0 across multiple drives) as the node's ephemeral storage, as long as the NodeClass `ephemeralStorage` size stays below the NVMe capacity. The [`terraform/aws/cluster`](../terraform/aws/cluster) module relies on this. |
| **EKS, self-managed nodes** | Set `localStorage.strategy: RAID0` in the nodeadm `NodeConfig`, or `instanceStorePolicy: RAID0` in a Karpenter `EC2NodeClass`. |
| **GKE** | Create the executor node pool with local SSD-backed ephemeral storage (`--ephemeral-storage-local-ssd count=N`). The [`terraform/gcp/cluster`](../terraform/gcp/cluster) module does this. |
| **AKS** | Scratch uses the node's OS disk by default; size it for your tier. To use the VM's temp disk instead, set the node pool's kubelet disk type to `Temporary`. |
| **On-premises** | Put the kubelet's root directory (`/var/lib/kubelet` by default) on the local SSD. |

---

## Choosing Your Tier

1. **Sum your total data volume** across all datastores that Qualytics will profile and monitor
2. **Identify your largest single table/object** and check it against the tier's max single-operation size
3. **Consider scan frequency** — if you need hourly full scans of large datasets, consider one tier up
4. **Match the tier** to the instance types for your cloud provider and update your `values.yaml`

When in doubt, start with **Medium** — it handles the majority of production workloads. Moving between tiers only requires changing instance types in your node pools and updating the driver and executor `resources` in your Helm configuration.

For workloads beyond 4X-Large or for custom configurations, contact [hello@qualytics.ai](mailto:hello@qualytics.ai).
