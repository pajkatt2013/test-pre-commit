#
# Software created within Project Orion.
# Copyright (C) 2024-2025 Bayerische Motoren Werke Aktiengesellschaft (BMW AG) and/or
# Qualcomm Technologies, Inc. and/or its subsidiaries. All rights reserved.
# Authorship details are documented in the Git history.
#
"""Lambda handler serving APIgw as custom authorizer."""
# mostly taken from sample code and should be updated as needed
# https://confluence.cc.bmwgroup.net/display/orioncn/API+Owner+-+API+Gateway+-+How+to
# +enable+a+custom+Lambda+Authorizer+for+your+API+Gateway+to+validate+JWT+Tokens
import json
import logging
import os
import re
from typing import NoReturn
import jwt
import requests
from jwt.exceptions import InvalidAudienceError, PyJWTError
# Create a mutable dictionary to store the values
key_cache = {}
# Keycloak Configuration Env Vars
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
KEYCLOAK_URL = os.getenv("KEYCLOAK_URL", "")
KEYCLOAK_REALM = os.getenv("KEYCLOAK_REALM", "orionadp")
KEYCLOAK_CLIENT_ID = os.getenv("KEYCLOAK_CLIENT_ID", "")
M2M_KEYCLOAK_CLIENT_ID = os.getenv("M2M_KEYCLOAK_CLIENT_ID", "")
KEYCLOAK_CLIENT_IDS = [KEYCLOAK_CLIENT_ID, M2M_KEYCLOAK_CLIENT_ID]
KEYCLOAK_ISSUER = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}"
logger = logging.getLogger(__name__)
logger.setLevel(LOG_LEVEL)
def load_auth_config() -> dict:
    """
    Load the authentication configuration from ENV.
 
    Returns:
        dict: The authentication configuration.
 
    """
    if "group_config" not in key_cache:
        group_config = os.getenv("GROUP_ROLE_CONFIG")
        config = json.loads(group_config) if group_config else {}
        key_cache["group_config"] = config
        return config
    return key_cache["group_config"]
def fetch_public_key() -> str:
    """
    Fetch the public key from Keycloak and cache it.
 
    Returns:
        str: The public key in PEM format.
 
    """
    if "public_key" not in key_cache:
        keycloak_public_key_url = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}"
        # for more info: /.well-known/openid-configuration
        response = requests.get(keycloak_public_key_url, timeout=30)
        logger.debug(f"Received Keycloak response: {response.json()}")
        response.raise_for_status()
        public_key_data = response.json()["public_key"]
        key_cache["public_key"] = (
            "-----BEGIN PUBLIC KEY-----\n"
            + "\n".join(
                public_key_data[i : i + 64] for i in range(0, len(public_key_data), 64)
            )
            + "\n-----END PUBLIC KEY-----"
        )
    return key_cache["public_key"]
def verify_token(id_token: str) -> dict | None:
    """
    Parse the JWT token and extract the payload.
 
    Args:
        id_token (str): The JWT token to parse.
 
    Returns:
        dict | None: The token payload if valid, None otherwise.
 
    """
    def raise_invalid_audience_error() -> NoReturn:
        msg = "Invalid audience"
        raise InvalidAudienceError(msg)
    try:
        public_key = fetch_public_key()
        headers = jwt.get_unverified_header(id_token)
        decoded_token = jwt.decode(
            id_token,
            public_key,
            algorithms=[headers["alg"]],
            issuer=KEYCLOAK_ISSUER,
            options={"verify_exp": True, "verify_aud": False},
        )
        if decoded_token["azp"] in KEYCLOAK_CLIENT_IDS:
            return decoded_token
        raise_invalid_audience_error()
    except PyJWTError as e:
        print(f"Error verifying id_token: {e}")
        return None
def authorize_token(event: dict, id_token_payload: dict, auth_config: dict) -> bool:
    """
    Authorize the user
 
    1. exact match: requested URL path
    2. path variable match: resource name. e.g /v1/jobs/{id}
    3. fuzzy match: wildcard
    """
    user_groups = id_token_payload.get("groups-custom") or id_token_payload.get(
        "groups-custom-m2m", []
    )
    request_path = event["path"]
    request_method = event["httpMethod"]
    candidate_groups = []
    for auth_path, auth_groups in auth_config.items():
        for auth_group in auth_groups:
            if request_method in auth_group["method"]:
                if request_path == auth_path or event["resource"] == auth_path:
                    candidate_groups.append(auth_group)
                else:
                    if "*" in auth_path:
                        # Wildcard handling
                        path_regex_pattern = auth_path.replace("*", ".*")
                    elif "{" in auth_path:
                        # Replace `{id}` with regex
                        path_regex_pattern = re.sub(
                            r"\{[a-zA-Z0-9]+\}", r"([^/]+)", auth_path
                        )
                    else:
                        continue
                    match = re.match(f"^{path_regex_pattern}$", request_path)
                    if match:
                        candidate_groups.append(auth_group)
    if len(candidate_groups) > 0:
        for group in candidate_groups:
            if any("/" + group_name in user_groups for group_name in group["group"]):
                return True
        return False
    # the request is allowed if the corresponding authorization is not defined
    logger.warning(
        f'No authorization is defined for the resource: {event["resource"]}, method: {request_method}. Continuing anyway...'
    )
    return True
def handler(event: dict, context: object) -> dict:
    """
    Lambda handler serving API Gateway requests.
 
    Args:
        event (dict): The event data.
        context (object): The Lambda context object.
 
    Returns:
        dict: The response containing the authorization policy.
 
    """
    logger.debug(f"Fetched Event from Input: {event}, Context: {context}")
    headers = event["headers"]
    # some Api testing tools automatically convert header names to lowercase
    bearer_token = headers.get("authorization")
    if bearer_token is None:
        bearer_token = headers.get("Authorization")
    if bearer_token is None:
        return generate_policy(
            principal_id="user",
            effect="Deny",
            resource=event["methodArn"],
            context_data={
                "error": "Empty token",
                "errorDescription": "Token is missing in the request header!",
            },
        )
    id_token_raw = bearer_token.removeprefix("Bearer ")
    id_token_payload = verify_token(id_token_raw)
    if id_token_payload is None:
        logger.debug("Final Response: DENY API Call (Unauthorized)")
        return generate_policy(
            principal_id="user",
            effect="Deny",
            resource=event["methodArn"],
            context_data={
                "error": "Invalid token",
                "errorDescription": "The provided token is invalid or expired!",
            },
        )
    principal_id = id_token_payload["sub"]  # whom the token refers to
    auth_config = load_auth_config()
    allowed = authorize_token(event, id_token_payload, auth_config)
    if not allowed:
        logger.debug("Final Response: DENY API Call (Access Denied)")
        return generate_policy(
            principal_id=principal_id,
            effect="Deny",
            resource=event["methodArn"],
            context_data={
                "error": "Access denied",
            },
        )
    # Return "ALLOW policy" the IAM policy document for the Lambda Authorizer
    logger.debug("Final Response: ALLOW API Call")
    return generate_policy(
        principal_id=principal_id,
        effect="Allow",
        resource=event["methodArn"],
    )
def generate_policy(
    principal_id: str,
    effect: str,
    resource: str,
    context_data: dict | None = None,
) -> dict:
    """Help function to generate IAM policy"""
    if context_data is None:
        context_data = {}
    return {
        "principalId": principal_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": effect,
                    "Action": "execute-api:Invoke",
                    "Resource": resource,
                }
            ],
        },
        "context": context_data,
    }