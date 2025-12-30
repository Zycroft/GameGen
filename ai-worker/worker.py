#!/usr/bin/env python3
"""
AI Prompt Generation Worker

Polls DynamoDB for prompts with status='generate' and generates responses
using the selected AI service, then updates DynamoDB with the result.
Also handles image generation when imageStatus='generate'.

Safety measures:
- Only processes items with explicit 'generate' status
- Uses atomic conditional updates to prevent race conditions
- Tracks generation timestamps
- Rate limiting between requests
- Daily request limits per service
- Zycroft processes one request at a time
"""

import os
import time
import json
import logging
import requests
import boto3
import base64
import threading
import subprocess
import tempfile
import uuid
from botocore.config import Config
from botocore.exceptions import ClientError
from datetime import datetime, timezone

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
USAGE_TRACKING_TABLE = os.getenv('USAGE_TRACKING_TABLE', 'UsageTracking')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '10'))  # seconds
REQUEST_TIMEOUT = int(os.getenv('REQUEST_TIMEOUT', '600'))  # 10 minutes for slow models
MIN_REQUEST_INTERVAL = int(os.getenv('MIN_REQUEST_INTERVAL', '2'))  # Rate limit between API calls

# Image storage configuration
IMAGE_SERVER_USER = os.getenv('IMAGE_SERVER_USER', 'zycroft')
IMAGE_SERVER_HOST = os.getenv('IMAGE_SERVER_HOST', 'zycroft.duckdns.org')
IMAGE_SERVER_PATH = os.getenv('IMAGE_SERVER_PATH', '/var/www/GameGen-images/html')
IMAGE_PUBLIC_URL = os.getenv('IMAGE_PUBLIC_URL', 'https://zycroft.duckdns.org/GameGen-images')

# API Keys from environment (can also be loaded from config)
API_KEYS = {
    'OpenAI': os.getenv('OPENAI_API_KEY', ''),
    'Claude': os.getenv('CLAUDE_API_KEY', ''),
    'Gemini': os.getenv('GEMINI_API_KEY', ''),
    'Grok': os.getenv('GROK_API_KEY', ''),
    'Zycroft': '',  # Ollama doesn't need key
}

# Daily limits (loaded from config)
DAILY_LIMITS = {
    'default': 5,
    'Zycroft': 100,
    'OpenAI': 5,
    'Claude': 5,
    'Gemini': 5,
    'Grok': 5,
}

DAILY_IMAGE_LIMITS = {
    'default': 3,
    'OpenAI': 3,
    'Stability': 3,
    'Midjourney': 3,
}

# API Endpoints
API_ENDPOINTS = {
    'OpenAI': 'https://api.openai.com/v1/chat/completions',
    'Claude': 'https://api.anthropic.com/v1/messages',
    'Gemini': 'https://generativelanguage.googleapis.com/v1beta/models',
    'Grok': 'https://api.x.ai/v1/chat/completions',
    'Zycroft': OLLAMA_ENDPOINT,
}

# Image API Endpoints
IMAGE_ENDPOINTS = {
    'OpenAI': 'https://api.openai.com/v1/images/generations',
}

# Track last request time for rate limiting
last_request_time = 0

# Lock for Zycroft single-request processing
zycroft_lock = threading.Lock()


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


