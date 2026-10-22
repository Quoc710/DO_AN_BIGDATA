import java.io.BufferedReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;
import java.util.concurrent.locks.LockSupport;
import java.util.zip.GZIPInputStream;

/**
 * Bo ban tai cho baseline. Chay thang khong can build (JDK 17 tro len):
 *
 *   java LoadGen.java --file apache_500k.jsonl.gz --rate 1000 --run-id pg-1000
 *
 * Tham so:
 *   --url          dia chi app (mac dinh http://localhost:8080)
 *   --file         file dataset JSONL, doc duoc ca file nen .jsonl.gz (bat buoc)
 *   --rate         so log moi giay (bat buoc)
 *   --run-id       nhan lan chay, vd pg-1000 (bat buoc, moi lan chay mot nhan moi)
 *   --duration     so giay ban tai (mac dinh 90 = 30 giay khoi dong + 60 giay do)
 *   --workers      so luong gui song song toi da (mac dinh 400)
 *   --path         /logs (mac dinh, ghi vao DB) hoac /noop (chi kiem tra may ban tai, khong ghi DB)
 *   --timeout-ms   qua thoi gian nay coi la loi (mac dinh 10000)
 *   --sync-clock   true = cong do lech dong ho do qua /clock vao sent_ts (mac dinh false, chi in ra)
 *
 * Cach hoat dong:
 *   - Ban deu theo nhip dong ho, khong cho request truoc tra loi (open-loop),
 *     nen khi he thong cham, tai van giu dung muc da dat. Neu ca --workers luong
 *     deu dang cho tra loi thi log den luot bi bo qua va tinh la mat.
 *   - log_id dem lai tu 1 moi lan chay. Het file thi doc lai tu dau.
 *   - sent_ts gan dung luc gui. Do lech dong ho so voi PostgreSQL (do qua /clock) chi duoc
 *     in ra va ghi vao results.csv; chi cong vao sent_ts khi co --sync-clock true.
 *   - Cuoi lan chay in tong ket va ghi them 1 dong vao results.csv.
 */
public class LoadGen {

