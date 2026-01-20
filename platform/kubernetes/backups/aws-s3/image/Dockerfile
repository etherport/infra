FROM public.ecr.aws/aws-cli/aws-cli:2.33.0

# Bake deps into the image so the job doesn't yum install at runtime.
# (aws-cli image is Amazon Linux; yum should work.)
RUN yum -y -q install jq python3 parallel && yum clean all && rm -rf /var/cache/yum

# Install kubectl (pinned version for reproducible builds)
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.35.0
RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Your scripts live here
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Jobs will write temp logs here
WORKDIR /work