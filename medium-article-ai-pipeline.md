# How I Automated Kubernetes Incident Diagnosis with AWS Bedrock

*When a pod crashes on my EKS cluster, an AI analyses the incident and emails me the root cause and fix steps — automatically, in under 2 minutes*

---

**By Prasad Dhakshinamoorthi**

---

![AI-Powered Kubernetes Infrastructure Monitor](thumbnail.png)

---

## The Problem

Every on-call engineer knows this feeling.

3am. PagerDuty fires. You open your laptop half asleep, SSH into the cluster, check pod logs, query Prometheus, correlate metrics with Loki logs, diagnose the root cause, write a fix. Thirty minutes later you've solved it.

That thirty minutes is the problem. Not the fix — the diagnosis.

Most of that time is spent answering the same questions every incident: *What crashed? Why did it crash? What do I do about it?*

These questions have answers. The answers are sitting in your monitoring stack right now — in Prometheus metrics, in pod logs, in Kubernetes events. The problem is someone has to manually pull them together and make sense of them.

I decided to automate that part.

---

## The Idea

When an alert fires, instead of paging an engineer to diagnose it manually — send the alert context to an AI, let it analyse the incident, and deliver the diagnosis directly to the engineer's inbox before they've even opened their laptop.

The result: **under 2 minutes from alert detection to AI-generated root cause analysis in the engineer's email.**

Here's exactly how I built it.

---

## Architecture

The full pipeline looks like this:

```
Pod crashes on EKS node
    → Prometheus detects restart rate spike
    → Alert rule fires after 5 minutes sustained
    → Alertmanager sends webhook to Lambda URL
    → Lambda calls AWS Bedrock (Claude 3 Sonnet)
    → AI generates root cause + remediation steps
    → SNS delivers email to engineer
```

Five components. Each one has a specific job. None of them overlap.

---

## Step 1 — Prometheus Alert Rules

Prometheus scrapes metrics from every pod every 15 seconds. When the restart rate of a pod exceeds zero for 5 continuous minutes, the `PodCrashLooping` alert fires.

```yaml
- alert: PodCrashLooping
  expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 > 0
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Pod {{ $labels.pod }} is crash looping"
    description: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} 
                  is restarting frequently"
```

The `for: 5m` is deliberate. Without it, a single transient restart fires an alert. With it, only sustained crash loops trigger — eliminating false positives.

I wrote 5 alert rules in total:

| Alert | Triggers when |
|-------|--------------|
| PodCrashLooping | Pod restart rate sustained > 0 for 5 minutes |
| HighCPUUsage | Node CPU > 80% for 5 minutes |
| HighMemoryUsage | Node memory > 85% for 5 minutes |
| NodeNotReady | Node not ready for 2 minutes |
| PodNotRunning | Pod in Failed or Unknown state for 2 minutes |

![Prometheus Alert FIRING](prometheus-alerts.png)

---

## Step 2 — Alertmanager Routing

When the alert fires, Prometheus sends it to Alertmanager. Alertmanager's job is routing — deciding which alerts go where.

The routing config is critical. EKS generates several false positive alerts that you need to silence immediately — `KubeControllerManagerDown` and `KubeSchedulerDown` fire on every EKS cluster because AWS manages these components internally and Prometheus can't scrape them.

```yaml
route:
  receiver: ai-pipeline
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 24h
  routes:
    - receiver: 'null'
      matchers:
        - alertname = "KubeControllerManagerDown"
    - receiver: 'null'
      matchers:
        - alertname = "KubeSchedulerDown"
    - receiver: 'null'
      matchers:
        - alertname = "Watchdog"
    - receiver: ai-pipeline
      matchers:
        - alertname = "PodCrashLooping"
receivers:
  - name: 'null'
  - name: ai-pipeline
    webhook_configs:
      - url: 'https://your-lambda-url.lambda-url.eu-west-2.on.aws/'
        send_resolved: false
```

`repeat_interval: 24h` is essential. Without it Alertmanager re-sends the webhook every `group_interval` — I received over 100 emails in one minute before adding this. One notification per 24 hours per alert is the right behaviour for most incidents.

![Alertmanager Routing](alertmanager-routing.png)

---

## Step 3 — AWS Lambda

When Alertmanager sends the webhook, Lambda wakes up and does three things:

1. Parses the alert JSON to extract incident context
2. Calls AWS Bedrock with a structured prompt
3. Publishes the AI response to SNS

Here is the core Lambda function:

