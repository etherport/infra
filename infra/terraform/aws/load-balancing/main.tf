# Application Load Balancer and related resources

#------------------------------------------------------------------------------
# Data Sources - References to networking module resources
#------------------------------------------------------------------------------

data "aws_vpc" "private_infra" {
  filter {
    name   = "tag:Name"
    values = ["private-infra-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.private_infra.id]
  }
  filter {
    name   = "tag:Name"
    values = ["private-infra-subnet-public*"]
  }
}

data "aws_security_group" "alb_public" {
  name   = "private-infra_alb-public-443"
  vpc_id = data.aws_vpc.private_infra.id
}

#------------------------------------------------------------------------------
# S3 Bucket for ALB Access Logs (reference only - managed elsewhere)
#------------------------------------------------------------------------------

data "aws_s3_bucket" "logs" {
  bucket = "logs.grahamsmith.net"
}

#------------------------------------------------------------------------------
# Application Load Balancer
#------------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "private-infra-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_security_group.alb_public.id]
  subnets            = data.aws_subnets.public.ids

  enable_deletion_protection = false
  enable_http2               = true
  preserve_host_header       = true
  xff_header_processing_mode = "preserve"

  access_logs {
    bucket  = data.aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name = "private-infra-alb"
  }

  lifecycle {
    prevent_destroy = true
  }
}

#------------------------------------------------------------------------------
# Target Group - Traefik Ingress
#------------------------------------------------------------------------------

resource "aws_lb_target_group" "traefik" {
  name        = "traefik-wind-etherport-net"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = data.aws_vpc.private_infra.id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    port                = "traffic-port"
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200,404"
  }

  tags = {
    Name = "traefik-wind-etherport-net"
  }
}

# Static target registration for Traefik ingress IP
# availability_zone = "all" is required for IPs outside the VPC
resource "aws_lb_target_group_attachment" "traefik" {
  target_group_arn  = aws_lb_target_group.traefik.arn
  target_id         = var.traefik_ip
  port              = 443
  availability_zone = "all"
}

#------------------------------------------------------------------------------
# HTTPS Listener
#------------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
  certificate_arn   = data.aws_acm_certificate.grahamsmith_wildcard.arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "503"
    }
  }

  tags = {
    Name = "private-infra-alb-https"
  }
}

#------------------------------------------------------------------------------
# Listener Certificates (SNI)
#------------------------------------------------------------------------------

resource "aws_lb_listener_certificate" "etherport_wildcard" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = data.aws_acm_certificate.etherport_wildcard.arn
}

resource "aws_lb_listener_certificate" "wind_etherport_wildcard" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = data.aws_acm_certificate.wind_etherport_wildcard.arn
}

resource "aws_lb_listener_certificate" "ha_wind_etherport" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = data.aws_acm_certificate.ha_wind_etherport.arn
}

#------------------------------------------------------------------------------
# Listener Rules
#------------------------------------------------------------------------------

resource "aws_lb_listener_rule" "wind_etherport_services" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }

  condition {
    host_header {
      values = var.wind_etherport_hostnames
    }
  }

  tags = {
    Name = "wind-etherport-services"
  }
}
