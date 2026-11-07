package vn.uit.loganalytics;

import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.beans.factory.annotation.Value;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.concurrent.CompletableFuture;

@RestController
public class LogController {

    private static final String INSERT_SQL =
            "INSERT INTO app_log (run_id, log_id, service_id, level, message, sent_ts) VALUES (?, ?, ?, ?, ?, ?)";

    private final JdbcTemplate jdbc;
    private final BatchWriter batchWriter;
    private final KafkaTemplate<String, String> kafka;
    private final ObjectMapper mapper;
    private final String topic;

    public LogController(JdbcTemplate jdbc, BatchWriter batchWriter, KafkaTemplate<String, String> kafka, ObjectMapper mapper,
                         @Value("${pipeline.kafka.topic:logs}") String topic) {
        this.jdbc = jdbc;
        this.batchWriter = batchWriter;
        this.kafka = kafka;
        this.mapper = mapper;
        this.topic = topic;
    }

    private static boolean invalid(LogRequest r) {
        return r.runId() == null || r.logId() == null || r.sentTs() == null
                || r.serviceId() == null || r.level() == null || r.message() == null;
    }

    /** Baseline: mỗi request ghi thẳng 1 dòng vào PostgreSQL, ghi xong mới trả lời. */
    @PostMapping("/logs")
    public ResponseEntity<Void> ingest(@RequestBody LogRequest r) {
        if (invalid(r)) {
            return ResponseEntity.badRequest().build();
        }
        try {
            jdbc.update(INSERT_SQL, r.runId(), r.logId(), r.serviceId(), r.level(), r.message(), r.sentTs());
        } catch (DuplicateKeyException e) {
            return ResponseEntity.status(HttpStatus.CONFLICT).build();
        }
        return ResponseEntity.status(HttpStatus.CREATED).build();
    }

    /** Pipeline: 202 chỉ sau khi Kafka broker xác nhận đã nhận bản ghi. */
    @PostMapping("/logs-kafka")
    public CompletableFuture<ResponseEntity<Void>> ingestKafka(@RequestBody LogRequest r) {
        if (invalid(r)) return CompletableFuture.completedFuture(ResponseEntity.badRequest().<Void>build());
        try {
            String value = mapper.writeValueAsString(r);
            return kafka.send(topic, r.runId() + ":" + r.logId(), value)
                    .<ResponseEntity<Void>>handle((result, err) -> err == null
                            ? ResponseEntity.accepted().build()
                            : ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build());
        } catch (Exception e) {
            return CompletableFuture.completedFuture(ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).build());
        }
    }

    /**
     * Baseline ghi theo lô: gom log đến gần nhau rồi ghi chung vào PostgreSQL.
     * Chỉ trả 201 sau khi đã ghi xong; hàng đợi đầy thì trả 503.
     */
    @PostMapping("/logs-batch")
    public CompletableFuture<ResponseEntity<Void>> ingestBatch(@RequestBody LogRequest r) {
        if (invalid(r)) {
            return CompletableFuture.completedFuture(ResponseEntity.badRequest().<Void>build());
        }
        return batchWriter.submit(r).<ResponseEntity<Void>>handle((ok, err) -> {
            if (err != null) return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).build();
            if (!ok) return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
            return ResponseEntity.status(HttpStatus.CREATED).build();
        });
    }

    /** Tổng số lô và số dòng đã ghi theo lô, để tính kích thước lô trung bình. */
    @GetMapping("/batch-stats")
    public Map<String, Long> batchStats() {
        return Map.of("batches", batchWriter.batches(), "rows", batchWriter.rows());
    }

    /** Không ghi DB. Chỉ dùng để kiểm tra máy bắn tải có bắn kịp tốc độ đặt hay không. */
    @PostMapping("/noop")
    public ResponseEntity<Void> noop(@RequestBody LogRequest r) {
        return ResponseEntity.status(HttpStatus.CREATED).build();
    }

    /** Giờ của PostgreSQL (epoch ms). Bộ bắn tải gọi để chỉnh lệch đồng hồ trước khi chạy. */
    @GetMapping("/clock")
    public Map<String, Long> clock() {
        Long ms = jdbc.queryForObject(
                "SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint", Long.class);
        return Map.of("db_ms", ms);
    }
}