def load_config():
    """Load configuration from config files."""
    global DAILY_LIMITS, DAILY_IMAGE_LIMITS, API_KEYS, USAGE_TRACKING_TABLE

    config_paths = [
        '/app/config.json',
        './config.json',
        '../config.json',
    ]

    for path in config_paths:
        try:
            with open(path, 'r') as f:
                config = json.load(f)
                if 'daily_limits' in config:
                    DAILY_LIMITS.update(config['daily_limits'])
                    logger.info(f"Loaded daily limits from {path}")
                if 'daily_image_limits' in config:
                    DAILY_IMAGE_LIMITS.update(config['daily_image_limits'])
                if 'tables' in config and 'usageTracking' in config['tables']:
                    USAGE_TRACKING_TABLE = config['tables']['usageTracking']
                break
        except FileNotFoundError:
            continue
        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse {path}: {e}")

    # Load API keys
    api_config_paths = [
        '/app/config-api.json',
        './config-api.json',
        '../config-api.json',
    ]

    for path in api_config_paths:
        try:
            with open(path, 'r') as f:
                config = json.load(f)
                for service, data in config.items():
                    if isinstance(data, dict) and 'api_key' in data:
                        if data['api_key']:
                            API_KEYS[service] = data['api_key']
                    elif isinstance(data, str):
                        API_KEYS[service] = data
                logger.info(f"Loaded API keys from {path}")
                break
        except FileNotFoundError:
            continue
        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse {path}: {e}")


def ensure_usage_table_exists(dynamodb):
    """Create usage tracking table if it doesn't exist."""
    try:
        dynamodb.describe_table(TableName=USAGE_TRACKING_TABLE)
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            logger.info(f"Creating usage tracking table: {USAGE_TRACKING_TABLE}")
            dynamodb.create_table(
                TableName=USAGE_TRACKING_TABLE,
                KeySchema=[
                    {'AttributeName': 'dateService', 'KeyType': 'HASH'},
                ],
                AttributeDefinitions=[
                    {'AttributeName': 'dateService', 'AttributeType': 'S'},
                ],
                BillingMode='PAY_PER_REQUEST'
            )
            # Wait for table to be created
            time.sleep(2)
        else:
            raise


def get_today_date_str():
    """Get today's date as a string in UTC."""
    return datetime.now(timezone.utc).strftime('%Y-%m-%d')


def get_usage_count(dynamodb, service: str, usage_type: str = 'prompt') -> int:
    """Get current usage count for a service today."""
    date_service = f"{get_today_date_str()}_{service}_{usage_type}"
    try:
        response = dynamodb.get_item(
            TableName=USAGE_TRACKING_TABLE,
            Key={'dateService': {'S': date_service}}
        )
        if 'Item' in response:
            return int(response['Item'].get('count', {}).get('N', '0'))
        return 0
    except Exception as e:
        logger.error(f"Error getting usage count: {e}")
        return 0


def increment_usage_count(dynamodb, service: str, usage_type: str = 'prompt') -> int:
    """Increment usage count for a service and return new count."""
    date_service = f"{get_today_date_str()}_{service}_{usage_type}"
    try:
        response = dynamodb.update_item(
            TableName=USAGE_TRACKING_TABLE,
            Key={'dateService': {'S': date_service}},
            UpdateExpression='SET #count = if_not_exists(#count, :zero) + :inc, lastUpdated = :now',
            ExpressionAttributeNames={'#count': 'count'},
            ExpressionAttributeValues={
                ':inc': {'N': '1'},
                ':zero': {'N': '0'},
                ':now': {'N': str(int(time.time()))}
            },
            ReturnValues='UPDATED_NEW'
        )
        return int(response['Attributes']['count']['N'])
    except Exception as e:
        logger.error(f"Error incrementing usage count: {e}")
        return -1


def check_daily_limit(dynamodb, service: str, usage_type: str = 'prompt') -> tuple[bool, int, int]:
    """
    Check if daily limit is reached for a service.
    Returns (is_allowed, current_count, limit)
    """
    if usage_type == 'image':
        limit = DAILY_IMAGE_LIMITS.get(service, DAILY_IMAGE_LIMITS.get('default', 3))
    else:
        limit = DAILY_LIMITS.get(service, DAILY_LIMITS.get('default', 5))

    current_count = get_usage_count(dynamodb, service, usage_type)
    is_allowed = current_count < limit
    return is_allowed, current_count, limit


