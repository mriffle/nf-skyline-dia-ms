#!/usr/bin/env bash 
# 
# get-batch-logs.sh: 
# This script will download the AWS Cloudwatch Logs associated with a Nextflow workflow task
# Usage: 
#   get-batch-logs.sh --taskname <task-name> 
#     -where: 
#       --taskname: is the name of a task in the workflow such as 
#                 skyline_import:SKYLINE_ADD_LIB or encyclopedia_quant:ENCYCLOPEDIA_SEARCH_FILE
#       -l, --logfile: path to the log file for run
# 
# To dos 
# TODO: Add support to scan log file and return logs for all tasks which failed
# TODO: Add support to handle retry attempts
# TODO: Add support for downloading logs for workflow task which finished > 7 days ago. Batch job metadata is removed after 7 days
# TODO: If an AWS Batch job does not get into RUNNABLE state, then the logStream is never created. Add support to handle this scenario
# TODO: Nextflow does not execute AWS Batch for all jobs at once. If the there is a failure early in the workflow run, some will not have been submitted. Add support for this
# TODO: Print out basic information about the AWS Batch job. What was it's final state, etc 
# 

print_usage()
{
    echo "Usage:"
    echo "    get-batch-logs.sh --taskname name [-l logfile] "
    echo ""
    echo "    --taskname name: name of a task in the workflow. For example skyline_import:SKYLINE_ADD_LIB"
    echo "                     or encyclopedia_quant:ENCYCLOPEDIA_SEARCH_FILE "
    echo ""
    echo "    -l logfile: path to the nextflow.log file for the run "
    echo ""
}


# Variables
nextflow_log_path="./.nextflow.log"     # Use the nextflow.log file in the working directory by default


# Parse command line arguments
if [[ -z $1 ]]; then
    print_usage
    exit
fi

while [[ -n $1 ]]
do
    case $1
    in
        --taskname)
        if [ -z $2 ] || [ "$(echo $2 | cut -c1)" = "-" ]; then
            echo "Please specify the task name with the --taskname option. See the Usage text below"
            echo ""
            print_usage
            exit
        fi
        task_name=$2;
        shift 2;;
        -l)
        if [ -z $2 ] || [ "$(echo $2 | cut -c1)" = "-" ]; then
            echo "Please specify a path to the nextflow log file for the run with the -l option. See the Usage text below"
            echo ""
            print_usage
            exit
        fi
        nextflow_log_path=$2;
        shift 2;;
        *)
        echo "Option [$1] not one of  [taskname, l]";
        print_usage
        exit;;
    esac
done


# Validate parameters

echo "Downloading logs for '$task_name' from AWS Batch:"
echo "=================================================="

echo "Verifying inputs and your session..."

if [[ -z $nextflow_log_path ]] || [[ ! -e $nextflow_log_path ]] || [[ ! -f $nextflow_log_path ]]; then
    echo ""
    echo "Nextflow log file, $nextflow_log_path, does not exist.  Please specify correct path on the command line."
    echo ""
    print_usage
    exit 1
else
    echo " - nextflow log file found at $nextflow_log_path"
fi

# Temporary file to hold the log group and stream name
clean_task_name=$(echo "$task_name" | tr " " "_" | tr -d "(" | tr -d ")")
JOB_LOG_INFO=".${clean_task_name}_batch_job_log.json"      # Temporary file to hold the log group and stream name

# Check if JOB_LOG_INFO file exists. If it exists, delete it
if [[ -f $JOB_LOG_INFO ]]; then
    rm $JOB_LOG_INFO
    if [ "$?" -ne 0 ]; then
        echo
        echo "ERROR: Removing Temporary file, $JOB_LOG_INFO has failed"
        exit 1
    fi

    touch $JOB_LOG_INFO
    if [ "$?" -ne 0 ]; then
        echo
        echo "ERROR: Creating Temporary file, $JOB_LOG_INFO has failed"
        exit 1
    fi
fi

# Check that aws cli exists
if [[ ! $(type -P "aws") ]]; then
    echo
    echo "ERROR: AWS cli, aws, cannot be found on your path. The aws cli is required."
    exit 1
else
    echo " - aws cli exists"
fi

# Find if the task_name is in the log file
task_names=$(grep "Submitted process" "$nextflow_log_path" | awk 'BEGIN { FS="Submitted process > " } { print $2 }')

if [[ -z $task_names ]]; then
    echo
    echo "ERROR: There is a problem. The nextflow log file for this run does not show any tasks were started."
    echo " - this script looks for the string 'Submitted process...' in the log file and did not find it"
    exit 1
fi

if [[ ! $task_names =~ "$task_name" ]]; then
    echo
    echo "ERROR: Unable to find the task, '$task_name', in the log file. "
    echo
    echo "The available tasks in the log file are:"
    echo "$task_names"
    echo 
    echo "* note: task names are case sensitive"
    exit 1
else
    echo " - '$task_name' found in the log file."
fi

# Find AWS Batch job id assocated with the task in the nextflow.log file
# read file and find the line with string and return the line above it
submit_logs=$(grep -B 1 "Submitted process > $task_name" $nextflow_log_path)

if [[ -z $submit_logs ]]; then
    echo
    echo "ERROR: There is a problem. The nextflow log file for this run does not show any tasks were started."
    echo "- this script looks for the string 'Submitted process > $task_name' in the log file and did not find it"
    exit 1
elif [[ ! $submit_logs =~ "AWSBatch" ]]; then 
    echo
    echo "ERROR: There is a problem. It appears that the task, '$task_name', was not submitted to AWS Batch."
    echo
    echo "The log entries for submitting this task are:"
    echo "$submit_logs"
    exit 1
elif [[ ! $submit_logs =~ "job=" ]]; then 
    echo
    echo "ERROR: There is a problem. Unable to find the AWS Batch job id for this task"
    echo
    echo "The log entries for submitting this task are:"
    echo "$submit_logs"
    exit 1
else
    job_id=$(echo "$submit_logs" | grep "job=" | awk 'BEGIN { FS="job=" } { print $2 }' | awk 'BEGIN { FS=";" } { print $1 }')
    if [[ -z $job_id ]]; then
        echo 
        echo "ERROR: There is a problem. Unable to find the AWS Batch job id for this task"
        echo
        echo "The log entries for submitting this task are:"
        echo "$submit_logs"
        exit 1
    else
        echo " - AWS Batch job-id is '$job_id'"
    fi
fi


# Download the log events
echo
echo "Downloading log events..."
echo 
# Find Cloudwatch logGroup and logStream for this job
aws batch describe-jobs --jobs $job_id  --query 'jobs[].container.{logStreamName:logStreamName, logGroupName:logConfiguration.options."awslogs-group"} | [0]' \
    --output json --no-cli-pager > "$JOB_LOG_INFO"
if [ "$?" -ne 0 ]; then
    echo
    echo "ERROR: There was problem finding the finding the job in AWS Batch."
    echo "See error messages above and look at '$JOB_LOG_INFO' for more information about the failure"
    exit 1
fi

# Dowload the log events in the logStream
aws logs get-log-events --start-from-head --no-paginate --query 'events[*].message' --cli-input-json "file://${JOB_LOG_INFO}" --output text | tr '\t' '\n'
if [ "$?" -ne 0 ]; then
    echo
    echo "ERROR: There was problem downloading the log events from AWS Batch (CloudWatch)."
    echo "See error messages above for more information about the failure"
    exit 1
fi


# Download was successful. Clean up
rm $JOB_LOG_INFO
echo
echo "Log entries successfully downloaded"
