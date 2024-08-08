import java.security.SecureRandom

/*
 Generate a 50 character random string that begins with NF_ to use
 as the generated secret id for this nextflow run
*/
def generateRandomSecretId() {
    String charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_'
    SecureRandom random = new SecureRandom()
    StringBuilder sb = new StringBuilder("NF_")

    (1..47).each {
        sb.append(charset.charAt(random.nextInt(charset.length())))
    }

    return sb.toString()
}

SECRET_NAME = 'PANORAMA_API_KEY'
REGION = 'us-west-2'

// define this as a separate process so it can be cached
process CREATE_AWS_SECRET_ID {
    executor 'local'

    output:
        val aws_secret_id
    
    exec:
        aws_secret_id = generateRandomSecretId()
}

process BUILD_AWS_SECRETS {
    label 'process_low_constant'
    secret 'PANORAMA_API_KEY'
    executor 'local'    // always run this locally
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'
    cache false

    input:
        val secret_id

    output:
        path("aws-setup-secrets.stderr"), emit: stderr
        path("aws-setup-secrets.stdout"), emit: stdout
        val aws_secret_id

    script:
        aws_secret_id = secret_id

        """
        # Check if the secret already exists
        SECRET_EXISTS=\$(aws secretsmanager list-secrets --region ${REGION} --query "SecretList[?Name=='${secret_id}'].Name" --output text)
        SECRET_STRING='{"${SECRET_NAME}":"$PANORAMA_API_KEY"}'

        echo "SECRET_EXISTS: \$SECRET_EXISTS"
        echo "SECRET_STRING: \$SECRET_STRING"
        echo "PANORAMA_API_KEY: \$PANORAMA_API_KEY"
        
        if [ "\$SECRET_EXISTS" == "${secret_id}" ]; then
            echo "Secret with name '${secret_id}' already exists. Checking the value."

            # Retrieve the existing secret value

            EXISTING_SECRET=\$(aws secretsmanager get-secret-value --secret-id ${secret_id} --region ${REGION} --query 'SecretString' --output text)
            echo "EXISTING_SECRET: \$EXISTING_SECRET"
            
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