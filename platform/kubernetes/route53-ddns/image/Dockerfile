FROM public.ecr.aws/aws-cli/aws-cli:2.34.44

# Install additional utilities
# Note: curl is already installed (curl-minimal) in the base image
RUN yum install -y \
    jq \
    bind-utils \
    && yum clean all

# Copy update script
COPY scripts/update-route53.sh /scripts/update-route53.sh
RUN chmod +x /scripts/update-route53.sh

# Default command
CMD ["/scripts/update-route53.sh"]
