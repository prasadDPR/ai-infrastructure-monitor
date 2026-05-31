import json
import boto3
import logging
import os
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

bedrock = boto3.client('bedrock-runtime', region_name='eu-west-2')
sns = boto3.client('sns', region_name='eu-west-2')

SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    
    try:
        # Parse the alert from Alertmanager
        body = json.loads(event.get('body', '{}'))
        alerts = body.get('alerts', [])
        
        if not alerts:
            return {'statusCode': 200, 'body': 'No alerts to process'}
        
        for alert in alerts:
            process_alert(alert)
            
        return {'statusCode': 200, 'body': 'Alerts processed successfully'}
        
    except Exception as e:
        logger.error(f"Error processing alert: {str(e)}")
        return {'statusCode': 500, 'body': str(e)}


def process_alert(alert):
    # Extract alert details
    alert_name = alert.get('labels', {}).get('alertname', 'Unknown')
    severity = alert.get('labels', {}).get('severity', 'unknown')
    namespace = alert.get('labels', {}).get('namespace', 'unknown')
    pod = alert.get('labels', {}).get('pod', 'unknown')
    description = alert.get('annotations', {}).get('description', 'No description')
    summary = alert.get('annotations', {}).get('summary', 'No summary')
    status = alert.get('status', 'unknown')
    
    logger.info(f"Processing alert: {alert_name} - {severity}")
    
    # Only process firing alerts
    if status != 'firing':
        logger.info(f"Skipping non-firing alert: {status}")
        return
    
    # Get AI analysis from Bedrock
    analysis = analyse_with_bedrock(
        alert_name=alert_name,
        severity=severity,
        namespace=namespace,
        pod=pod,
        description=description,
        summary=summary
    )
    
    # Send to SNS
    publish_recommendation(
        alert_name=alert_name,
        severity=severity,
        namespace=namespace,
        pod=pod,
        summary=summary,
        analysis=analysis
    )


def analyse_with_bedrock(alert_name, severity, namespace, pod, description, summary):
    prompt = f"""You are an expert NHS healthcare infrastructure SRE (Site Reliability Engineer).

A Kubernetes monitoring alert has fired. Analyse it and provide:
1. Root cause — what most likely caused this alert
2. Immediate fix — exact steps to resolve it right now
3. Prevention — how to stop this happening again

Alert Details:
- Alert Name: {alert_name}
- Severity: {severity}
- Namespace: {namespace}
- Pod: {pod}
- Summary: {summary}
- Description: {description}
- Time: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

Provide a clear, actionable response that an on-call engineer can follow immediately.
Keep your response concise — maximum 300 words."""

    try:
        response = bedrock.invoke_model(
            modelId='anthropic.claude-3-sonnet-20240229-v1:0',
            body=json.dumps({
                'anthropic_version': 'bedrock-2023-05-31',
                'max_tokens': 500,
                'messages': [
                    {
                        'role': 'user',
                        'content': prompt
                    }
                ]
            })
        )
        
        response_body = json.loads(response['body'].read())
        analysis = response_body['content'][0]['text']
        logger.info(f"Bedrock analysis complete: {len(analysis)} chars")
        return analysis
        
    except Exception as e:
        logger.error(f"Bedrock error: {str(e)}")
        return f"AI analysis unavailable: {str(e)}"


def publish_recommendation(alert_name, severity, namespace, pod, summary, analysis):
    message = f"""
HEALTHCARE INFRASTRUCTURE ALERT
================================
Alert:     {alert_name}
Severity:  {severity.upper()}
Namespace: {namespace}
Pod:       {pod}
Summary:   {summary}
Time:      {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

AI ANALYSIS (powered by AWS Bedrock)
=====================================
{analysis}

================================
Healthcare Infrastructure Monitor
AWS EKS Cluster - eu-west-2
"""
    
    subject = f"[{severity.upper()}] {alert_name} - {pod}"
    
    try:
        if SNS_TOPIC_ARN:
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Message=message,
                Subject=subject[:100]
            )
            logger.info(f"SNS notification sent for {alert_name}")
        else:
            logger.warning("SNS_TOPIC_ARN not set — skipping notification")
            logger.info(f"Alert analysis:\n{message}")
    except Exception as e:
        logger.error(f"SNS error: {str(e)}")