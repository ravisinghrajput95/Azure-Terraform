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
  aks_subnet     = local.aks_subnet_name
  agw_subnet     = local.agw_subnet_name
  bastion_subnet = "AzureBastionSubnet"

  # prod fronts the application tier with an Application Gateway, so the
  # gateway subnet is the ONLY permitted ingress source — not "Internet", which
  # is what dev must use because a public load balancer DNATs without replacing
  # the source address. This is the tighter of the two postures and the reason
  # prod can validate an ingress path dev cannot.
  app_ingress_source = module.profile.enable_application_gateway ? local.cidr[local.agw_subnet] : "Internet"

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
    description                = "Operator SSH, via Azure Bastion only."
  }

  # Azure's load balancer health probes originate from a platform address, not
  # from the VNet. Without this the probes fail and the backend is marked down
  # while the instances themselves are healthy.
  allow_lb_probe = {
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    description                = "Azure load balancer health probes. Marking the backend down is the failure mode when this is missing."
  }

  nsg_definitions = {
    ############################################################################
    # Application Gateway
    #
    # This rule set is mandated by Azure, not chosen, and it is the one most
    # often got wrong.
    #
    # GatewayManager on 65200-65535 is the v2 control plane. Without it the
    # gateway provisions and then reports an unhealthy status that names the
    # backend, sending everyone to look at the wrong tier. The port range looks
    # alarming and cannot be narrowed.
    #
    # The fallthrough deny applies here as it does everywhere else. It is safe
    # BECAUSE the three mandatory allows sit above it — an Application Gateway
    # tolerates an inbound deny-all and does not tolerate losing GatewayManager
    # or its outbound path. Reordering those allows below 4096 would break the
    # gateway, which is why they carry explicit low priorities rather than
    # relying on declaration order.
    ############################################################################
    (local.agw_nsg_name) = {
      subnet_id = module.networking.subnet_ids[local.agw_subnet]
      rules = {
        "Allow-Internet-HTTP" = {
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_ranges    = ["80", "443"]
          source_address_prefix      = "Internet"
          destination_address_prefix = "*"
          description                = "Public ingress to the gateway's frontend."
        }
        "Allow-GatewayManager" = {
          priority                   = 110
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "65200-65535"
          source_address_prefix      = "GatewayManager"
          destination_address_prefix = "*"
          description                = "Application Gateway v2 control plane. MANDATORY — without it the gateway reports unhealthy and the error names the backend."
        }
        "Allow-LB-Probe"   = local.allow_lb_probe
        "Deny-All-Inbound" = local.deny_all_inbound
      }
    }

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
          description                = "HTTPS from the Application Gateway subnet, which is the only ingress path in this environment."
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
          description                = "Application tier only. The gateway subnet is deliberately excluded so traffic cannot skip a tier."
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
          description                = "SQL, Managed Redis and Key Vault/Storage over TLS, from the AKS node subnet."
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
    # What remains at this layer is the outer perimeter. AKS manages rules for
    # its managed load balancer inside the node resource group; adding
    # overlapping rules here fights that reconciliation.
    ############################################################################
    (local.aks_nsg_name) = {
      subnet_id = module.networking.subnet_ids[local.aks_subnet]
      rules = {
        "Allow-Gateway-Ingress" = {
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_ranges    = ["80", "443"]
          source_address_prefix      = local.cidr[local.agw_subnet]
          destination_address_prefix = "*"
          description                = "Application Gateway to the cluster's internal ingress load balancer."
        }
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
    # prod runs Bastion Standard, which occupies this subnet. dev's Developer
    # SKU attaches by VNet ID and leaves its equivalent subnet empty.
    ############################################################################
    (local.bastion_nsg_name) = {
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
