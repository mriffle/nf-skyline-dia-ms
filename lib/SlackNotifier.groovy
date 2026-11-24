//
// Optional Slack notifications when a run starts and when it ends.
//
// Messages are posted to a Slack incoming webhook. The webhook URL is a credential, so it is
// read from the Nextflow secret SLACK_WEBHOOK_URL and never from params: the config file a
// user passes with -c is uploaded to Panorama as-is.
//
// The one rule this class exists to keep: a Slack problem must never fail or stall a run.
// Nothing here throws, every network call is time-bounded, and every problem is reported as
// a returned warning string for the caller to log. No warning ever contains the webhook URL
// or an exception message, because exception messages can include the URL.
//

import groovy.json.JsonOutput
import java.time.Duration
import java.time.OffsetDateTime
import java.time.temporal.Temporal
import java.util.concurrent.atomic.AtomicBoolean

class SlackNotifier {

    static final String SECRET_NAME = 'SLACK_WEBHOOK_URL'

    // Connect and read timeouts for the POST.
    private static final int TIMEOUT_MS = 5000

    // Ceiling on one notification. The socket timeouts above do not cover name resolution,
    // so the POST runs on a daemon thread that is abandoned after this long.
    private static final int HARD_LIMIT_MS = 15000

    private static final int MAX_ERROR_CHARS = 1500

    // Set once the start point is reached, whether or not the start message could be sent.
    private static final AtomicBoolean started = new AtomicBoolean(false)

    // onComplete and onError can both fire for one failure; only the first sends.
    private static final AtomicBoolean endClaimed = new AtomicBoolean(false)

    // A missing or malformed secret is reported once per run, not once per message.
    private static final AtomicBoolean configProblemReported = new AtomicBoolean(false)

    //
    // Send the notification for one stage of the run.
    //
    // stage is one of:
    //   'start'    - the workflow was constructed without error and is about to run
    //   'complete' - workflow.onComplete fired (success or failure)
    //   'error'    - workflow.onError fired
    //
    // onError fires at the first error, but with the 'finish' error strategy the run can go
    // on for a long time afterwards, so the end message normally waits for onComplete. The
    // exception is a failure before the start point: Nextflow versions before 25 do not fire
    // onComplete for those, so onError reports them.
    //
    // Returns null when there is nothing to report, otherwise a warning for the caller to log.
    //
    static String notify(String stage, workflow, String webhookUrl) {
        try {
            String text
            if (stage == 'start') {
                started.set(true)
                text = startText(workflow)
            } else if (stage == 'complete' || stage == 'error') {
                if (stage == 'error' && started.get()) {
                    return null
                }
                if (!endClaimed.compareAndSet(false, true)) {
                    return null
                }
                text = endText(workflow, stage == 'error')
            } else {
                return null
            }

            URI uri = null
            String problem = null
            if (webhookUrl == null || webhookUrl.trim().isEmpty()) {
                problem = "Parameter `slack.enabled` is true but the Nextflow secret ${SECRET_NAME} is not set. " +
                          "Run `nextflow secrets set ${SECRET_NAME} '<your webhook URL>'` on the machine that " +
                          "launches Nextflow. Continuing without Slack notifications."
            } else {
                uri = parseWebhookUrl(webhookUrl)
                if (uri == null) {
                    problem = "The Nextflow secret ${SECRET_NAME} is not a valid https URL. " +
                              "Continuing without Slack notifications."
                }
            }
            if (problem != null) {
                return configProblemReported.compareAndSet(false, true) ? problem : null
            }

            String reason = post(uri, text)
            if (reason == null) {
                return null
            }
            String label = (stage == 'start') ? 'start' : 'end'
            return "Slack notification (${label}) was not sent: ${reason}. The workflow is not affected."
        } catch (Throwable t) {
            return "Slack notification was not sent: ${t.getClass().simpleName}. The workflow is not affected."
        }
    }

    // Returns the parsed URL, or null if it is not an absolute https URL.
    private static URI parseWebhookUrl(String value) {
        try {
            URI uri = new URI(value.trim())
            if (!'https'.equalsIgnoreCase(uri.scheme) || !uri.host) {
                return null
            }
            uri.toURL()
            return uri
        } catch (Throwable ignored) {
            return null
        }
    }

    // POST the message. Returns null on success, otherwise a short reason that is safe to log.
    private static String post(URI uri, String text) {
        String[] result = ["no response within ${HARD_LIMIT_MS.intdiv(1000)} seconds".toString()]
        Thread worker = new Thread({ result[0] = doPost(uri, text) } as Runnable, 'slack-notify')
        worker.daemon = true
        worker.start()
        worker.join(HARD_LIMIT_MS)
        return result[0]
    }

