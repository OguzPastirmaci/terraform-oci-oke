# Copyright (c) 2022, 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# GPU Memory Clusters (GMC) for worker pools with mode = "gpu-memory-cluster"
# This creates for EACH GMF ID provided in gpu_memory_fabric_ids:
# 1. A Compute Cluster (RDMA network group)
# 2. An Instance Configuration (via instanceconfig.tf, shared with cluster-network mode)
# 3. A GMC that provisions instances within the compute cluster using the GMF

# Query available GMFs for reference (used for available_host_count lookup)
data "oci_core_compute_gpu_memory_fabrics" "available" {
  for_each = local.enabled_gpu_memory_clusters

  # Use tenancy_id for GMFs as they may be at tenancy level
  compartment_id      = var.tenancy_id
  availability_domain = lookup(each.value, "placement_ad", null) != null ? lookup(var.ad_numbers_to_names, lookup(each.value, "placement_ad")) : element(each.value.availability_domains, 0)

  # Filter for healthy and occupied fabrics (OCCUPIED for testing, change to AVAILABLE for production)
  compute_gpu_memory_fabric_health          = "HEALTHY"
  compute_gpu_memory_fabric_lifecycle_state = "OCCUPIED"
}

# Local to create a map of GMF instances based on the provided gpu_memory_fabric_ids list
locals {
  # Create a map for each GMF ID provided in the pool config: { "pool_name-0" => { pool_config, gmf_id, index } }
  all_gmfs = merge([
    for pool_name, pool_config in local.enabled_gpu_memory_clusters : {
      for idx, gmf_id in lookup(pool_config, "gpu_memory_fabric_ids", []) :
      "${pool_name}-${idx}" => {
        pool_name           = pool_name
        pool_config         = pool_config
        gmf_index           = idx
        gmf_id              = gmf_id
        availability_domain = lookup(pool_config, "placement_ad", null) != null ? lookup(var.ad_numbers_to_names, lookup(pool_config, "placement_ad")) : element(pool_config.availability_domains, 0)
      }
    }
  ]...)

  # Map GMF IDs to their available_host_count from the data source
  gmf_host_counts = {
    for pool_name, pool_config in local.enabled_gpu_memory_clusters :
    pool_name => {
      for gmf in try(data.oci_core_compute_gpu_memory_fabrics.available[pool_name].compute_gpu_memory_fabric_collection[0].items, []) :
      gmf.compute_gpu_memory_fabric_id => gmf.available_host_count
    }
  }
}

# Create Compute Clusters for each GMF
resource "oci_core_compute_cluster" "gpu_memory_cluster" {
  for_each       = local.all_gmfs
  compartment_id = each.value.pool_config.compartment_id
  display_name   = format("%s-compute-cluster", each.key)
  defined_tags   = each.value.pool_config.defined_tags
  freeform_tags  = each.value.pool_config.freeform_tags

  availability_domain = each.value.availability_domain

  lifecycle {
    ignore_changes = [
      display_name, defined_tags, freeform_tags,
    ]
  }
}

# Create GMCs for each GMF
resource "oci_core_compute_gpu_memory_cluster" "workers" {
  for_each = local.all_gmfs

  # Required
  availability_domain       = oci_core_compute_cluster.gpu_memory_cluster[each.key].availability_domain
  compartment_id            = each.value.pool_config.compartment_id
  compute_cluster_id        = oci_core_compute_cluster.gpu_memory_cluster[each.key].id
  instance_configuration_id = oci_core_instance_configuration.workers[each.value.pool_name].id

  # Size - use pool size if explicitly set (> 0), otherwise use available_host_count from GMF
  size = coalesce(
    each.value.pool_config.size > 0 ? each.value.pool_config.size : null,
    try(local.gmf_host_counts[each.value.pool_name][each.value.gmf_id], null),
    1
  )

  # GMF ID
  gpu_memory_fabric_id = each.value.gmf_id

  display_name  = each.key
  defined_tags  = each.value.pool_config.defined_tags
  freeform_tags = each.value.pool_config.freeform_tags

  lifecycle {
    ignore_changes = [
      display_name, defined_tags, freeform_tags,
    ]

    precondition {
      condition     = coalesce(each.value.pool_config.image_id, "none") != "none"
      error_message = "Missing image_id for pool ${each.value.pool_name}. Check provided value for image_id if image_type is 'custom', or image_os/image_os_version if image_type is 'oke' or 'platform'."
    }

    precondition {
      condition     = each.value.pool_config.autoscale == false
      error_message = "GMCs do not support cluster autoscaler management."
    }

    precondition {
      condition     = contains(["BM.GPU.GB200.4", "BM.GPU.GB200-v2.4", "BM.GPU.GB200-v3.4", "BM.GPU.GB300.4"], each.value.pool_config.shape)
      error_message = "GMCs require one of: BM.GPU.GB200.4, BM.GPU.GB200-v2.4, BM.GPU.GB200-v3.4, BM.GPU.GB300.4. Current shape: ${each.value.pool_config.shape}"
    }
  }

  # GMC provisioning can take significant time depending on the number of instances and GMFs
  timeouts {
    create = "2h"
    update = "2h"
    delete = "1h"
  }
}
