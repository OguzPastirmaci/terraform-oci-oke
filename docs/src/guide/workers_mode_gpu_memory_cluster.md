# Workers / Mode: GPU Memory Cluster

<p>

Provision bare metal GPU workers that share a high-bandwidth GPU memory fabric managed by the `oci_core_compute_gpu_memory_cluster` resource. All worker pools that use this mode join the same compute cluster created by the module.

Configured with `mode = "gpu-memory-cluster"` on a `worker_pools` entry, or by setting `worker_pool_mode = "gpu-memory-cluster"` to use it as the default for all pools.
</p>

## Usage

```hcl
worker_pools = {
  gpu-memory-cluster-workers = {
    description = "Self-managed GPU workers sharing a GPU memory fabric"

    mode = "gpu-memory-cluster"
    size = 2

    compartment_id = "ocid1.compartment.oc1..exampleuniqueID"
    subnet_id      = "ocid1.subnet.oc1..exampleuniqueID"

    placement_ads = [1]
    shape                   = "BM.GPU.GB200.4"
    image_type              = "custom"
    image_id                = "ocid1.image.oc1..exampleuniqueID"
    boot_volume_size        = 200
    boot_volume_vpus_per_gb = 20
    ocpus                   = 8
    memory                  = 512
    placement_ad            = 1

    gpu_memory_fabric_ids = [
      "ocid1.gpumemoryfabric.oc1..exampleuniqueID1",
      "ocid1.gpumemoryfabric.oc1..exampleuniqueID2"
    ]

    cloud_init = [
      {
        content = <<-EOT
#!/usr/bin/env bash
echo "Configuring GPU memory workers"
EOT
      }
    ]
  }
}
```

## References
* [Compute GPU Memory Clusters](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_compute_gpu_memory_cluster)
* [GPU Memory Fabric overview](https://docs.oracle.com/en-us/iaas/Content/Compute/References/gpu-memory-fabric.htm)
