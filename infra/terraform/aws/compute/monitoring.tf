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
  threshold           = 20
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
    Name        = "High-Swap-Utilization-VPN"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

#------------------------------------------------------------------------------
# CloudWatch Alarms - DNS Instance
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dns_high_memory" {
  alarm_name          = "High-Memory-Utilization-DNS"
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
    InstanceId   = aws_instance.dns.id
    ImageId      = aws_instance.dns.ami
    InstanceType = aws_instance.dns.instance_type
  }

  alarm_actions = [
    aws_sns_topic.ec2_alerts.arn,
    "arn:aws:swf:us-west-2:830881980142:action/actions/AWS_EC2.InstanceId.Reboot/1.0"
  ]

  tags = {
    Name        = "High-Memory-Utilization-DNS"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

resource "aws_cloudwatch_metric_alarm" "dns_high_swap" {
  alarm_name          = "High-Swap-Utilization-DNS"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "swap_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 30
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId   = aws_instance.dns.id
    ImageId      = aws_instance.dns.ami
    InstanceType = aws_instance.dns.instance_type
  }

  alarm_actions = [
    aws_sns_topic.ec2_alerts.arn,
    "arn:aws:swf:us-west-2:830881980142:action/actions/AWS_EC2.InstanceId.Reboot/1.0"
  ]

  tags = {
    Name        = "High-Swap-Utilization-DNS"
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}
