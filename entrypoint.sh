#!/bin/sh -l

set +e
set -x

IAM_ARN=$(aws sts get-caller-identity --query "Arn" | sed 's/\"//g')

env
pwd
ls -la
echo $@
echo "::set-output name=AWS_ACCOUNT_ID::${IAM_ARN##*\/}"

ls -la ${GITHUB_WORKSPACE}
exit 0

APP_NAME="${REPO_NAME}-${NODE_ENV}" # follow this convention everywhere...

ACCOUNT_KEYS=$(aws secretsmanager get-secret-value --secret-id IAM_KEYS | jq -rc '.SecretString')
AWS_ACCESS_KEY_ID=$(echo ${ACCOUNT_KEYS} | jq -rc ".${NODE_APP_INSTANCE^^}_AWS_SECRET_KEY_ID")
AWS_SECRET_ACCESS_KEY=$(echo ${ACCOUNT_KEYS} | jq -rc ".${NODE_APP_INSTANCE^^}_AWS_SECRET_ACCESS_KEY")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" | sed 's/\"//g')
AWS_PAGER=""
CONFIG="${NODE_ENV}"


# zip layer
mkdir nodejs/
mv ./node_modules/ ./nodejs/
zip -9 -Xqyr ${APP_NAME}-layer.zip ./nodejs

# zip code
zip -9 -Xqyr ${GIT_SHA}.zip -@ < .sls-include

# Load config variables
if [[ ! -f ./config/${CONFIG}.json ]]; then
    CONFIG="default"
fi

# jq --color-output . ./config/${CONFIG}.json

_get_config () {
    # not sure how to swap the fallback value...
    echo $(jq -rc --arg ARG "$1" '.$ARG // "nodejs14.x"' ./config/${CONFIG}.json)
}

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
    --name "/${REPO_NAME}/${NODE_ENV}/package-lock-chksum" \
    --with-decryption \
    | jq -rc '.Parameter.Value')

if [[ -z "${SAVED_CHKSUM}" ]]; then # not found

    _publish_layer

    aws ssm put-parameter \
        --name "/${REPO_NAME}/${NODE_ENV}/package-lock-chksum" \
        --value ${CHKSUM} \
        --type SecureString

    SAVED_CHKSUM=${CHKSUM}

elif [[ ${CHKSUM} != ${SAVED_CHKSUM} ]]; then

    _publish_layer

    aws ssm put-parameter \
        --name "/${REPO_NAME}/${NODE_ENV}/package-lock-chksum" \
        --overwrite \
        --value ${CHKSUM} \
        --type SecureString
fi

aws lambda get-function --function-name ${APP_NAME}

if [[ $? -ne 0 ]]; then

    # https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-awscli.html

    aws iam create-role \
        --role-name ${APP_NAME} \
        --assume-role-policy-document file://$(pwd)/deployment/iam-trust-policy.json
    aws iam attach-role-policy \
        --role-name ${APP_NAME} \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    sleep 10
    aws lambda create-function \
        --function-name ${APP_NAME} \
        --environment Variables="{NODE_APP_INSTANCE=${NODE_APP_INSTANCE},NODE_ENV=${NODE_ENV}}" \
        --handler handler.hello \
        --layers $(_get_latest_layer) \
        --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${APP_NAME} \
        --memory-size $(jq -rc '.memorySize // 128' ./config/${CONFIG}.json) \
        --runtime $(jq -rc '.runtime // "nodejs14.x"' ./config/${CONFIG}.json) \
        --timeout $(jq -rc '.timeout // 3' ./config/${CONFIG}.json) \
        --zip-file fileb://$(pwd)/${GIT_SHA}.zip

else 
    aws lambda update-function-code \
        --function-name ${APP_NAME} \
        --zip-file fileb://$(pwd)/${GIT_SHA}.zip | jq '
            if .Environment.Variables.NODE_ENV? then .Environment.Variables.NODE_ENV = "REDACTED" else . end'

    if [[ ${CHKSUM} != ${SAVED_CHKSUM} ]]; then

        aws lambda update-function-configuration \
            --function-name ${APP_NAME} \
            --layers $(_get_latest_layer) \
            --memory-size $(jq -rc '.memorySize // 128' ./config/${CONFIG}.json) \
            --runtime $(jq -rc '.runtime // "nodejs14.x"' ./config/${CONFIG}.json) \
            --timeout $(jq -rc '.timeout // 3' ./config/${CONFIG}.json)
    fi
fi