/**
  * Generate a unique string for this user to store the
  * PanoramaWeb API key.
  */
def generateAWSSecretId(aws_user_id) {
    StringBuilder sb = new StringBuilder("NF_")
    sb.append(aws_user_id)
    sb.append("_PANORAMA_KEY")

    return sb.toString()
}

SECRET_NAME = 'PANORAMA_API_KEY'
REGION = params.aws.region

process GET_AWS_USER_ID {
    label 'process_low_constant'
    executor 'local'    // always run this locally
    cache false         // never cache 

    output:
    stdout emit: aws_user_id

    script:
    """
    aws sts get-caller-identity | grep '"Arn"' | sed 's/.*user\\///' | tr -d '",' | tr -d '\n'
    """

    stub:
    """
    echo "STUB_USER_ID"
    """
}

process BUILD_AWS_SECRETS {
    label 'process_low_constant'
    secret 'PANORAMA_API_KEY'
    executor 'local'    // always run this locally
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'
    cache false         // never cache 

    input:
        val aws_user_id
    output:
        path("aws-setup-secrets.stderr"), emit: stderr
        path("aws-setup-secrets.stdout"), emit: stdout
        val secret_id, emit: aws_secret_id

    script:
        secret_id = generateAWSSecretId(aws_user_id)

        """
        # Check if the secret already exists
        SECRET_EXISTS=\$(aws secretsmanager list-secrets --region ${REGION} --query "SecretList[?Name=='${secret_id}'].Name" --output text)
        SECRET_STRING='{"${SECRET_NAME}":"\$PANORAMA_API_KEY"}'

        echo \$PANORAMA_API_KEY
        echo "\$SECRET_STRING"
        
        if [ "\$SECRET_EXISTS" == "${secret_id}" ]; then
            echo "Secret with name '${secret_id}' already exists. Checking the value."

            # Retrieve the existing secret value

            EXISTING_SECRET=\$(aws secretsmanager get-secret-value --secret-id ${secret_id} --region ${REGION} --query 'SecretString' --output text)
            
            if [ "\$EXISTING_SECRET" == "\$SECRET_STRING" ]; then
                echo "The existing secret value is the same. No update needed."
                touch aws-setup-secrets.stderr
                touch aws-setup-secrets.stdout
            else
                echo "The existing secret value is different. Updating the secret."

                aws secretsmanager update-secret \
                    --secret-id ${secret_id} \
                    --secret-string \$SECRET_STRING \
                    --region ${REGION} \
                    > >(tee "aws-setup-secrets.stdout") 2> >(tee "aws-setup-secrets.stderr" >&2)

                echo "Secret '${secret_id}' updated successfully."
            fi
        else
            echo "Secret with name '${secret_id}' does not exist. Creating the secret."

            aws secretsmanager create-secret \
                --name ${secret_id} \
                --secret-string \$SECRET_STRING \
                --region ${REGION} \
                > >(tee "aws-setup-secrets.stdout") 2> >(tee "aws-setup-secrets.stderr" >&2)

            echo "Secret '${secret_id}' created successfully."
        fi
        """
    stub:
        secret_id = 'stub_secret_id'
        """
        touch aws-setup-secrets.stderr
        touch aws-setup-secrets.stdout
        """
}

process DESTROY_AWS_SECRETS {
    label 'process_low_constant'
    executor 'local'    // always run this locally
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'
    cache false

    input:
        val secret_id

    output:
        path("aws-destroy-secrets.stderr"), emit: stderr
        path("aws-destroy-secrets.stdout"), emit: stdout

    script:

        """
        aws secretsmanager delete-secret \
        --secret-id ${secret_id} \
        --region ${REGION} \
        --force-delete-without-recovery \
        > >(tee "aws-destroy-secrets.stdout") 2> >(tee "aws-destroy-secrets.stderr" >&2)
        """
    stub:
        """
        touch aws-destroy-secrets.stderr
        touch aws-destroy-secrets.stdout
        """
}