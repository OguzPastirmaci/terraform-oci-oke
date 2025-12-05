# Workers / Mode: GPU Memory Cluster

<p>

Provision bare metal GPU workers that share a high-bandwidth GPU memory fabric managed by the `oci_core_compute_gpu_memory_cluster` resource. All worker pools that use this mode join the same compute cluster created by the module.

Configured with `mode = "gpu-memory-cluster"` on a `worker_pools` entry, or by setting `worker_pool_mode = "gpu-memory-cluster"` to use it as the default for all pools.
</p>

## Usage

```javascript
{{#include ../../../examples/workers/vars-workers-gpu-memory-cluster.auto.tfvars:4:}}
```

## References
* [Compute GPU Memory Clusters](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_compute_gpu_memory_cluster)
* [GPU Memory Fabric overview](https://docs.oracle.com/en-us/iaas/Content/Compute/References/gpu-memory-fabric.htm)