    private static String doPost(URI uri, String text) {
        HttpURLConnection conn = null
        try {
            conn = (HttpURLConnection) uri.toURL().openConnection()
            conn.setConnectTimeout(TIMEOUT_MS)
            conn.setReadTimeout(TIMEOUT_MS)
            conn.setInstanceFollowRedirects(false)
            conn.setRequestMethod('POST')
            conn.setDoOutput(true)
            conn.setRequestProperty('Content-Type', 'application/json; charset=utf-8')
            byte[] body = JsonOutput.toJson([text: text]).getBytes('UTF-8')
            conn.outputStream.withCloseable { it.write(body) }
            int code = conn.responseCode
            return (code >= 200 && code < 300) ? null : "Slack answered HTTP ${code}".toString()
        } catch (Throwable t) {
            return "could not reach Slack (${t.getClass().simpleName})".toString()
        } finally {
            try {
                conn?.disconnect()
            } catch (Throwable ignored) {
                // nothing useful to do
            }
        }
    }

    static String startText(workflow) {
        return ":arrow_forward: *${pipelineName(workflow)} started*\n${runContext(workflow)}".toString()
    }

    static String endText(workflow, boolean forceFailed = false) {
        boolean success = !forceFailed && field('false') { workflow.success } == 'true'
        String elapsed = elapsedSince(workflow)
        String name = pipelineName(workflow)
        if (success) {
            String took = elapsed ? " in ${elapsed}" : ''
            return ":white_check_mark: *${name} completed*${took}\n${runContext(workflow)}".toString()
        }
        String took = elapsed ? " after ${elapsed}" : ''
        String message = ":x: *${name} failed*${took}\n${runContext(workflow)}"
        String detail = errorDetail(workflow)
        if (detail) {
            message += "\n```\n${detail}\n```"
        }
        return message.toString()
    }

    private static String pipelineName(workflow) {
        return escape(field('nf-skyline-dia-ms') { workflow.manifest.name })
    }

    private static String runContext(workflow) {
        String run = inlineCode(field('unknown') { workflow.runName })
        String user = field('unknown') { workflow.userName }
        String host = field('unknown') { InetAddress.localHost.hostName }
        String dir = inlineCode(field('unknown') { workflow.launchDir })
        return "Run: ${run}  ·  ${escape(user)}@${escape(host)}\nLaunch directory: ${dir}".toString()
    }

    // workflow.errorMessage is empty for a failed task; the detail is in errorReport.
    private static String errorDetail(workflow) {
        String detail = field('') { workflow.errorMessage } ?: field('') { workflow.errorReport }
        detail = detail.replaceAll(/\u001B\[[;\d]*[A-Za-z]/, '').trim()
        if (!detail) {
            return ''
        }
        if (detail.length() > MAX_ERROR_CHARS) {
            detail = detail.substring(0, MAX_ERROR_CHARS) + '\n... (truncated)'
        }
        return escape(detail.replace('```', "'''"))
    }

    // Time since the run started. Computed here rather than read from workflow.duration,
    // which is not set yet when onError fires.
    private static String elapsedSince(workflow) {
        try {
            def start = workflow.start
            long seconds
            if (start instanceof Temporal) {
                seconds = Duration.between((Temporal) start, OffsetDateTime.now()).seconds
            } else if (start instanceof Date) {
                seconds = ((System.currentTimeMillis() - ((Date) start).time) / 1000) as long
            } else {
                return ''
            }
            return formatSeconds(Math.max(0L, seconds))
        } catch (Throwable ignored) {
            return ''
        }
    }

    static String formatSeconds(long total) {
        long hours = total.intdiv(3600)
        long minutes = (total % 3600).intdiv(60)
        long seconds = total % 60
        if (hours > 0) {
            return "${hours}h ${minutes}m".toString()
        }
        if (minutes > 0) {
            return "${minutes}m ${seconds}s".toString()
        }
        return "${seconds}s".toString()
    }

    // Read one value for the message; a missing or unreadable value must not lose the message.
    private static String field(String fallback, Closure reader) {
        try {
            def value = reader.call()
            String text = value == null ? '' : value.toString()
            return text ?: fallback
        } catch (Throwable ignored) {
            return fallback
        }
    }

    // Slack treats &, < and > as control characters in message text.
    private static String escape(String value) {
        return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    }

    private static String inlineCode(String value) {
        return '`' + escape(value.replace('`', "'")) + '`'
    }
}
