#!/bin/bash

# ============================================================
# Compass Aurora PostgreSQL - IAM Authentication Token
#
# Git Bash Window #3
#
# Examples:
#
#   ./compass-db-token.sh uat ro
#   ./compass-db-token.sh uat rw
#   ./compass-db-token.sh uat admin
#
#   ./compass-db-token.sh prod ro
#   ./compass-db-token.sh prod rw
#   ./compass-db-token.sh prod admin
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
# Database Port
# ------------------------------------------------------------

DB_PORT="5432"

# This is the localhost port used by the SSM tunnel
DB_LOCAL_PORT="5236"


# ============================================================
# DO NOT NEED TO MODIFY BELOW THIS LINE
# ============================================================


ENV=$(echo "$1" | tr '[:upper:]' '[:lower:]')
ROLE=$(echo "$2" | tr '[:upper:]' '[:lower:]')


# ------------------------------------------------------------
# Environment Selection
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
# Role Selection
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
# Database Role Mapping
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

        AWS_PROFILE="cfs-base01-gov-core1custmgmtp-uat_${AWS_ACCOUNT}_${DB_USER}"

        ;;


    prod)

        AWS_ACCOUNT="$PROD_AWS_ACCOUNT"
        AWS_REGION="$PROD_AWS_REGION"
        DB_HOST="$PROD_DB_HOST"

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
# UPDATE THIS LINE if your IAM Role ARN contains a path
# or uses a different naming convention.
# ------------------------------------------------------------

AWS_ROLE_ARN="arn:aws-us-gov:iam::${AWS_ACCOUNT}:role/${DB_USER}"


# ------------------------------------------------------------
# Validate Configuration
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
echo "         COMPASS DATABASE IAM TOKEN GENERATOR"
echo "============================================================"
echo
echo "Environment : $(echo "$ENV" | tr '[:lower:]' '[:upper:]')"
echo "DB Access   : $ROLE"
echo "DB User     : $DB_USER"
echo
echo "AWS Account : $AWS_ACCOUNT"
echo "AWS Region  : $AWS_REGION"
echo "AWS Profile : $AWS_PROFILE"
echo "AWS Role ARN: $AWS_ROLE_ARN"
echo
echo "Aurora Host : $DB_HOST"
echo
echo "============================================================"
echo


# ------------------------------------------------------------
# Production Warning
# ------------------------------------------------------------

if [ "$ENV" = "prod" ]; then

    echo "************************************************************"
    echo "*                                                          *"
    echo "*          PRODUCTION DATABASE AUTHENTICATION              *"
    echo "*                                                          *"
    echo "************************************************************"
    echo
    echo "Role    : $DB_USER"
    echo "Account : $AWS_ACCOUNT"
    echo

    read -p "Continue? [y/N]: " CONFIRM

    case "$CONFIRM" in

        y|Y|yes|YES)
            ;;

        *)
            echo
            echo "Cancelled."
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
        echo "Run Git Bash Window #1 first."
        exit 1
    }


# ------------------------------------------------------------
# Verify Account
# ------------------------------------------------------------

if [ "$CALLER_ACCOUNT" != "$AWS_ACCOUNT" ]; then

    echo
    echo "ERROR: AWS ACCOUNT DOES NOT MATCH."
    echo
    echo "Expected : $AWS_ACCOUNT"
    echo "Actual   : $CALLER_ACCOUNT"
    echo
    echo "Stopping."
    exit 1

fi


echo "AWS credentials OK."
echo "Verified Account: $CALLER_ACCOUNT"
echo


# ------------------------------------------------------------
# Generate RDS IAM Authentication Token
# ------------------------------------------------------------

echo "Generating RDS IAM authentication token..."
echo


TOKEN=$(aws rds generate-db-auth-token \
    --hostname "$DB_HOST" \
    --port "$DB_PORT" \
    --region "$AWS_REGION" \
    --username "$DB_USER" \
    --profile "$AWS_PROFILE")


if [ -z "$TOKEN" ]; then

    echo
    echo "ERROR: Failed to generate IAM authentication token."
    exit 1

fi


# ------------------------------------------------------------
# Copy Token To Windows Clipboard
# ------------------------------------------------------------

COPIED="no"


if command -v clip.exe >/dev/null 2>&1; then

    printf "%s" "$TOKEN" | clip.exe

    COPIED="yes"

fi


# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                    TOKEN GENERATED"
echo "============================================================"
echo


if [ "$COPIED" = "yes" ]; then

    echo "IAM DB token copied to your Windows clipboard."
    echo
    echo "Use Ctrl+V in the pgAdmin Password field."

else

    echo "Copy the following token into pgAdmin:"
    echo
    echo "$TOKEN"

fi


echo
echo "------------------------------------------------------------"
echo "pgAdmin Connection"
echo "------------------------------------------------------------"
echo
echo "Hostname/address : localhost"
echo "Port             : $DB_LOCAL_PORT"
echo "Username         : $DB_USER"
echo "Password         : <generated IAM token>"
echo
echo "============================================================"