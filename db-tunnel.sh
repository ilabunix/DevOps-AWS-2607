#!/bin/bash

# ============================================================
# Compass Aurora PostgreSQL - SSM Tunnel
#
# Git Bash Window #2
#
# Examples:
#
#   ./compass-db-tunnel.sh uat ro
#   ./compass-db-tunnel.sh uat rw
#   ./compass-db-tunnel.sh uat admin
#
#   ./compass-db-tunnel.sh prod ro
#   ./compass-db-tunnel.sh prod rw
#   ./compass-db-tunnel.sh prod admin
#
# Keep this window OPEN while using pgAdmin.
# ============================================================

set -e


# ============================================================
# USER CONFIGURATION
# ============================================================
#
# UPDATE THESE VALUES FOR YOUR ENVIRONMENT.
#

# ------------------------------------------------------------
# AWS Account IDs
# ------------------------------------------------------------

UAT_AWS_ACCOUNT="REPLACE_WITH_UAT_AWS_ACCOUNT_ID"
PROD_AWS_ACCOUNT="REPLACE_WITH_PROD_AWS_ACCOUNT_ID"


# ------------------------------------------------------------
# AWS Region
# ------------------------------------------------------------

UAT_AWS_REGION="us-gov-east-1"
PROD_AWS_REGION="us-gov-east-1"


# ------------------------------------------------------------
# Aurora Global Endpoints
# ------------------------------------------------------------

UAT_DB_HOST="REPLACE_WITH_UAT_AURORA_ENDPOINT"

PROD_DB_HOST="REPLACE_WITH_PROD_AURORA_ENDPOINT"


# ------------------------------------------------------------
# EC2 / SSM Jumpboxes
# ------------------------------------------------------------

UAT_EC2_NAME="adt-frfs-compass-uat-e-ops-ec2-jumpbox"

PROD_EC2_NAME="adt-frfs-compass-prod-e-ops-ec2-jumpbox"


# ------------------------------------------------------------
# Database Ports
# ------------------------------------------------------------

DB_PORT="5432"
DB_LOCAL_PORT="5236"


# ============================================================
# DO NOT NEED TO MODIFY BELOW THIS LINE
# ============================================================


# ------------------------------------------------------------
# Read arguments
# ------------------------------------------------------------

ENV=$(echo "$1" | tr '[:upper:]' '[:lower:]')
ROLE=$(echo "$2" | tr '[:upper:]' '[:lower:]')


# ------------------------------------------------------------
# Interactive Environment Selection
# ------------------------------------------------------------

if [ -z "$ENV" ]; then

    echo
    echo "Select Compass environment:"
    echo
    echo "  1) UAT"
    echo "  2) PROD"
    echo

    read -p "Selection: " ENV_SELECTION

    case "$ENV_SELECTION" in
        1)
            ENV="uat"
            ;;
        2)
            ENV="prod"
            ;;
        *)
            echo
            echo "ERROR: Invalid environment selection."
            exit 1
            ;;
    esac

fi


# ------------------------------------------------------------
# Interactive Role Selection
# ------------------------------------------------------------

if [ -z "$ROLE" ]; then

    echo
    echo "Select database access role:"
    echo
    echo "  1) Read Only"
    echo "  2) Read/Write"
    echo "  3) Admin"
    echo

    read -p "Selection: " ROLE_SELECTION

    case "$ROLE_SELECTION" in
        1)
            ROLE="ro"
            ;;
        2)
            ROLE="rw"
            ;;
        3)
            ROLE="admin"
            ;;
        *)
            echo
            echo "ERROR: Invalid role selection."
            exit 1
            ;;
    esac

fi


# ------------------------------------------------------------
# Database User / Role Mapping
# ------------------------------------------------------------

case "$ROLE" in

    ro)
        DB_USER="cfs-adt-saml-db-ro"
        ;;

    rw)
        DB_USER="cfs-adt-saml-db-rw"
        ;;

    admin)
        DB_USER="cfs-adt-saml-db-admin"
        ;;

    *)
        echo
        echo "ERROR: Role must be:"
        echo
        echo "  ro"
        echo "  rw"
        echo "  admin"
        exit 1
        ;;

esac


# ------------------------------------------------------------
# Environment Mapping
# ------------------------------------------------------------

case "$ENV" in

    uat)

        AWS_ACCOUNT="$UAT_AWS_ACCOUNT"
        AWS_REGION="$UAT_AWS_REGION"
        DB_HOST="$UAT_DB_HOST"
        EC2_NAME="$UAT_EC2_NAME"

        AWS_PROFILE="cfs-base01-gov-core1custmgmtp-uat_${AWS_ACCOUNT}_${DB_USER}"

        ;;


    prod)

        AWS_ACCOUNT="$PROD_AWS_ACCOUNT"
        AWS_REGION="$PROD_AWS_REGION"
        DB_HOST="$PROD_DB_HOST"
        EC2_NAME="$PROD_EC2_NAME"

        AWS_PROFILE="cfs-base01-gov-core1custmgmtp-prod_${AWS_ACCOUNT}_${DB_USER}"

        ;;


    *)

        echo
        echo "ERROR: Environment must be:"
        echo
        echo "  uat"
        echo "  prod"
        exit 1
        ;;