    public static void main(String[] args) throws Exception {
        Map<String, String> a = parseArgs(args);
        String url = a.getOrDefault("url", "http://localhost:8080");
        String file = require(a, "file");
        int rate = Integer.parseInt(require(a, "rate"));
        String runId = require(a, "run-id");
        int duration = Integer.parseInt(a.getOrDefault("duration", "90"));
        int workers = Integer.parseInt(a.getOrDefault("workers", "400"));
        String path = a.getOrDefault("path", "/logs");
        int timeoutMs = Integer.parseInt(a.getOrDefault("timeout-ms", "10000"));

        List<String> tails = loadTails(Path.of(file));
        System.out.printf("Da doc %,d dong tu %s%n", tails.size(), file);

        HttpClient client = HttpClient.newBuilder()
                .version(HttpClient.Version.HTTP_1_1)
                .connectTimeout(Duration.ofSeconds(5))
                .build();

        long[] clk = clockOffset(client, url);
        long measured = clk[0], rtt = clk[1];
        // Chi chinh khi do lech lon hon sai so do (= thoi gian 1 vong goi), tranh tu tao ra sai lech.
        // Mac dinh KHONG chinh: Docker Desktop dung chung dong ho voi may that, do lech do duoc thuong la nhieu.
        // Lan chay dai 22/10 do nham -61 ms va lam do tre bi cong sai ~61 ms. Muon chinh thi them --sync-clock true.
        boolean sync = Boolean.parseBoolean(a.getOrDefault("sync-clock", "false"));
        long offset = (sync && Math.abs(measured) > Math.max(rtt, 2)) ? measured : 0;
        System.out.printf("Lech dong ho so voi PostgreSQL: %d ms (sai so do %d ms) -> cong vao sent_ts: %d ms (--sync-clock)%n",
                measured, rtt, offset);

        long total = (long) rate * duration;
        System.out.printf("Bat dau run_id=%s: %,d log/s trong %d giay = %,d log%n", runId, rate, duration, total);

        URI logsUri = URI.create(url + path);
        AtomicLong ok = new AtomicLong(), failed = new AtomicLong(), conflict = new AtomicLong(), sent = new AtomicLong();
        AtomicInteger busy = new AtomicInteger();
        Map<String, LongAdder> errors = new ConcurrentHashMap<>();   // loai loi -> so lan
        // Hang cho nho giua bo dieu phoi va cac worker. Day hang = tat ca worker dang ban -> bo qua log do.
        BlockingQueue<Long> queue = new ArrayBlockingQueue<>(workers);
        final long STOP = -1L;

        Thread[] pool = new Thread[workers];
        for (int w = 0; w < workers; w++) {
            pool[w] = new Thread(() -> {
                try {
                    while (true) {
                        long logId = queue.take();
                        if (logId == STOP) return;
                        busy.incrementAndGet();
                        String tail = tails.get((int) ((logId - 1) % tails.size()));
                        long sentTs = System.currentTimeMillis() + offset;
                        String body = "{\"run_id\":\"" + runId + "\",\"log_id\":" + logId + ",\"sent_ts\":" + sentTs + "," + tail;
                        HttpRequest req = HttpRequest.newBuilder(logsUri)
                                .timeout(Duration.ofMillis(timeoutMs))
                                .header("Content-Type", "application/json")
                                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                                .build();
                        sent.incrementAndGet();
                        try {
                            int code = client.send(req, HttpResponse.BodyHandlers.discarding()).statusCode();
                            if (code / 100 == 2) ok.incrementAndGet();
                            else if (code == 409) conflict.incrementAndGet();
                            else {
                                failed.incrementAndGet();
                                errors.computeIfAbsent("HTTP " + code, k -> new LongAdder()).increment();
                            }
                        } catch (IOException e) {
                            failed.incrementAndGet();
                            errors.computeIfAbsent(e.getClass().getSimpleName(), k -> new LongAdder()).increment();
                        } finally {
                            busy.decrementAndGet();
                        }
                    }
                } catch (InterruptedException ignored) {
                }
            }, "worker-" + w);
            pool[w].start();
        }

        long skipped = 0;
        long start = System.nanoTime();
        long nextReport = start + TimeUnit.SECONDS.toNanos(5);
        long attempted = 0;
        while (attempted < total) {
            long now = System.nanoTime();
            long due = Math.min(total, (now - start) * rate / 1_000_000_000L + 1);
            while (attempted < due) {
                attempted++;
                if (!queue.offer(attempted)) skipped++;   // he thong qua cham, worker nao cung dang cho -> tinh la mat
            }
            if (now >= nextReport) {
                System.out.printf("  %3ds  da gui %,d  ok %,d  loi %,d  bo qua %,d  worker dang ban %,d/%,d%n",
                        TimeUnit.NANOSECONDS.toSeconds(now - start), sent.get(), ok.get(), failed.get(), skipped,
                        busy.get(), workers);
                nextReport += TimeUnit.SECONDS.toNanos(5);
            }
            if (attempted < total) LockSupport.parkNanos(200_000);
        }
        double sendSecs = (System.nanoTime() - start) / 1e9;

        // cho cac request con do tra loi xong
        for (int w = 0; w < workers; w++) queue.put(STOP);
        for (Thread t : pool) t.join(timeoutMs + 5000L);

        double actualRate = attempted / sendSecs;
        System.out.println();
        System.out.println("===== TONG KET " + runId + " =====");
        System.out.printf("Tai dat (offered load) : %,d log/s, thuc te ban %,.0f log/s%n", rate, actualRate);
        System.out.printf("Tong so log can gui    : %,d%n", attempted);
        System.out.printf("Gui di / OK / loi      : %,d / %,d / %,d%n", sent.get(), ok.get(), failed.get());
        System.out.printf("Bo qua (qua tai phia gui): %,d   Trung khoa (409): %,d%n", skipped, conflict.get());
        if (!errors.isEmpty()) {
            System.out.print("Cac loai loi           :");
            errors.forEach((k, v) -> System.out.print(" " + k + "=" + v.sum()));
            System.out.println();
        }
        if (actualRate < rate * 0.95) {
            System.out.println("CANH BAO: may ban tai khong ban kip toc do dat, ket qua lan nay khong dung duoc.");
        }
        if (duration < 90) {
            System.out.println("CANH BAO: --duration duoi 90 giay thi metrics.sql khong du 60 giay de do.");
        }

        Path csv = Path.of("results.csv");
        boolean header = !Files.exists(csv);
        try (PrintWriter w = new PrintWriter(new FileWriter(csv.toFile(), StandardCharsets.UTF_8, true))) {
            if (header) w.println("run_id,rate,duration_s,attempted,sent,ok,failed,skipped,conflict,actual_rate,clock_offset_ms");  // clock_offset_ms = muc da cong vao sent_ts
            w.printf("%s,%d,%d,%d,%d,%d,%d,%d,%d,%.1f,%d%n", runId, rate, duration, attempted, sent.get(), ok.get(),
                    failed.get(), skipped, conflict.get(), actualRate, offset);
        }
        System.out.println("Da ghi them 1 dong vao results.csv");
        if (path.equals("/logs")) {
            System.out.println("Lenh tinh so do:");
            System.out.printf("  docker exec -it la-postgres psql -U loguser -d logdb -v run=%s -v rate=%d -f /metrics.sql%n", runId, rate);
        }
        System.exit(0);
    }

