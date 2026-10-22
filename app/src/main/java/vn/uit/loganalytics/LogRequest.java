package vn.uit.loganalytics;

/** Một log gửi tới API. JSON dạng snake_case: run_id, log_id, service_id, level, message, sent_ts. */
public record LogRequest(String runId, Long logId, String serviceId, String level, String message, Long sentTs) {
}
