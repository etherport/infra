FROM public.ecr.aws/aws-cli/aws-cli:2.32.16

# Install additional utilities
RUN yum install -y \
    curl \
    jq \
    && yum clean all

# Copy update script
COPY scripts/update-route53.sh /scripts/update-route53.sh
RUN chmod +x /scripts/update-route53.sh

# Default command
CMD ["/scripts/update-route53.sh"]
