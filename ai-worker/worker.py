#!/usr/bin/env python3
"""
AI Prompt Generation Worker

Polls DynamoDB for prompts with status='pending' and generates responses
using the Ollama API, then updates DynamoDB with the result.
"""

import os
import time
import json
import logging
import requests
import boto3
from botocore.config import Config
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration from environment variables
DYNAMODB_ENDPOINT = os.getenv('DYNAMODB_ENDPOINT', 'http://localhost:8001')
DYNAMODB_REGION = os.getenv('DYNAMODB_REGION', 'us-west-2')
OLLAMA_ENDPOINT = os.getenv('OLLAMA_ENDPOINT', 'http://localhost:11434')
AI_PROMPTS_TABLE = os.getenv('AI_PROMPTS_TABLE', 'AIPrompts')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '10'))  # seconds
REQUEST_TIMEOUT = int(os.getenv('REQUEST_TIMEOUT', '600'))  # 10 minutes for slow models


def get_dynamodb_client():
    """Create DynamoDB client configured for local endpoint."""
    config = Config(
        region_name=DYNAMODB_REGION,
        signature_version='v4',
        retries={'max_attempts': 3}
    )

    return boto3.client(
        'dynamodb',
        endpoint_url=DYNAMODB_ENDPOINT,
        region_name=DYNAMODB_REGION,
        aws_access_key_id='fakekey',
        aws_secret_access_key='fakesecret',
        config=config
    )


def scan_pending_prompts(dynamodb):
    """Scan for prompts with status='pending'."""
    try:
        response = dynamodb.scan(
            TableName=AI_PROMPTS_TABLE,
            FilterExpression='#status = :pending',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={':pending': {'S': 'pending'}}
        )
        return response.get('Items', [])
    except Exception as e:
        logger.error(f"Error scanning for pending prompts: {e}")
        return []


def generate_response(prompt_content: str, model: str) -> dict:
    """Call Ollama API to generate a response."""
    url = f"{OLLAMA_ENDPOINT}/api/generate"

    payload = {
        "model": model,
        "prompt": prompt_content,
        "stream": False
    }

    try:
        logger.info(f"Generating response with model: {model}")
        response = requests.post(
            url,
            json=payload,
            timeout=REQUEST_TIMEOUT
        )
        response.raise_for_status()

        result = response.json()
        return {
            "success": True,
            "response": result.get("response", ""),
            "total_duration": result.get("total_duration", 0),
            "eval_count": result.get("eval_count", 0)
        }
    except requests.exceptions.Timeout:
        logger.error(f"Request timed out after {REQUEST_TIMEOUT}s")
        return {"success": False, "error": "Request timed out"}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling Ollama API: {e}")
        return {"success": False, "error": str(e)}


def update_prompt_status(dynamodb, project_object_id: str, prompt_id: str,
                         status: str, response: str = None, error: str = None):
    """Update the prompt status and response in DynamoDB."""
    try:
        update_expression = "SET #status = :status, updatedAt = :updatedAt"
        expression_names = {'#status': 'status'}
        expression_values = {
            ':status': {'S': status},
            ':updatedAt': {'N': str(int(time.time()))}
        }

        if response is not None:
            update_expression += ", #response = :response"
            expression_names['#response'] = 'response'
            expression_values[':response'] = {'S': response}

        if error is not None:
            update_expression += ", #error = :error"
            expression_names['#error'] = 'error'
            expression_values[':error'] = {'S': error}

        dynamodb.update_item(
            TableName=AI_PROMPTS_TABLE,
            Key={
                'projectObjectID': {'S': project_object_id},
                'promptID': {'S': prompt_id}
            },
            UpdateExpression=update_expression,
            ExpressionAttributeNames=expression_names,
            ExpressionAttributeValues=expression_values
        )
        logger.info(f"Updated prompt {prompt_id} to status: {status}")
        return True
    except Exception as e:
        logger.error(f"Error updating prompt status: {e}")
        return False


def process_prompt(dynamodb, item: dict):
    """Process a single pending prompt."""
    project_object_id = item.get('projectObjectID', {}).get('S', '')
    prompt_id = item.get('promptID', {}).get('S', '')
    content = item.get('content', {}).get('S', '')
    model = item.get('model', {}).get('S', 'llama3.2:3b')
    title = item.get('title', {}).get('S', 'Untitled')

    if not content:
        logger.warning(f"Prompt {prompt_id} has no content, skipping")
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error='No prompt content provided')
        return

    logger.info(f"Processing prompt: {title} ({prompt_id})")

    # Mark as processing
    update_prompt_status(dynamodb, project_object_id, prompt_id, 'processing')

    # Generate response
    result = generate_response(content, model)

    if result['success']:
        # Normalize line breaks
        response_text = result['response']
        while '\n\n' in response_text:
            response_text = response_text.replace('\n\n', '\n')
        response_text = response_text.strip()

        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'completed', response=response_text)
        logger.info(f"Successfully generated response for prompt: {title}")
    else:
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error=result.get('error', 'Unknown error'))
        logger.error(f"Failed to generate response for prompt: {title}")


def main():
    """Main worker loop."""
    logger.info("AI Prompt Generation Worker starting...")
    logger.info(f"DynamoDB endpoint: {DYNAMODB_ENDPOINT}")
    logger.info(f"Ollama endpoint: {OLLAMA_ENDPOINT}")
    logger.info(f"Poll interval: {POLL_INTERVAL}s")

    dynamodb = get_dynamodb_client()

    # Verify connection
    try:
        dynamodb.describe_table(TableName=AI_PROMPTS_TABLE)
        logger.info(f"Connected to DynamoDB table: {AI_PROMPTS_TABLE}")
    except Exception as e:
        logger.error(f"Failed to connect to DynamoDB: {e}")
        return

    while True:
        try:
            # Scan for pending prompts
            pending_prompts = scan_pending_prompts(dynamodb)

            if pending_prompts:
                logger.info(f"Found {len(pending_prompts)} pending prompt(s)")

                for item in pending_prompts:
                    process_prompt(dynamodb, item)

            # Wait before next poll
            time.sleep(POLL_INTERVAL)

        except KeyboardInterrupt:
            logger.info("Worker shutting down...")
            break
        except Exception as e:
            logger.error(f"Error in main loop: {e}")
            time.sleep(POLL_INTERVAL)


if __name__ == '__main__':
    main()
