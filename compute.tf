# compute.tf — launch template, ASG, mixed instances policy.

locals {
  # Public SSM parameters AWS publishes for the latest AL2023 AMI per
  # architecture — no custom AMI/Packer build.
  al2023_ami_ssm_parameter_names = {
    x86_64 = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    arm64  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  name = local.al2023_ami_ssm_parameter_names[var.architecture]
}

locals {
  # Default candidate types per architecture. The ASG's Mixed Instances
  # Policy override list consumes the full set; the Launch Template
  # itself only needs one as its base/fallback value.
  instance_types_by_architecture = {
    x86_64 = ["t3a.nano", "t3.nano"]
    arm64  = ["t4g.nano"]
  }

  resolved_instance_types = (
    var.instance_types != null
    ? var.instance_types
    : local.instance_types_by_architecture[var.architecture]
  )
}

resource "aws_launch_template" "nat" {
  name_prefix = "${var.name_prefix}-nat-instance-"

  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = local.resolved_instance_types[0]

  iam_instance_profile {
    name = aws_iam_instance_profile.nat_instance.name
  }

  # IMDSv2 required — the bootstrap script's imds() helper depends on
  # it, and it blocks SSRF-style credential theft regardless. Default
  # hop limit of 1 is correct: the script runs on the host, not in a
  # container needing the extra hop.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  network_interfaces {
    device_index    = 0
    security_groups = [aws_security_group.nat.id]

    # Needed from first boot — dnf install and the self-association API
    # calls (bootstrap.sh.tpl) have nothing else to rely on until the
    # EIP attaches. Explicit here because a network_interfaces block
    # overrides the subnet's own MapPublicIpOnLaunch default.
    associate_public_ip_address = true

    # source_dest_check deliberately not set here: aws_launch_template
    # has no such argument in this provider's schema. Disabled at boot
    # instead (bootstrap.sh.tpl, ec2:ModifyInstanceAttribute), same
    # pattern as EIP association and route repointing.
  }

  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    eip_allocation_id = local.eip_allocation_id
    route_table_ids   = join(",", var.private_route_table_ids)
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name_prefix}-nat" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nat" {
  name_prefix         = "${var.name_prefix}-nat-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.public_subnet_id]
  health_check_type   = "EC2"

  # GroupInServiceInstances is opt-in; required by the Spot-exhaustion
  # fallback alarm (spot_fallback.tf). Without this, the metric never
  # publishes and treat_missing_data would false-alarm every deployment.
  enabled_metrics = local.spot_fallback_enabled ? ["GroupInServiceInstances"] : []

  # Proactively replace Spot instances at elevated interruption risk
  # (complements the EventBridge failover Lambda in failover.tf).
  capacity_rebalance = var.use_spot

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.nat.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = local.resolved_instance_types
        content {
          instance_type = override.value
        }
      }
    }

    # use_spot flips 100% Spot vs 100% On-Demand. Spot-exhaustion
    # fallback (spot_fallback.tf) can flip to On-Demand at runtime when
    # zero instances stay InService.
    instances_distribution {
      spot_allocation_strategy                 = "price-capacity-optimized"
      on_demand_base_capacity                  = var.use_spot ? 0 : 1
      on_demand_percentage_above_base_capacity = var.use_spot ? 0 : 100
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = "${var.name_prefix}-nat" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