esac


# ------------------------------------------------------------
# Construct IAM Role ARN
#
# Example:
#
# arn:aws-us-gov:iam::123456789012:role/cfs-adt-saml-db-ro
#
# If your actual IAM Role ARN uses another path or naming
# convention, UPDATE THIS LINE.
# ------------------------------------------------------------

AWS_ROLE_ARN="arn:aws-us-gov:iam::${AWS_ACCOUNT}:role/${DB_USER}"


# ------------------------------------------------------------
# Validate Required Configuration
# ------------------------------------------------------------

if [[ "$AWS_ACCOUNT" == REPLACE_* ]]; then
    echo
    echo "ERROR: AWS Account ID has not been configured for $ENV."
    exit 1
fi


if [[ "$DB_HOST" == REPLACE_* ]]; then
    echo
    echo "ERROR: Aurora endpoint has not been configured for $ENV."
    exit 1
fi


# ------------------------------------------------------------
# Display Configuration
# ------------------------------------------------------------

echo
echo "============================================================"
echo "              COMPASS DATABASE SSM TUNNEL"
echo "============================================================"
echo
echo "Environment    : $(echo "$ENV" | tr '[:lower:]' '[:upper:]')"
echo "DB Access      : $ROLE"
echo "DB User        : $DB_USER"
echo
echo "AWS Account    : $AWS_ACCOUNT"
echo "AWS Region     : $AWS_REGION"
echo "AWS Profile    : $AWS_PROFILE"
echo "AWS Role ARN   : $AWS_ROLE_ARN"
echo
echo "Jumpbox        : $EC2_NAME"
echo "Aurora Host    : $DB_HOST"
echo
echo "Remote Port    : $DB_PORT"
echo "Local Port     : $DB_LOCAL_PORT"
echo
echo "============================================================"
echo


# ------------------------------------------------------------
# Production Confirmation
# ------------------------------------------------------------

if [ "$ENV" = "prod" ]; then

    echo "************************************************************"
    echo "*                                                          *"
    echo "*               PRODUCTION DATABASE ACCESS                 *"
    echo "*                                                          *"
    echo "************************************************************"
    echo
    echo "Role      : $DB_USER"
    echo "Account   : $AWS_ACCOUNT"
    echo

    read -p "Continue with PROD connection? [y/N]: " CONFIRM

    case "$CONFIRM" in

        y|Y|yes|YES)
            ;;

        *)
            echo
            echo "Connection cancelled."
            exit 0
            ;;

    esac

    echo

fi


# ------------------------------------------------------------
# Verify AWS Credentials
# ------------------------------------------------------------

echo "Checking AWS credentials..."
echo

CALLER_ACCOUNT=$(aws sts get-caller-identity \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query Account \
    --output text 2>/dev/null) || {

        echo
        echo "ERROR: Unable to use AWS profile:"
        echo
        echo "  $AWS_PROFILE"
        echo
        echo "Run Git Bash Window #1 first to generate"
        echo "your temporary AWS credentials."
        exit 1
    }


# ------------------------------------------------------------
# Verify Correct AWS Account
# ------------------------------------------------------------

if [ "$CALLER_ACCOUNT" != "$AWS_ACCOUNT" ]; then

    echo
    echo "ERROR: AWS ACCOUNT DOES NOT MATCH."
    echo
    echo "Expected : $AWS_ACCOUNT"
    echo "Actual   : $CALLER_ACCOUNT"
    echo
    echo "Stopping to prevent connection to the wrong account."
    exit 1

fi


echo "AWS credentials OK."
echo "Verified Account: $CALLER_ACCOUNT"
echo


# ------------------------------------------------------------
# Locate Running Jumpbox
# ------------------------------------------------------------

echo "Finding running Compass jumpbox..."
echo


INSTANCE_ID=$(aws ec2 describe-instances \
    --filters \
        "Name=tag:Name,Values=$EC2_NAME" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --output text)


if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then

    echo
    echo "ERROR: Could not find a running jumpbox."
    echo
    echo "Expected EC2 Name:"
    echo
    echo "  $EC2_NAME"
    exit 1

fi


echo "Jumpbox found:"
echo
echo "  $INSTANCE_ID"
echo


# ------------------------------------------------------------
# Start SSM Port Forwarding
# ------------------------------------------------------------

echo "============================================================"
echo "                STARTING SSM TUNNEL"
echo "============================================================"
echo
echo "pgAdmin Connection:"
echo
echo "  Hostname : localhost"
echo "  Port     : $DB_LOCAL_PORT"
echo "  Username : $DB_USER"
echo
echo "KEEP THIS WINDOW OPEN WHILE USING pgAdmin."
echo
echo "Press Ctrl+C when finished."
echo
echo "============================================================"
echo


aws ssm start-session \
    --region "$AWS_REGION" \
    --target "$INSTANCE_ID" \
    --profile "$AWS_PROFILE" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$DB_HOST,portNumber=$DB_PORT,localPortNumber=$DB_LOCAL_PORT"