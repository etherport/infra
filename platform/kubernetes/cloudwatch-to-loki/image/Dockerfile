# cloudwatch-to-loki image — bakes the Python deps so the CronJob no longer
# `pip install`s on every 5-min run. The runtime install + backoffLimit:0 turned
# a transient PyPI/network hiccup into an overnight job failure + alert
# (2026-06-20). Baking removes that failure class (and the ~10s/run + pip noise).
#
# The forwarder SCRIPT stays in the ConfigMap (mounted at /scripts) so script
# edits don't need an image rebuild — only the dependencies are baked here.
FROM python:3.14-slim

# kubernetes==30.* pinned: v31+ broke in-cluster auth on python 3.14 (the bearer
# token wasn't attached to ApiClient requests -> system:anonymous -> 403). 30.x
# is the last known-good major. See 04-cronjob.yaml / forward.py for the detail.
RUN pip install --no-cache-dir --retries 5 --timeout 30 \
      boto3 \
      'kubernetes>=30,<31'

# Script is mounted from the cloudwatch-to-loki-script ConfigMap at runtime.
CMD ["python", "/scripts/forward.py"]