def rate_limit():
    """Enforce minimum interval between API requests."""
    global last_request_time
    elapsed = time.time() - last_request_time
    if elapsed < MIN_REQUEST_INTERVAL:
        time.sleep(MIN_REQUEST_INTERVAL - elapsed)
    last_request_time = time.time()


def scan_for_generate_status(dynamodb, status_field='status'):
    """Scan for prompts with status='generate'."""
    try:
        response = dynamodb.scan(
            TableName=AI_PROMPTS_TABLE,
            FilterExpression='#status = :generate',
            ExpressionAttributeNames={'#status': status_field},
            ExpressionAttributeValues={':generate': {'S': 'generate'}}
        )
        return response.get('Items', [])
    except Exception as e:
        logger.error(f"Error scanning for {status_field}='generate': {e}")
        return []


def atomic_claim_item(dynamodb, project_object_id: str, prompt_id: str, status_field: str) -> bool:
    """
    Atomically claim an item for processing using conditional update.
    Returns True if claimed successfully, False if already being processed.
    This prevents race conditions with multiple workers.
    """
    try:
        dynamodb.update_item(
            TableName=AI_PROMPTS_TABLE,
            Key={
                'projectObjectID': {'S': project_object_id},
                'promptID': {'S': prompt_id}
            },
            UpdateExpression=f"SET #{status_field} = :processing, processingStartedAt = :startTime",
            ConditionExpression=f"#{status_field} = :generate",
            ExpressionAttributeNames={f'#{status_field}': status_field},
            ExpressionAttributeValues={
                ':processing': {'S': 'processing'},
                ':generate': {'S': 'generate'},
                ':startTime': {'N': str(int(time.time()))}
            }
        )
        return True
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            logger.info(f"Item {prompt_id} already claimed by another worker")
            return False
        raise


def generate_response_ollama(prompt_content: str, model: str) -> dict:
    """Call Ollama API to generate a response (Zycroft service)."""
    url = f"{OLLAMA_ENDPOINT}/api/generate"

    payload = {
        "model": model,
        "prompt": prompt_content,
        "stream": False
    }

    try:
        rate_limit()
        logger.info(f"Generating response with Ollama model: {model}")
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
        logger.error(f"Ollama request timed out after {REQUEST_TIMEOUT}s")
        return {"success": False, "error": "Request timed out"}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling Ollama API: {e}")
        return {"success": False, "error": str(e)}


