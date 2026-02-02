#!/usr/bin/env bash
set -euo pipefail

# 配置
SSD_ADDR="${SSD_ADDR:-http://localhost:9428}"
HDD_ADDR="${HDD_ADDR:-http://localhost:9438}"
SSD_DATA="${SSD_DATA:-./data/vl-ssd}"
HDD_DATA="${HDD_DATA:-./data/vl-hdd}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-victorialogs}"
TENANT="${TENANT:-default}"
TABLE="${TABLE:-logs}"

# 工具选择：使用 docker 运行 aws-cli（避免本机安装）
AWS_CLI() {
  docker run --rm -i \
    -e AWS_REGION="${AWS_REGION:-ap-southeast-1}" \
    -v "$PWD:/work" -w /work \
    -v "${HOME}/.aws:/root/.aws" \
    amazon/aws-cli:2.15.18 "$@"
}

is_yyyymmdd() {
  [[ "$1" =~ ^[0-9]{8}$ ]]
}

days_ago_yyyymmdd() {
  date -v-"$1"d +"%Y%m%d"
}

snapshot_partition() {
  local addr="$1" prefix="$2"
  curl -fsS "${addr}/internal/partition/snapshot/create?partition_prefix=${prefix}" >/dev/null
}

detach_partition() {
  local addr="$1" name="$2"
  curl -fsS "${addr}/internal/partition/detach?name=${name}" >/dev/null
}

attach_partition() {
  local addr="$1" name="$2"
  curl -fsS "${addr}/internal/partition/attach?name=${name}" >/dev/null
}

rsync_partition() {
  local src="$1" dst="$2"
  rsync -a --delete-excluded --mkpath "${src}" "${dst}"
}

migrate_nvme_to_hdd() {
  local part="$1"
  echo "[NVMe->HDD] partition=${part}"
  snapshot_partition "${SSD_ADDR}" "${part}"
  rsync_partition "${SSD_DATA}/partitions/${part}" "${HDD_DATA}/partitions/"
  attach_partition "${HDD_ADDR}" "${part}"
  detach_partition "${SSD_ADDR}" "${part}"
  rm -rf "${SSD_DATA}/partitions/${part}"
  echo "done."
}

archive_hdd_to_s3() {
  local part="$1"
  echo "[HDD->S3] partition=${part}"
  snapshot_partition "${HDD_ADDR}" "${part}"
  local s3="s3://${S3_BUCKET}/${S3_PREFIX}/${TENANT}/${TABLE}/${part:0:4}/${part:4:2}/${part}"
  AWS_CLI s3 sync "${HDD_DATA}/partitions/${part}" "${s3}" --no-progress
  detach_partition "${HDD_ADDR}" "${part}"
  echo "uploaded to ${s3}"
}

main() {
  local seven_days="$(days_ago_yyyymmdd 7)"
  local one_eighty_days="$(days_ago_yyyymmdd 180)"

  echo "SSD_DATA=${SSD_DATA} HDD_DATA=${HDD_DATA}"
  echo "SSD_ADDR=${SSD_ADDR} HDD_ADDR=${HDD_ADDR}"
  echo "S3_BUCKET=${S3_BUCKET} S3_PREFIX=${S3_PREFIX}"

  # 迁移：<= now-7d 的分区，从 NVMe 到 HDD
  for d in $(ls -1 "${SSD_DATA}/partitions" 2>/dev/null || true); do
    if is_yyyymmdd "${d}" && [[ "${d}" -le "${seven_days}" ]]; then
      migrate_nvme_to_hdd "${d}"
    fi
  done

  # 归档：<= now-180d 的分区，从 HDD 到 S3
  if [[ -n "${S3_BUCKET}" ]]; then
    for d in $(ls -1 "${HDD_DATA}/partitions" 2>/dev/null || true); do
      if is_yyyymmdd "${d}" && [[ "${d}" -le "${one_eighty_days}" ]]; then
        archive_hdd_to_s3 "${d}"
      fi
    done
  else
    echo "S3_BUCKET 未设置，跳过归档。"
  fi
}

main "$@"
