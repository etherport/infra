FROM public.ecr.aws/aws-cli/aws-cli:2.32.16

# Bake deps into the image so the job doesn't yum install at runtime.
# (aws-cli image is Amazon Linux; yum should work.)
RUN yum -y -q install jq python3 kubectl && yum clean all && rm -rf /var/cache/yum

# Your scripts live here
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Jobs will write temp logs here
WORKDIR /work