def generate_response_openai(prompt_content: str, model: str, api_key: str) -> dict:
    """Call OpenAI API to generate a response."""
    url = API_ENDPOINTS['OpenAI']

    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt_content}],
    }

    # GPT-5 and o1/o3 models use max_completion_tokens, older models use max_tokens
    if model.startswith('gpt-5') or model.startswith('o1') or model.startswith('o3'):
        payload["max_completion_tokens"] = 4096
    else:
        payload["max_tokens"] = 4096

    try:
        rate_limit()
        logger.info(f"Generating response with OpenAI model: {model}")
        response = requests.post(url, headers=headers, json=payload, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()

        result = response.json()
        content = result.get('choices', [{}])[0].get('message', {}).get('content', '')
        return {"success": True, "response": content}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling OpenAI API: {e}")
        return {"success": False, "error": str(e)}


def generate_response_claude(prompt_content: str, model: str, api_key: str) -> dict:
    """Call Anthropic Claude API to generate a response."""
    url = API_ENDPOINTS['Claude']

    headers = {
        'x-api-key': api_key,
        'Content-Type': 'application/json',
        'anthropic-version': '2023-06-01'
    }

    payload = {
        "model": model,
        "max_tokens": 4096,
        "messages": [{"role": "user", "content": prompt_content}]
    }

    try:
        rate_limit()
        logger.info(f"Generating response with Claude model: {model}")
        response = requests.post(url, headers=headers, json=payload, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()

        result = response.json()
        content = result.get('content', [{}])[0].get('text', '')
        return {"success": True, "response": content}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling Claude API: {e}")
        return {"success": False, "error": str(e)}


def generate_response_gemini(prompt_content: str, model: str, api_key: str) -> dict:
    """Call Google Gemini API to generate a response."""
    url = f"{API_ENDPOINTS['Gemini']}/{model}:generateContent?key={api_key}"

    headers = {'Content-Type': 'application/json'}

    payload = {
        "contents": [{"parts": [{"text": prompt_content}]}]
    }

    try:
        rate_limit()
        logger.info(f"Generating response with Gemini model: {model}")
        response = requests.post(url, headers=headers, json=payload, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()

        result = response.json()
        content = result.get('candidates', [{}])[0].get('content', {}).get('parts', [{}])[0].get('text', '')
        return {"success": True, "response": content}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling Gemini API: {e}")
        return {"success": False, "error": str(e)}


def generate_response_grok(prompt_content: str, model: str, api_key: str) -> dict:
    """Call xAI Grok API to generate a response."""
    url = API_ENDPOINTS['Grok']

    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt_content}],
        "max_tokens": 4096
    }

    try:
        rate_limit()
        logger.info(f"Generating response with Grok model: {model}")
        response = requests.post(url, headers=headers, json=payload, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()

        result = response.json()
        content = result.get('choices', [{}])[0].get('message', {}).get('content', '')
        return {"success": True, "response": content}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling Grok API: {e}")
        return {"success": False, "error": str(e)}


def generate_response(prompt_content: str, model: str, service: str) -> dict:
    """Generate response using the specified service."""
    api_key = API_KEYS.get(service, '')

    if service == 'Zycroft':
        # Use lock to ensure only one Zycroft request at a time
        with zycroft_lock:
            return generate_response_ollama(prompt_content, model)
    elif service == 'OpenAI':
        if not api_key:
            return {"success": False, "error": "OpenAI API key not configured"}
        return generate_response_openai(prompt_content, model, api_key)
    elif service == 'Claude':
        if not api_key:
            return {"success": False, "error": "Claude API key not configured"}
        return generate_response_claude(prompt_content, model, api_key)
    elif service == 'Gemini':
        if not api_key:
            return {"success": False, "error": "Gemini API key not configured"}
        return generate_response_gemini(prompt_content, model, api_key)
    elif service == 'Grok':
        if not api_key:
            return {"success": False, "error": "Grok API key not configured"}
        return generate_response_grok(prompt_content, model, api_key)
    else:
        return {"success": False, "error": f"Unknown service: {service}"}


def generate_image_openai(prompt: str, model: str, api_key: str) -> dict:
    """Generate image using OpenAI DALL-E."""
    url = IMAGE_ENDPOINTS['OpenAI']

    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }

    # Map model names
    dalle_model = 'dall-e-3' if 'dall-e-3' in model else 'dall-e-2'
    if 'gpt-image' in model:
        dalle_model = 'dall-e-3'  # Use DALL-E 3 for gpt-image-1

    payload = {
        "model": dalle_model,
        "prompt": prompt,
        "n": 1,
        "size": "1024x1024",
        "response_format": "b64_json"
    }

    try:
        rate_limit()
        logger.info(f"Generating image with OpenAI model: {dalle_model}")
        response = requests.post(url, headers=headers, json=payload, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()

        result = response.json()
        image_data = result.get('data', [{}])[0].get('b64_json', '')
        return {"success": True, "image_data": image_data}
    except requests.exceptions.RequestException as e:
        logger.error(f"Error calling OpenAI Image API: {e}")
        return {"success": False, "error": str(e)}


def generate_image(prompt: str, model: str, service: str) -> dict:
    """Generate image using the specified service."""
    api_key = API_KEYS.get(service, '')

    if service == 'OpenAI':
        if not api_key:
            return {"success": False, "error": "OpenAI API key not configured"}
        return generate_image_openai(prompt, model, api_key)
    elif service == 'Stability':
        # Stability AI integration placeholder
        return {"success": False, "error": "Stability AI integration not yet implemented"}
    elif service == 'Midjourney':
        # Midjourney integration placeholder
        return {"success": False, "error": "Midjourney integration not yet implemented"}
    else:
        return {"success": False, "error": f"Unknown image service: {service}"}


def update_prompt_status(dynamodb, project_object_id: str, prompt_id: str,
                         status: str, response: str = None, error: str = None,
                         status_field: str = 'status'):
    """Update the prompt status and response in DynamoDB."""
    try:
        update_expression = f"SET #{status_field} = :status, updatedAt = :updatedAt"
        expression_names = {f'#{status_field}': status_field}
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

        # Add completion timestamp
        update_expression += ", completedAt = :completedAt"
        expression_values[':completedAt'] = {'N': str(int(time.time()))}

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
        logger.info(f"Updated prompt {prompt_id} {status_field} to: {status}")
        return True
    except Exception as e:
        logger.error(f"Error updating prompt status: {e}")
        return False


def process_prompt(dynamodb, item: dict):
    """Process a single prompt for text generation."""
    project_object_id = item.get('projectObjectID', {}).get('S', '')
    prompt_id = item.get('promptID', {}).get('S', '')
    content = item.get('content', {}).get('S', '')
    service = item.get('service', {}).get('S', 'Zycroft')
    model = item.get('model', {}).get('S', 'llama3.2:3b')
    title = item.get('title', {}).get('S', 'Untitled')

    if not content:
        logger.warning(f"Prompt {prompt_id} has no content, skipping")
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error='No prompt content provided')
        return

    # Check daily limit
    is_allowed, current_count, limit = check_daily_limit(dynamodb, service, 'prompt')
    if not is_allowed:
        logger.warning(f"Daily limit reached for {service}: {current_count}/{limit}")
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error=f'Daily limit reached for {service} ({current_count}/{limit})')
        return

    # Try to atomically claim this item
    if not atomic_claim_item(dynamodb, project_object_id, prompt_id, 'status'):
        return  # Already being processed by another worker

    logger.info(f"Processing prompt: {title} ({prompt_id}) with {service}/{model}")

    # Generate response
    result = generate_response(content, model, service)

    if result['success']:
        # Increment usage count
        increment_usage_count(dynamodb, service, 'prompt')

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


