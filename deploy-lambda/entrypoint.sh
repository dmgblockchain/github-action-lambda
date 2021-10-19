#!/usr/bin/bash -l
set +e

IAM_USER=$(aws sts get-caller-identity --query "Arn" | sed 's/\"//g')
echo "::set-output name=IAM_USER::${IAM_USER##*\/}"

# ACCOUNT_KEYS=$(aws secretsmanager get-secret-value --secret-id IAM_KEYS | jq -rc '.SecretString')
# AWS_ACCESS_KEY_ID=$(echo ${ACCOUNT_KEYS} | jq -rc ".${INPUT_NODE_APP_INSTANCE^^}_AWS_SECRET_KEY_ID")
# AWS_SECRET_ACCESS_KEY=$(echo ${ACCOUNT_KEYS} | jq -rc ".${INPUT_NODE_APP_INSTANCE^^}_AWS_SECRET_ACCESS_KEY")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" | sed 's/\"//g')
AWS_PAGER=""
NODE_ENV="${INPUT_NODE_ENV}"

# set -x
cd ${GITHUB_WORKSPACE}/${INPUT_SRC_DIR}

if [[ -z "${INPUT_APP_NAME}" ]]; then # not found
    APP_NAME="${INPUT_REPOSITORY}-${INPUT_NODE_ENV}"
else
    APP_NAME="${INPUT_APP_NAME}"
fi

# zip layer
mkdir nodejs/
mv ./node_modules/ ./nodejs/
zip -9 -Xqyr ${APP_NAME}-layer.zip ./nodejs

# zip code
zip -9 -Xqyr ${GIT_SHA}.zip -@ < ${INPUT_ZIP_INCLUDE}

# Load config variables
if [[ ! -f ./config/${NODE_ENV}.json ]]; then
    CONFIG="default"
fi

_get_latest_layer () {
    echo $(aws lambda list-layer-versions \
        --layer-name ${APP_NAME} \
        --query 'LayerVersions[0].LayerVersionArn' | cut -d'"' -f2)
}

_publish_layer () {
    aws lambda publish-layer-version \
        --layer-name ${APP_NAME} \
        --compatible-runtimes nodejs14.x \
        --zip-file fileb://$(pwd)/${APP_NAME}-layer.zip
}

# checksum for package-lock
SAVED_CHKSUM=$(aws ssm get-parameter \
    --name "/${INPUT_REPOSITORY}/${INPUT_NODE_ENV}/package-lock-chksum" \
    --with-decryption \
    | jq -rc '.Parameter.Value')

if [[ -z "${SAVED_CHKSUM}" ]]; then # not found

    _publish_layer

    aws ssm put-parameter \
        --name "/${INPUT_REPOSITORY}/${INPUT_NODE_ENV}/package-lock-chksum" \
        --value ${INPUT_PACKAGE_LOCK_CHKSUM} \
        --type SecureString

    SAVED_CHKSUM=${INPUT_PACKAGE_LOCK_CHKSUM}

elif [[ ${INPUT_PACKAGE_LOCK_CHKSUM} != ${SAVED_CHKSUM} ]]; then

    _publish_layer

    aws ssm put-parameter \
        --name "/${INPUT_REPOSITORY}/${INPUT_NODE_ENV}/package-lock-chksum" \
        --overwrite \
        --value ${INPUT_PACKAGE_LOCK_CHKSUM} \
        --type SecureString
fi

aws lambda get-function --function-name ${APP_NAME}

if [[ $? -ne 0 ]]; then

    # https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-awscli.html

    cat << EOF >> iam-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "apigateway.amazonaws.com",
          "events.amazonaws.com",
          "lambda.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    aws iam create-role \
        --role-name ${APP_NAME} \
        --assume-role-policy-document file://$(pwd)/iam-trust-policy.json

    aws iam attach-role-policy \
        --role-name ${APP_NAME} \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    sleep 10
    aws lambda create-function \
        --function-name ${APP_NAME} \
        --environment Variables="{NODE_APP_INSTANCE=${INPUT_NODE_APP_INSTANCE},NODE_ENV=${INPUT_NODE_ENV}}" \
        --handler ${INPUT_SRC_HANDLER} \
        --layers $(_get_latest_layer) \
        --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${APP_NAME} \
        --memory-size 128 \
        --runtime 'nodejs14.x' \
        --timeout 30 \
        --zip-file fileb://$(pwd)/${GIT_SHA}.zip

else 
    aws lambda update-function-code \
        --function-name ${APP_NAME} \
        --zip-file fileb://$(pwd)/${GIT_SHA}.zip | jq '
            if .Environment.Variables.INPUT_NODE_ENV? then .Environment.Variables.INPUT_NODE_ENV = "REDACTED" else . end'

    if [[ ${INPUT_PACKAGE_LOCK_CHKSUM} != ${SAVED_CHKSUM} ]]; then

        set -x

        aws lambda update-function-configuration \
            --function-name ${APP_NAME} \
            --handler ${INPUT_SRC_HANDLER}
    fi
fi