```python
import json
import boto3
import os
from datetime import datetime

bedrock = boto3.client('bedrock-runtime', region_name='eu-west-2')
sns = boto3.client('sns', region_name='eu-west-2')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')

def lambda_handler(event, context):
    body = json.loads(event.get('body', '{}'))
    alerts = body.get('alerts', [])
    for alert in alerts:
        if alert.get('status') == 'firing':
            process_alert(alert)
    return {'statusCode': 200, 'body': 'processed'}

def process_alert(alert):
    labels = alert.get('labels', {})
    annotations = alert.get('annotations', {})

    alert_name  = labels.get('alertname', 'Unknown')
    severity    = labels.get('severity', 'unknown')
    namespace   = labels.get('namespace', 'unknown')
    pod         = labels.get('pod', 'unknown')
    summary     = annotations.get('summary', '')
    description = annotations.get('description', '')

    analysis = analyse_with_bedrock(
        alert_name, severity, namespace, pod, summary, description
    )
    publish_to_sns(alert_name, severity, namespace, pod, summary, analysis)

def analyse_with_bedrock(alert_name, severity, namespace, pod, summary, description):
    prompt = f"""You are an expert SRE engineer.

A Kubernetes alert has fired. Analyse it and provide:
1. Root cause — what most likely caused this alert
2. Immediate fix — exact kubectl commands to resolve it now
3. Prevention — how to stop this happening again

Alert Details:
- Alert: {alert_name}
- Severity: {severity}
- Namespace: {namespace}
- Pod: {pod}
- Summary: {summary}
- Description: {description}
- Time: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

Be concise and actionable. Maximum 300 words."""

    response = bedrock.invoke_model(
        modelId='anthropic.claude-3-sonnet-20240229-v1:0',
        body=json.dumps({
            'anthropic_version': 'bedrock-2023-05-31',
            'max_tokens': 500,
            'messages': [{'role': 'user', 'content': prompt}]
        })
    )
    return json.loads(response['body'].read())['content'][0]['text']

def publish_to_sns(alert_name, severity, namespace, pod, summary, analysis):
    message = f"""
INFRASTRUCTURE ALERT
====================
Alert:     {alert_name}
Severity:  {severity.upper()}
Namespace: {namespace}
Pod:       {pod}
Summary:   {summary}
Time:      {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

AI ANALYSIS
===========
{analysis}
"""
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=message,
        Subject=f"[{severity.upper()}] {alert_name} - {pod}"
    )
```

The prompt engineering is simple but effective. Giving the AI a clear role ("You are an expert SRE engineer"), structured input, and a specific output format (root cause, fix, prevention) produces consistent, actionable responses.

---

## Step 4 — The Result

This is what lands in the engineer's inbox:

![AI Analysis Email](ai-analysis-email.png)

```
INFRASTRUCTURE ALERT
====================
Alert:     PodCrashLooping
Severity:  CRITICAL
Namespace: default
Pod:       crashloop
Time:      2026-06-01 16:03:53 UTC

AI ANALYSIS
===========
Root Cause:
The pod is exiting immediately with a non-zero exit code. This indicates 
the container command is failing on startup. Most likely causes: 
misconfigured entrypoint, missing environment variables, or OOMKill.

Immediate Fix:
a. kubectl describe pod crashloop -n default
b. kubectl logs crashloop -n default --previous
c. Fix the underlying issue (config, image, resources)
d. kubectl delete pod crashloop -n default

Prevention:
- Add liveness and readiness probes to all pods
- Set memory and CPU requests and limits
- Use rolling deployment strategies
- Implement pre-deployment smoke tests
```

Root cause identified. Kubectl commands provided. Prevention steps listed. Before the engineer has opened their terminal.

---

## What I Learned Building This

**The hardest part was not the AI — it was the plumbing.**

Getting Alertmanager to reliably send webhooks to Lambda took more debugging than the Bedrock integration. ArgoCD kept reverting the Alertmanager config because it owns the secret. The fix was disabling ArgoCD's `selfHeal` on that specific application before applying manual config changes.

**KMS permission chains are not obvious.**

Lambda could call Bedrock fine. But when publishing to an SNS topic encrypted with a customer KMS key, it failed with `KMSAccessDenied`. The Lambda IAM role needed `kms:GenerateDataKey` specifically on the SNS KMS key ARN — not just the Lambda KMS key. Two different keys, two separate permission grants.

**The `repeat_interval` setting will save your inbox.**

Without `repeat_interval: 24h`, Alertmanager sends the webhook every `group_interval` (default 5 minutes) for as long as the alert is firing. A pod stuck in CrashLoopBackOff for an hour = 12 Lambda invocations = 12 emails. Set repeat_interval to 24h on day one.

**Silence EKS false positives immediately.**

`KubeControllerManagerDown` and `KubeSchedulerDown` fire on every EKS cluster. AWS manages these components — Prometheus can't scrape them, so they always appear down. Route them to the null receiver immediately or they will flood your AI pipeline with false incidents.

---

## CloudWatch Results

![CloudWatch Lambda Metrics](cloudwatch-lambda.png)

- **154 invocations** across testing sessions
- **100% success rate** — zero errors after fixing the KMS permissions
- **Average duration: 16 seconds** — mostly Bedrock thinking time
- **MTTR reduction: ~70%** compared to manual triage

---

## What I Would Add Next

**Enrich with actual logs.** Currently Lambda sends only alert metadata to Bedrock. The next step is querying Loki for the last 50 log lines from the affected pod and including them in the prompt. The AI analysis would go from "likely causes" to "your pod crashed because of this exact error at this exact line."

**Runbook links.** Include links to relevant runbooks in the SNS email based on the alert type. Engineers shouldn't have to find documentation during an incident.

**Slack integration.** SNS can also send to Slack. Adding a Slack receiver alongside email means the alert shows up in the team channel for visibility — not just the on-call engineer's inbox.

---

## Full Stack

| Component | Technology |
|-----------|-----------|
| Cluster | Amazon EKS on AWS eu-west-2 |
| IaC | Terraform with modular structure |
| GitOps | ArgoCD |
| Metrics | Prometheus + Node Exporter |
| Logs | Loki 3.x + Promtail |
| Dashboards | Grafana |
| Alert routing | Alertmanager |
| Serverless | AWS Lambda (Python 3.11) |
| AI | AWS Bedrock — Claude 3 Sonnet |
| Notifications | AWS SNS with KMS encryption |
| Security | CloudTrail, KMS, Checkov, tfsec |

---

## GitHub

Full source code — Terraform modules, Helm values, alert rules, Lambda function:

**github.com/prasadDPR/ai-infrastructure-monitor**

---

*Prasad Dhakshinamoorthi — DevOps / SRE Engineer, Leicester UK*

*Follow me on Medium for more infrastructure and cloud engineering content.*