def process_image_generation(dynamodb, item: dict):
    """Process a prompt for image generation with support for multiple images."""
    project_object_id = item.get('projectObjectID', {}).get('S', '')
    prompt_id = item.get('promptID', {}).get('S', '')
    content = item.get('content', {}).get('S', '')
    service = item.get('imageService', {}).get('S', 'OpenAI')
    model = item.get('imageModel', {}).get('S', 'dall-e-3')
    title = item.get('title', {}).get('S', 'Untitled')
    image_mode = item.get('imageMode', {}).get('S', 'replace')
    image_count = int(item.get('imageCount', {}).get('N', '1'))

    if not content:
        logger.warning(f"Prompt {prompt_id} has no content for image generation, skipping")
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error='No prompt content provided',
                           status_field='imageStatus')
        return

    # Check daily limit - need enough capacity for all requested images
    is_allowed, current_count, limit = check_daily_limit(dynamodb, service, 'image')
    remaining = limit - current_count
    if remaining <= 0:
        logger.warning(f"Daily image limit reached for {service}: {current_count}/{limit}")
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error=f'Daily image limit reached for {service} ({current_count}/{limit})',
                           status_field='imageStatus')
        return

    # Limit count to remaining capacity
    actual_count = min(image_count, remaining)
    if actual_count < image_count:
        logger.warning(f"Reducing image count from {image_count} to {actual_count} due to daily limit")

    # Try to atomically claim this item
    if not atomic_claim_item(dynamodb, project_object_id, prompt_id, 'imageStatus'):
        return  # Already being processed by another worker

    logger.info(f"Generating {actual_count} image(s) (mode: {image_mode}) for: {title} ({prompt_id}) with {service}/{model}")

    # Delete existing images from server if in replace mode
    if image_mode == 'replace':
        delete_existing_images_from_server(project_object_id, prompt_id)

    # Get existing images if in append mode
    existing_images = []
    if image_mode == 'append':
        existing_images = get_existing_images(dynamodb, project_object_id, prompt_id)

    # Generate images
    generated_images = []
    errors = []

    for i in range(actual_count):
        logger.info(f"Generating image {i+1}/{actual_count}...")
        result = generate_image(content, model, service)

        if result['success']:
            # Increment usage count for each successful generation
            increment_usage_count(dynamodb, service, 'image')

            # Upload image to server
            image_index = len(existing_images) + len(generated_images)
            upload_result = upload_image_to_server(
                result.get('image_data', ''),
                project_object_id,
                prompt_id,
                image_index
            )

            if 'url' in upload_result:
                generated_images.append({
                    'url': upload_result['url'],
                    'index': image_index,
                    'timestamp': int(time.time())
                })
                logger.info(f"Successfully generated and uploaded image {i+1}/{actual_count}")
            else:
                errors.append(upload_result.get('error', 'Upload failed'))
                logger.error(f"Failed to upload image {i+1}/{actual_count}: {upload_result.get('error')}")
        else:
            errors.append(result.get('error', 'Unknown error'))
            logger.error(f"Failed to generate image {i+1}/{actual_count}: {result.get('error')}")

    # Combine images based on mode
    if image_mode == 'replace':
        final_images = generated_images
    else:  # append
        final_images = existing_images + generated_images

    # Update prompt with generated images
    if generated_images:
        save_generated_images(dynamodb, project_object_id, prompt_id, final_images)
        status = 'completed' if not errors else 'completed'  # Still mark completed if some succeeded
        error_msg = None
        if errors:
            error_msg = f"Generated {len(generated_images)}/{actual_count} images. Errors: {'; '.join(errors[:3])}"
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           status, error=error_msg, status_field='imageStatus')
        logger.info(f"Successfully generated {len(generated_images)}/{actual_count} images for prompt: {title}")
    else:
        update_prompt_status(dynamodb, project_object_id, prompt_id,
                           'error', error=errors[0] if errors else 'No images generated',
                           status_field='imageStatus')
        logger.error(f"Failed to generate any images for prompt: {title}")


