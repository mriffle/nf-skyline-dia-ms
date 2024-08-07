SECRET_ID   = 'SKYLINE_DIA_MS_SECRETS'
SECRET_NAME = 'PANORAMA_API_KEY'
REGION = 'us-west-2'

process BUILD_AWS_SECRETS {
    label 'process_low_constant'
    secret 'PANORAMA_API_KEY'
    executor 'local'    // always run this locally
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'

    output:
        path("aws-setup-secrets.stderr"), emit: stderr
        path("aws-setup-secrets.stdout"), emit: stdout

    script:

        """
        # Check if the secret already exists
        SECRET_EXISTS=\$(aws secretsmanager list-secrets --region ${REGION} --query "SecretList[?Name=='${SECRET_ID}'].Name" --output text)
        SECRET_STRING='{"${SECRET_NAME}":"\$PANORAMA_API_KEY"}'
        
        if [ "\$SECRET_EXISTS" == "${SECRET_ID}" ]; then
            echo "Secret with name '${SECRET_ID}' already exists. Checking the value."

            # Retrieve the existing secret value

            EXISTING_SECRET=\$(aws secretsmanager get-secret-value --secret-id ${SECRET_ID} --region ${REGION} --query 'SecretString' --output text)

            if [ "\$EXISTING_SECRET" == "\$SECRET_STRING" ]; then
                echo "The existing secret value is the same. No update needed."
                touch aws-setup-secrets.stderr
                touch aws-setup-secrets.stdout
            else
                echo "The existing secret value is different. Updating the secret."

                aws secretsmanager update-secret \
                    --secret-id ${SECRET_ID} \
                    --secret-string \$SECRET_STRING \
                    --region ${REGION} \
                    > >(tee "aws-setup-secrets.stdout") 2> >(tee "aws-setup-secrets.stderr" >&2)

                echo "Secret '${SECRET_ID}' updated successfully."
            fi
        else
            echo "Secret with name '${SECRET_ID}' does not exist. Creating the secret."

            aws secretsmanager create-secret \
                --name ${SECRET_ID} \
                --secret-string \$SECRET_STRING \
                --region ${REGION} \
                > >(tee "aws-setup-secrets.stdout") 2> >(tee "aws-setup-secrets.stderr" >&2)

            echo "Secret '${SECRET_ID}' created successfully."
        fi
        """
    stub:
        """
        touch aws-setup-secrets.stderr
        touch aws-setup-secrets.stdout
        """
}

process DESTROY_AWS_SECRETS {
    label 'process_low_constant'
    executor 'local'    // always run this locally
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'

    output:
        path("aws-destroy-secrets.stderr"), emit: stderr
        path("aws-destroy-secrets.stdout"), emit: stdout

    script:

        """
        aws secretsmanager delete-secret \
        --secret-id ${SECRET_ID} \
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