    /** Lay phan sau log_id cua moi dong, vd: "service_id": "...", "level": "...", "message": "..."} */
    static List<String> loadTails(Path p) throws IOException {
        List<String> out = new ArrayList<>(500_000);
        InputStream in = Files.newInputStream(p);
        if (p.toString().endsWith(".gz")) in = new GZIPInputStream(in, 1 << 16);   // doc thang file nen .gz
        try (BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty()) continue;
                int i = line.indexOf("\"service_id\"");
                if (i < 0 || !line.endsWith("}")) throw new IOException("Dong khong dung dinh dang: " + line);
                out.add(line.substring(i));
            }
        }
        if (out.isEmpty()) throw new IOException("File rong: " + p);
        return out;
    }

    /** Do lech dong ho: goi /clock 21 lan, lay lan tra loi nhanh nhat. Tra ve {do lech, thoi gian 1 vong}. */
    static long[] clockOffset(HttpClient client, String url) throws Exception {
        HttpRequest req = HttpRequest.newBuilder(URI.create(url + "/clock")).timeout(Duration.ofSeconds(5)).GET().build();
        long bestRtt = Long.MAX_VALUE, bestOffset = 0;
        for (int i = 0; i < 21; i++) {
            long t0 = System.currentTimeMillis();
            HttpResponse<String> resp = client.send(req, HttpResponse.BodyHandlers.ofString());
            long t1 = System.currentTimeMillis();
            if (resp.statusCode() != 200) throw new IllegalStateException("/clock tra ve " + resp.statusCode());
            String b = resp.body().replaceAll("[^0-9]", "");
            long db = Long.parseLong(b);
            if (t1 - t0 < bestRtt) {
                bestRtt = t1 - t0;
                bestOffset = db - (t0 + t1) / 2;
            }
        }
        return new long[]{bestOffset, bestRtt};
    }

    static Map<String, String> parseArgs(String[] args) {
        Map<String, String> m = new HashMap<>();
        for (int i = 0; i + 1 < args.length; i += 2) {
            if (!args[i].startsWith("--")) throw new IllegalArgumentException("Tham so sai: " + args[i]);
            m.put(args[i].substring(2), args[i + 1]);
        }
        return m;
    }

    static String require(Map<String, String> m, String k) {
        String v = m.get(k);
        if (v == null) {
            System.err.println("Thieu tham so --" + k);
            System.err.println("Vi du: java LoadGen.java --file apache_500k.jsonl.gz --rate 1000 --run-id pg-1000");
            System.exit(1);
        }
        return v;
    }
}