def get_existing_images(dynamodb, project_object_id: str, prompt_id: str) -> list:
    """Get existing images from a prompt for append mode."""
    try:
        response = dynamodb.get_item(
            TableName=AI_PROMPTS_TABLE,
            Key={
                'projectObjectID': {'S': project_object_id},
                'promptID': {'S': prompt_id}
            },
            ProjectionExpression='generatedImages'
        )
        if 'Item' in response and 'generatedImages' in response['Item']:
            images_json = response['Item']['generatedImages'].get('S', '[]')
            return json.loads(images_json)
        return []
    except Exception as e:
        logger.error(f"Error getting existing images: {e}")
        return []


def upload_image_to_server(image_base64: str, project_object_id: str, prompt_id: str, image_index: int) -> dict:
    """
    Save base64 image directly to the mounted NGINX images directory.
    Returns dict with 'url' on success or 'error' on failure.
    """
    try:
        # Decode base64 image
        image_data = base64.b64decode(image_base64)

        # Generate unique filename
        timestamp = int(time.time())
        unique_id = str(uuid.uuid4())[:8]
        filename = f"img_{timestamp}_{unique_id}_{image_index}.png"

        # Create folder structure: projectObjectID/promptID/
        folder_path = f"{IMAGE_SERVER_PATH}/{project_object_id}/{prompt_id}"
        file_path = f"{folder_path}/{filename}"
        public_url = f"{IMAGE_PUBLIC_URL}/{project_object_id}/{prompt_id}/{filename}"

        # Create directory if it doesn't exist
        os.makedirs(folder_path, exist_ok=True)

        # Write image file directly
        with open(file_path, 'wb') as f:
            f.write(image_data)

        logger.info(f"Saved image to {file_path}, URL: {public_url}")
        return {'url': public_url}

    except Exception as e:
        logger.error(f"Error saving image: {e}")
        return {'error': str(e)}


