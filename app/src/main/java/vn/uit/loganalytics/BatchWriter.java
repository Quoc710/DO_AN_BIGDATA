package vn.uit.loganalytics;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.BatchPreparedStatementSetter;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Baseline ghi theo lô (group commit).
 * Mỗi request vẫn chỉ được trả lời SAU KHI dòng của nó đã ghi xong vào PostgreSQL,
 * giống baseline ghi từng dòng. Khác ở chỗ: các log đến gần như cùng lúc được gom lại
 * và ghi bằng 1 lệnh (tối đa batch.max-size dòng).
 * Không có thời gian chờ cố ý: writer lấy hết những gì đang có trong hàng đợi rồi ghi ngay.
 * Tải thấp thì mỗi lô chỉ 1 vài dòng (độ trễ thấp), tải cao thì lô tự to lên.
 */
@Component
public class BatchWriter {

    private static final String INSERT_SQL =
            "INSERT INTO app_log (run_id, log_id, service_id, level, message, sent_ts) VALUES (?, ?, ?, ?, ?, ?)";

    /** Một log đang chờ ghi, kèm "lời hứa" để báo lại cho request khi ghi xong. */
    record Pending(LogRequest log, CompletableFuture<Boolean> done) {
    }

    private final JdbcTemplate jdbc;
    private final BlockingQueue<Pending> queue;
    private final int maxBatch;
    private final AtomicLong batches = new AtomicLong();
    private final AtomicLong rows = new AtomicLong();

    public BatchWriter(JdbcTemplate jdbc,
                       @Value("${batch.max-size:100}") int maxBatch,
                       @Value("${batch.writers:4}") int writers,
                       @Value("${batch.queue-capacity:20000}") int queueCapacity) {
        this.jdbc = jdbc;
        this.maxBatch = maxBatch;
        this.queue = new ArrayBlockingQueue<>(queueCapacity);
        for (int i = 0; i < writers; i++) {
            Thread t = new Thread(this::writeLoop, "batch-writer-" + i);
            t.setDaemon(true);
            t.start();
        }
    }

    /** Đưa 1 log vào hàng đợi. Trả về false ngay nếu hàng đợi đầy (quá tải). */
    public CompletableFuture<Boolean> submit(LogRequest log) {
        CompletableFuture<Boolean> done = new CompletableFuture<>();
        if (!queue.offer(new Pending(log, done))) {
            done.complete(false);
        }
        return done;
    }

    private void writeLoop() {
        List<Pending> batch = new ArrayList<>(maxBatch);
        while (true) {
            batch.clear();
            try {
                batch.add(queue.take());                 // chờ có ít nhất 1 log
                queue.drainTo(batch, maxBatch - 1);      // lấy thêm những log đang chờ sẵn
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
            try {
                jdbc.batchUpdate(INSERT_SQL, new BatchPreparedStatementSetter() {
                    @Override
                    public void setValues(PreparedStatement ps, int i) throws SQLException {
                        LogRequest r = batch.get(i).log();
                        ps.setString(1, r.runId());
                        ps.setLong(2, r.logId());
                        ps.setString(3, r.serviceId());
                        ps.setString(4, r.level());
                        ps.setString(5, r.message());
                        ps.setLong(6, r.sentTs());
                    }

                    @Override
                    public int getBatchSize() {
                        return batch.size();
                    }
                });
                batches.incrementAndGet();
                rows.addAndGet(batch.size());
                for (Pending p : batch) p.done().complete(true);
            } catch (Exception e) {
                for (Pending p : batch) p.done().completeExceptionally(e);
            }
        }
    }

    public long batches() {
        return batches.get();
    }

    public long rows() {
        return rows.get();
    }
}
