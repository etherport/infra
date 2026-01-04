#!/usr/bin/env python3
"""
Auto-Remediation Controller
Receives Prometheus alerts via webhook and takes corrective actions
"""
import os
import json
import logging
import yaml
from http.server import HTTPServer, BaseHTTPRequestHandler
from kubernetes import client, config
from datetime import datetime, timedelta

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Load Kubernetes config
try:
    config.load_incluster_config()
except:
    config.load_kube_config()

v1 = client.CoreV1Api()
apps_v1 = client.AppsV1Api()

# Load remediation rules
with open('/etc/remediation/rules.yaml', 'r') as f:
    RULES = yaml.safe_load(f)['rules']

# Track recent actions to prevent loops
recent_actions = {}
COOLDOWN_MINUTES = 15

def is_cooldown_active(alert_name):
    """Check if we're in cooldown period for this alert"""
    if alert_name in recent_actions:
        last_action = recent_actions[alert_name]
        if datetime.now() - last_action < timedelta(minutes=COOLDOWN_MINUTES):
            logger.info(f"Cooldown active for {alert_name}, skipping action")
            return True
    return False

def restart_pods(namespace, selector):
    """Restart pods matching selector in namespace"""
    logger.info(f"Restarting pods in {namespace} with selector {selector}")
    try:
        pods = v1.list_namespaced_pod(namespace, label_selector=selector)
        deleted_count = 0
        for pod in pods.items:
            logger.info(f"Deleting pod {pod.metadata.name}")
            v1.delete_namespaced_pod(pod.metadata.name, namespace)
            deleted_count += 1
        logger.info(f"Deleted {deleted_count} pods")
        return True
    except Exception as e:
        logger.error(f"Error restarting pods: {e}")
        return False

def scale_deployment(namespace, name, replicas=0):
    """Scale deployment to 0 then back to original"""
    logger.info(f"Scaling deployment {namespace}/{name}")
    try:
        deployment = apps_v1.read_namespaced_deployment(name, namespace)
        original_replicas = deployment.spec.replicas

        # Scale to 0
        deployment.spec.replicas = replicas
        apps_v1.patch_namespaced_deployment_scale(name, namespace, deployment)
        logger.info(f"Scaled {name} to {replicas}")

        # Scale back (would need to wait in production)
        if replicas == 0:
            import time
            time.sleep(10)
            deployment.spec.replicas = original_replicas
            apps_v1.patch_namespaced_deployment_scale(name, namespace, deployment)
            logger.info(f"Scaled {name} back to {original_replicas}")
        return True
    except Exception as e:
        logger.error(f"Error scaling deployment: {e}")
        return False

class AlertWebhook(BaseHTTPRequestHandler):
    def do_POST(self):
        """Handle incoming Prometheus alerts"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)

        try:
            alert_data = json.loads(post_data)
            logger.info(f"Received alert: {json.dumps(alert_data, indent=2)}")

            # Process each alert
            for alert in alert_data.get('alerts', []):
                alert_name = alert.get('labels', {}).get('alertname')
                status = alert.get('status')

                if status == 'firing' and alert_name in RULES:
                    if is_cooldown_active(alert_name):
                        continue

                    rule = RULES[alert_name]
                    action = rule.get('action')
                    namespace = rule.get('namespace') or alert.get('labels', {}).get('namespace')
                    selector = rule.get('selector')

                    logger.info(f"Taking action for {alert_name}: {rule.get('description')}")

                    success = False
                    if action == 'restart_pods' and namespace and selector:
                        success = restart_pods(namespace, selector)
                    elif action == 'scale_deployment':
                        deployment_name = alert.get('labels', {}).get('deployment')
                        if deployment_name and namespace:
                            success = scale_deployment(namespace, deployment_name)

                    if success:
                        recent_actions[alert_name] = datetime.now()

            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode())

        except Exception as e:
            logger.error(f"Error processing alert: {e}")
            self.send_response(500)
            self.end_headers()

    def log_message(self, format, *args):
        """Suppress default logging"""
        pass

if __name__ == '__main__':
    PORT = 8080
    server = HTTPServer(('', PORT), AlertWebhook)
    logger.info(f"Auto-remediation webhook server listening on port {PORT}")
    server.serve_forever()