def delete_existing_images_from_server(project_object_id: str, prompt_id: str):
    """Delete all images in the prompt folder (for replace mode)."""
    try:
        folder_path = f"{IMAGE_SERVER_PATH}/{project_object_id}/{prompt_id}"
        if os.path.exists(folder_path):
            import glob
            for png_file in glob.glob(f"{folder_path}/*.png"):
                os.remove(png_file)
            logger.info(f"Deleted existing images from {folder_path}")
    except Exception as e:
        logger.warning(f"Error deleting existing images: {e}")


def save_generated_images(dynamodb, project_object_id: str, prompt_id: str, images: list):
    """Save generated image URLs to the prompt in DynamoDB."""
    try:
        # Only save URL metadata, not the base64 data
        image_metadata = []
        for img in images:
            metadata = {
                'url': img.get('url', ''),
                'index': img.get('index', 0),
                'timestamp': img.get('timestamp', int(time.time()))
            }
            image_metadata.append(metadata)

        images_json = json.dumps(image_metadata)
        dynamodb.update_item(
            TableName=AI_PROMPTS_TABLE,
            Key={
                'projectObjectID': {'S': project_object_id},
                'promptID': {'S': prompt_id}
            },
            UpdateExpression='SET generatedImages = :images, imageGeneratedAt = :timestamp',
            ExpressionAttributeValues={
                ':images': {'S': images_json},
                ':timestamp': {'N': str(int(time.time()))}
            }
        )
        logger.info(f"Saved {len(image_metadata)} image URLs to prompt {prompt_id}")
    except Exception as e:
        logger.error(f"Error saving generated images: {e}")


def main():
    """Main worker loop."""
    logger.info("AI Prompt Generation Worker starting...")
    logger.info(f"DynamoDB endpoint: {DYNAMODB_ENDPOINT}")
    logger.info(f"Ollama endpoint: {OLLAMA_ENDPOINT}")
    logger.info(f"Poll interval: {POLL_INTERVAL}s")

    # Load configuration
    load_config()
    logger.info(f"Daily limits: {DAILY_LIMITS}")
    logger.info(f"Daily image limits: {DAILY_IMAGE_LIMITS}")

    dynamodb = get_dynamodb_client()

    # Verify connection
    try:
        dynamodb.describe_table(TableName=AI_PROMPTS_TABLE)
        logger.info(f"Connected to DynamoDB table: {AI_PROMPTS_TABLE}")
    except Exception as e:
        logger.error(f"Failed to connect to DynamoDB: {e}")
        return

    # Ensure usage tracking table exists
    try:
        ensure_usage_table_exists(dynamodb)
        logger.info(f"Usage tracking table ready: {USAGE_TRACKING_TABLE}")
    except Exception as e:
        logger.warning(f"Could not ensure usage table: {e}")

    while True:
        try:
            # Scan for prompts needing text generation
            generate_prompts = scan_for_generate_status(dynamodb, 'status')
            if generate_prompts:
                logger.info(f"Found {len(generate_prompts)} prompt(s) to generate")
                for item in generate_prompts:
                    process_prompt(dynamodb, item)

            # Scan for prompts needing image generation
            image_prompts = scan_for_generate_status(dynamodb, 'imageStatus')
            if image_prompts:
                logger.info(f"Found {len(image_prompts)} image(s) to generate")
                for item in image_prompts:
                    process_image_generation(dynamodb, item)

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
