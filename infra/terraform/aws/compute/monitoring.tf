# NB (M110, 2026-07-02): the dns_* alarms were removed with the standalone dns
# instance; the vpn_* alarms cover the consolidated edge box.
# CloudWatch Alarms and SNS for EC2 Monitoring

#------------------------------------------------------------------------------
# SNS Topic for EC2 Alerts
#------------------------------------------------------------------------------

resource "aws_sns_topic" "ec2_alerts" {
  name         = "CloudWatch_Alarms_EC2_Low_memory"
  display_name = "EC2 Memory Alerts"

  tags = {
    Name        = "CloudWatch_Alarms_EC2_Low_memory"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

resource "aws_sns_topic_subscription" "ec2_alerts_email" {
  topic_arn = aws_sns_topic.ec2_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

#------------------------------------------------------------------------------
# CloudWatch Alarms - VPN Instance
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "vpn_high_memory" {
  alarm_name          = "High-Memory-Utilization-VPN"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId   = aws_instance.vpn.id
    ImageId      = aws_instance.vpn.ami
    InstanceType = aws_instance.vpn.instance_type
  }

  alarm_actions = [
    aws_sns_topic.ec2_alerts.arn,
    "arn:aws:swf:us-west-2:830881980142:action/actions/AWS_EC2.InstanceId.Reboot/1.0"
  ]

  tags = {
    Name        = "High-Memory-Utilization-VPN"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

resource "aws_cloudwatch_metric_alarm" "vpn_high_swap" {
  alarm_name          = "High-Swap-Utilization-VPN"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "swap_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 50
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId   = aws_instance.vpn.id
    ImageId      = aws_instance.vpn.ami
    InstanceType = aws_instance.vpn.instance_type
  }

  # Notify only — NO auto-reboot. Baseline swap on this 0.5GB t4g.nano sits
  # ~15-20% (Linux parks cold pages while mem stays <50%), so the old 20% +
  # reboot action flap-rebooted the VPN for a non-problem. Genuine memory
  # pressure is covered by High-Memory-Utilization-VPN (>80%, which keeps its
  # reboot). Raised 20->50; if it still flaps, drop the swap alarm entirely.
  alarm_actions = [
    aws_sns_topic.ec2_alerts.arn
  ]

  tags = {
    Name        = "High-Swap-Utilization-VPN"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

#------------------------------------------------------------------------------
# CloudWatch Alarms - DNS Instance
#------------------------------------------------------------------------------



#------------------------------------------------------------------------------
# Hard-failure auto-recovery
#
# Layered with the memory/swap alarms above:
#   * mem/swap alarms (above)  -> ec2:reboot   - soft fault, agent published
#   * status check alarms      -> ec2:recover  - hypervisor / OS unreachable
#
# Both actions keep the instance on the same hardware — no autoscaling,
# no instance-type change, no cost impact. The recover action is
# automatically supported on any EBS-backed instance.
#
# Uses AWS-provided metrics (StatusCheckFailed_System and _Instance)
# which incur no MetricMonitorUsage charge. Both alarms are within the
# 10 free standard-resolution alarms per region.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "vpn_status_check_recover" {
  alarm_name          = "EC2-StatusCheck-Recover-VPN"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "StatusCheckFailed_System"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "missing"
  alarm_description   = "Auto-recover VPN instance on hypervisor or system-status failure."

  dimensions = {
    InstanceId = aws_instance.vpn.id
  }

  # `ec2:recover` recreates the instance on equivalent hardware; same
  # AMI, same volumes, same private/public IPs, same instance type.
  alarm_actions = [
    "arn:aws:automate:us-west-2:ec2:recover",
    aws_sns_topic.ec2_alerts.arn,
  ]

  tags = {
    Name        = "EC2-StatusCheck-Recover-VPN"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

