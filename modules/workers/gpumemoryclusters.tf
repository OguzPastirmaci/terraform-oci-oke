# Copyright (c) 2022, 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# GPU Memory Clusters (GMC) for worker pools with mode = "gpu-memory-cluster"
# This creates:
# 1. One Compute Cluster (RDMA network group) per pool - shared by all GMCs in that pool
# 2. An Instance Configuration per pool (via instanceconfig.tf, shared with cluster-network mode)
# 3. A GMC for each GMF ID - either explicitly provided or auto-discovered from available GMFs

# Query available GMFs (used for auto-discovery and available_host_count lookup)
data "oci_core_compute_gpu_memory_fabrics" "available" {
  for_each = local.enabled_gpu_memory_clusters

  # Use tenancy_id for GMFs as they may be at tenancy level
  compartment_id      = var.tenancy_id
  availability_domain = lookup(each.value, "placement_ad", null) != null ? lookup(var.ad_numbers_to_names, lookup(each.value, "placement_ad")) : element(each.value.availability_domains, 0)

  # Filter for healthy and available fabrics
  compute_gpu_memory_fabric_health          = "HEALTHY"
  compute_gpu_memory_fabric_lifecycle_state = "OCCUPIED"
}

locals {
  # Separate pools by whether they have explicit GMF IDs or use auto-discovery
  pools_with_explicit_gmfs = {
    for pool_name, pool_config in local.enabled_gpu_memory_clusters :
    pool_name => pool_config if length(lookup(pool_config, "gpu_memory_fabric_ids", [])) > 0
  }

  pools_with_discovered_gmfs = {
    for pool_name, pool_config in local.enabled_gpu_memory_clusters :
    pool_name => pool_config if length(lookup(pool_config, "gpu_memory_fabric_ids", [])) == 0
  }

  # Create a map for pools with explicit GMF IDs (static keys for for_each)
  explicit_gmfs = merge([
    for pool_name, pool_config in local.pools_with_explicit_gmfs : {
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

  # Extract GMF items from data source safely using coalesce to handle null values
  available_gmf_items = {
    for pool_name, pool_config in local.enabled_gpu_memory_clusters :
    pool_name => lookup(coalesce(data.oci_core_compute_gpu_memory_fabrics.available[pool_name].compute_gpu_memory_fabric_collection, [{}])[0], "items", [])
  }

  # Flatten discovered GMFs into a list for count-based resource
  discovered_gmfs_list = flatten([
    for pool_name, pool_config in local.pools_with_discovered_gmfs : [
      for idx, gmf in local.available_gmf_items[pool_name] : {
        pool_name            = pool_name
        pool_config          = pool_config
        gmf_index            = idx
        gmf_id               = gmf.compute_gpu_memory_fabric_id
        available_host_count = gmf.available_host_count
        availability_domain  = lookup(pool_config, "placement_ad", null) != null ? lookup(var.ad_numbers_to_names, lookup(pool_config, "placement_ad")) : element(pool_config.availability_domains, 0)
      }
    ]
  ])

  # Map GMF IDs to their available_host_count from the data source
  gmf_host_counts = {
    for pool_name, pool_config in local.enabled_gpu_memory_clusters :
    pool_name => {
      for gmf in local.available_gmf_items[pool_name] :
      gmf.compute_gpu_memory_fabric_id => gmf.available_host_count
    }
  }
}

# Create one Compute Cluster per pool (shared by all GMCs in that pool)
resource "oci_core_compute_cluster" "gpu_memory_cluster" {
  for_each       = local.enabled_gpu_memory_clusters
  compartment_id = each.value.compartment_id
  display_name   = format("%s-compute-cluster", each.key)
  defined_tags   = each.value.defined_tags
  freeform_tags  = each.value.freeform_tags

  availability_domain = lookup(each.value, "placement_ad", null) != null ? lookup(var.ad_numbers_to_names, lookup(each.value, "placement_ad")) : element(each.value.availability_domains, 0)

  lifecycle {
    ignore_changes = [
      display_name, defined_tags, freeform_tags,
    ]
  }
}

# =============================================================================
# GMCs with explicit gpu_memory_fabric_ids (for_each with static keys)
# =============================================================================
resource "oci_core_compute_gpu_memory_cluster" "explicit" {
  for_each = local.explicit_gmfs

  # Required
  availability_domain       = oci_core_compute_cluster.gpu_memory_cluster[each.value.pool_name].availability_domain
  compartment_id            = each.value.pool_config.compartment_id
  compute_cluster_id        = oci_core_compute_cluster.gpu_memory_cluster[each.value.pool_name].id
  instance_configuration_id = oci_core_instance_configuration.workers[each.value.pool_name].id

  # Size - use pool size if explicitly set (> 0), otherwise use available_host_count from GMF
  size = coalesce(
    each.value.pool_config.size > 0 ? each.value.pool_config.size : null,
    lookup(lookup(local.gmf_host_counts, each.value.pool_name, {}), each.value.gmf_id, null),
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

  timeouts {
    create = "2h"
    update = "2h"
    delete = "1h"
  }
}

# =============================================================================
# GMCs with auto-discovered GMFs (count-based for dynamic keys)
# =============================================================================
resource "oci_core_compute_gpu_memory_cluster" "discovered" {
  count = length(local.discovered_gmfs_list)

  # Required
  availability_domain       = oci_core_compute_cluster.gpu_memory_cluster[local.discovered_gmfs_list[count.index].pool_name].availability_domain
  compartment_id            = local.discovered_gmfs_list[count.index].pool_config.compartment_id
  compute_cluster_id        = oci_core_compute_cluster.gpu_memory_cluster[local.discovered_gmfs_list[count.index].pool_name].id
  instance_configuration_id = oci_core_instance_configuration.workers[local.discovered_gmfs_list[count.index].pool_name].id

  # Size - use pool size if explicitly set (> 0), otherwise use available_host_count from GMF
  size = coalesce(
    local.discovered_gmfs_list[count.index].pool_config.size > 0 ? local.discovered_gmfs_list[count.index].pool_config.size : null,
    local.discovered_gmfs_list[count.index].available_host_count,
    1
  )

  # GMF ID
  gpu_memory_fabric_id = local.discovered_gmfs_list[count.index].gmf_id

  display_name  = "${local.discovered_gmfs_list[count.index].pool_name}-${local.discovered_gmfs_list[count.index].gmf_index}"
  defined_tags  = local.discovered_gmfs_list[count.index].pool_config.defined_tags
  freeform_tags = local.discovered_gmfs_list[count.index].pool_config.freeform_tags

  lifecycle {
    ignore_changes = [
      display_name, defined_tags, freeform_tags,
    ]

    precondition {
      condition     = coalesce(local.discovered_gmfs_list[count.index].pool_config.image_id, "none") != "none"
      error_message = "Missing image_id for pool ${local.discovered_gmfs_list[count.index].pool_name}. Check provided value for image_id if image_type is 'custom', or image_os/image_os_version if image_type is 'oke' or 'platform'."
    }

    precondition {
      condition     = local.discovered_gmfs_list[count.index].pool_config.autoscale == false
      error_message = "GMCs do not support cluster autoscaler management."
    }

    precondition {
      condition     = contains(["BM.GPU.GB200.4", "BM.GPU.GB200-v2.4", "BM.GPU.GB200-v3.4", "BM.GPU.GB300.4"], local.discovered_gmfs_list[count.index].pool_config.shape)
      error_message = "GMCs require one of: BM.GPU.GB200.4, BM.GPU.GB200-v2.4, BM.GPU.GB200-v3.4, BM.GPU.GB300.4. Current shape: ${local.discovered_gmfs_list[count.index].pool_config.shape}"
    }
  }

  timeouts {
    create = "2h"
    update = "2h"
    delete = "1h"
  }
}
