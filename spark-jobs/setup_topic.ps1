$ErrorActionPreference = "Stop"
$topic = "logs"
$partitions = 2
$describe = docker exec la-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic $topic 2>&1
if ($LASTEXITCODE -ne 0) {
    docker exec la-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic $topic --partitions $partitions --replication-factor 1
    if ($LASTEXITCODE -ne 0) { throw "Could not create Kafka topic $topic" }
    Write-Host "Created topic $topic with $partitions partitions."
} else {
    $match = [regex]::Match(($describe -join " "), 'PartitionCount:\s*(\d+)')
    if (-not $match.Success) { throw "Could not read partition count: $describe" }
    $current = [int]$match.Groups[1].Value
    if ($current -lt $partitions) {
        docker exec la-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --alter --topic $topic --partitions $partitions
        if ($LASTEXITCODE -ne 0) { throw "Could not expand Kafka topic $topic" }
        Write-Host "Expanded topic $topic from $current to $partitions partitions."
    } else { Write-Host "Topic $topic already has $current partitions." }
}
