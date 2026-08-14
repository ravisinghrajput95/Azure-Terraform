################################################################################
# NSG rule matrix
#
# Implements docs/NETWORKING.md section 3. Kept in its own file because this is
# the security policy of the environment, and it should be reviewable as a unit
# rather than buried among module wiring.
#
# Every source and destination prefix is derived from
# module.networking.subnet_cidrs, so the tier boundaries come from the address
# plan rather than being restated here. Changing a subnet's CIDR updates the
# rules that reference it automatically.
#
# On the explicit deny at priority 4096 in every NSG: Azure's built-in
# AllowVnetInBound rule at priority 65000 permits ALL traffic between any two
# VNet addresses on any port. Without a lower-priority deny, an NSG containing
# only Allow rules enforces nothing — the built-in rule catches everything the
# explicit rules did not, and every subnet can reach every other subnet.
################################################################################

locals {
  cidr = module.networking.subnet_cidrs

  app_subnet     = local.subnet_names["app"]
  biz_subnet     = local.subnet_names["biz"]
  db_subnet      = local.subnet_names["db"]
  pep_subnet     = local.subnet_names["pep"]
  mgmt_subnet    = local.subnet_names["mgmt"]
  aks_subnet     = "snet-aks-dev-cus"
  bastion_subnet = "AzureBastionSubnet"

  # Ingress source for the application tier depends on what fronts it. With
  # Application Gateway, the gateway subnet is the only permitted source. With
  # a public load balancer — dev, because AppGW has no inexpensive tier —
  # inbound flows arrive from the internet carrying their original source
  # address, because a load balancer DNATs without replacing the source.
  #
  # 10.10.1.0/24 is the reserved Application Gateway range from
  # docs/NETWORKING.md, held but not allocated in dev.
  app_ingress_source = module.profile.enable_application_gateway ? "10.10.1.0/24" : "Internet"

  # Reused across every NSG. Placed at 4096, the highest usable priority, so
  # any Allow rule takes precedence and the deny is the fallthrough.
  deny_all_inbound = {
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Fallthrough deny. Required: Azure's built-in AllowVnetInBound at 65000 would otherwise permit all intra-VNet traffic."
  }

  # Operator SSH arrives only via Bastion. No subnet accepts SSH from anywhere
  # else, and no instance carries a public IP.
  allow_ssh_from_bastion = {
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.cidr[local.bastion_subnet]
    destination_address_prefix = "*"
    description                = "Operator SSH via Azure Bastion only."
  }

  # Azure's health probes originate from the AzureLoadBalancer service tag,
  # not from the load balancer's frontend address. Blocking it marks every
  # backend instance unhealthy and takes the tier out of rotation.
  allow_lb_probe = {
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    description                = "Load balancer health probes. Blocking this marks all backends unhealthy."
  }

  nsg_definitions = {
    ############################################################################
    # Application tier
    ############################################################################
    (module.naming.network_security_group_names["app"]) = {
      subnet_id = module.networking.subnet_ids[local.app_subnet]
      rules = {
        "Allow-HTTPS-Ingress" = {
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = local.app_ingress_source
          destination_address_prefix = "*"
          description                = "HTTPS from the environment ingress point: App Gateway subnet in test/prod, internet in dev where a public LB fronts the tier."
        }
        "Allow-LB-Probe"   = local.allow_lb_probe
        "Allow-SSH-Admin"  = local.allow_ssh_from_bastion
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

    ############################################################################
    # Business tier
    #
    # Deliberately NOT reachable from the ingress point. Skipping a tier is a
    # lateral movement path, and this rule set is what makes the three-tier
    # boundary real rather than diagrammatic.
    ############################################################################
    (module.naming.network_security_group_names["biz"]) = {
      subnet_id = module.networking.subnet_ids[local.biz_subnet]
      rules = {
        "Allow-App-Tier" = {
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "8443"
          source_address_prefix      = local.cidr[local.app_subnet]
          destination_address_prefix = "*"
          description                = "Application tier only. The ingress subnet is deliberately excluded so traffic cannot skip a tier."
        }
        "Allow-LB-Probe"   = local.allow_lb_probe
        "Allow-SSH-Admin"  = local.allow_ssh_from_bastion
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

    ############################################################################
    # Private endpoints
    #
    # Effective only because the subnet sets private_endpoint_network_policies
    # to NetworkSecurityGroupEnabled. Historically NSGs were ignored on private
    # endpoint subnets, and with the default these rules would be silently
    # inert — a control that appears configured and does nothing.
    ############################################################################
    (module.naming.network_security_group_names["pep"]) = {
      subnet_id = module.networking.subnet_ids[local.pep_subnet]
      rules = {
        "Allow-Data-Plane-From-Workload" = {
          priority          = 100
          direction         = "Inbound"
          access            = "Allow"
          protocol          = "Tcp"
          source_port_range = "*"
          # 1433 SQL, 10000 Managed Redis, 443 Key Vault and Storage.
          #
          # 10000, NOT 6380. Azure Cache for Redis listens on 6380 for TLS;
          # Azure MANAGED Redis — which this platform uses, because Cache for
          # Redis is retiring and its API rejects creation — listens on 10000.
          # This rule named 6380 until 2026-08-14, which meant every call from a
          # pod to Redis fell through to the deny below.
          #
          # Nothing surfaced it. The private endpoint exists, the private DNS
          # zone resolves, the NSG reads as configured, and the connection is
          # simply refused. dev has never run a workload, so nothing exercised
          # the path. Confirmed against the live database:
          #   az redisenterprise database list ... --query "[].port"  ->  10000
          destination_port_ranges = ["443", "1433", "10000"]
          # The AKS node subnet, NOT the app and biz subnets. Under Azure CNI
          # Overlay a pod's traffic leaving the cluster is SNATed to its NODE
          # address, so a rule naming the old tier subnets would match nothing
          # and every call from a pod to SQL, Redis, Key Vault or Storage would
          # hit the deny below.
          source_address_prefixes = [
            local.cidr[local.aks_subnet],
          ]
          destination_address_prefix = "*"
          description                = "SQL, Redis over TLS, Key Vault and Storage, from the AKS node subnet."
        }
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

    ############################################################################
    # Database tier — reserved
    #
    # No resource lands here today; PaaS SQL reaches the VNet through a private
    # endpoint. The NSG exists so the subnet is never briefly unprotected if
    # something is placed in it later.
    ############################################################################
    (module.naming.network_security_group_names["db"]) = {
      subnet_id = module.networking.subnet_ids[local.db_subnet]
      rules = {
        "Allow-SSH-Admin"  = local.allow_ssh_from_bastion
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

    ############################################################################
    # Management
    ############################################################################
    (module.naming.network_security_group_names["mgmt"]) = {
      subnet_id = module.networking.subnet_ids[local.mgmt_subnet]
      rules = {
        "Allow-SSH-Admin"  = local.allow_ssh_from_bastion
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

    ############################################################################
    # Kubernetes nodes
    #
    # Deliberately sparse. The tier boundary that used to live between
    # snet-app and snet-biz now lives INSIDE the cluster, enforced by the
    # Kubernetes network policy engine rather than by an NSG — pods are not
    # separated by subnet, so an NSG cannot express app-to-biz rules any more.
    #
    # What remains at this layer is the outer perimeter: ingress reaches the
    # cluster's own load balancer, and nothing else gets in. AKS manages rules
    # for its managed load balancer inside the node resource group; adding
    # overlapping rules here fights that reconciliation.
    ############################################################################
    "nsg-aks-dev-cus" = {
      subnet_id = module.networking.subnet_ids[local.aks_subnet]
      rules = {
        "Allow-LB-Probe"   = local.allow_lb_probe
        "Allow-SSH-Admin"  = local.allow_ssh_from_bastion
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

    ############################################################################
    # Azure Bastion
    #
    # This rule set is mandated by Azure, not chosen. Bastion will not deploy
    # into a subnet whose NSG lacks these, and the error names Bastion rather
    # than the missing rule.
    #
    # Written now, before Bastion exists, so module 12 deploys into a subnet
    # that is already correct.
    ############################################################################
    "nsg-bastion-dev-eus" = {
      subnet_id = module.networking.subnet_ids[local.bastion_subnet]
      rules = {
        "Allow-HTTPS-Inbound" = {
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = "Internet"
          destination_address_prefix = "*"
          description                = "Operator HTTPS to the Bastion host."
        }
        "Allow-GatewayManager-Inbound" = {
          priority                   = 110
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = "GatewayManager"
          destination_address_prefix = "*"
          description                = "Bastion control plane. Mandatory."
        }
        "Allow-LoadBalancer-Inbound" = {
          priority                   = 120
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = "AzureLoadBalancer"
          destination_address_prefix = "*"
          description                = "Bastion health probes. Mandatory."
        }
        "Allow-BastionHostComms-Inbound" = {
          priority                   = 130
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "*"
          source_port_range          = "*"
          destination_port_ranges    = ["5701", "8080"]
          source_address_prefix      = "VirtualNetwork"
          destination_address_prefix = "VirtualNetwork"
          description                = "Bastion internal data plane. Mandatory."
        }
        "Deny-All-Inbound" = local.deny_all_inbound

        "Allow-SshRdp-Outbound" = {
          priority                   = 100
          direction                  = "Outbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_ranges    = ["22", "3389"]
          source_address_prefix      = "*"
          destination_address_prefix = "VirtualNetwork"
          description                = "Bastion to target VMs. Mandatory."
        }
        "Allow-AzureCloud-Outbound" = {
          priority                   = 110
          direction                  = "Outbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = "*"
          destination_address_prefix = "AzureCloud"
          description                = "Bastion dependencies. Mandatory."
        }
        "Allow-BastionHostComms-Outbound" = {
          priority                   = 120
          direction                  = "Outbound"
          access                     = "Allow"
          protocol                   = "*"
          source_port_range          = "*"
          destination_port_ranges    = ["5701", "8080"]
          source_address_prefix      = "VirtualNetwork"
          destination_address_prefix = "VirtualNetwork"
          description                = "Bastion internal data plane. Mandatory."
        }
        "Allow-CertificateValidation-Outbound" = {
          priority                   = 130
          direction                  = "Outbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "80"
          source_address_prefix      = "*"
          destination_address_prefix = "Internet"
          description                = "Certificate revocation checks. Mandatory."
        }
      }
    }
  }
}
