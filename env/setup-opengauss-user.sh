#!/usr/bin/env bash
# 在 openGauss 实例内建业务用户 / 业务库 / public schema 授权（幂等，可重复执行）。
#
# 为什么必须这一步：
#   1) openGauss 的 omm 禁止远程登录（pg_hba 虽放行 md5，但 omm 本身不允许远程登录），
#      驱动侧只能以普通业务账号走 TCP 连进来 —— 账号必须先在实例内建好；
#   2) openGauss 每个库的 public schema 属 omm，普通用户默认只有 USAGE 没有 CREATE，
#      不显式授权的话，业务用户 CREATE TABLE 直接 42501（permission denied for schema）。
#
# 用法：
#   env/setup-opengauss-user.sh                    # 容器模式（默认）：在 canglin-opengauss 容器内执行
#   env/setup-opengauss-user.sh --ssh canglin@host # SSH 模式：在远端 openGauss 主机内执行
#   env/setup-opengauss-user.sh --ssh canglin@host --port 2222
#
# 可用环境变量：
#   CONTAINER                    容器名（默认 canglin-opengauss，对齐 env/docker-compose.yml）
#   CANGLIN_OPENGAUSS_USER       业务账号（默认 canglin）
#   CANGLIN_OPENGAUSS_PASSWORD   业务口令（默认 Canglin@123）
#   CANGLIN_OPENGAUSS_DATABASE   业务库（默认 canglin_src）
#   CANGLIN_OPENGAUSS_ROOT       openGauss 安装根（可选）。非空表示实例装在 chroot 里
#                                （虚拟机方案：宿主 /opt/ocentros 内是完整实例根文件系统），
#                                此时所有 SQL 都经 chroot + runuser 以 omm 身份执行
#   DOCKER_BIN                   容器 CLI（默认 docker，可用 podman 覆盖）
#
# 幂等性：已存在的用户只同步口令、已存在的库不重建、GRANT 可重复执行。
set -euo pipefail

OG_USER="${CANGLIN_OPENGAUSS_USER:-canglin}"
OG_PASSWORD="${CANGLIN_OPENGAUSS_PASSWORD:-Canglin@123}"
OG_DATABASE="${CANGLIN_OPENGAUSS_DATABASE:-canglin_src}"
CONTAINER="${CONTAINER:-canglin-opengauss}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
OG_ROOT="${CANGLIN_OPENGAUSS_ROOT:-}"
OG_HOME="/usr/local/opengauss"

# 目标实例：容器模式用 CONTAINER，SSH 模式用 SSH_TARGET
SSH_TARGET=""
SSH_PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) SSH_TARGET="$2"; shift 2 ;;
    --port) SSH_PORT="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

log() { printf '[setup-opengauss-user] %s\n' "$*"; }
die() { printf '[setup-opengauss-user][ERROR] %s\n' "$*" >&2; exit 1; }

if [ -n "$SSH_TARGET" ]; then
  MODE=ssh
else
  MODE=docker
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "找不到容器 CLI：$DOCKER_BIN"
  "$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" \
    || die "容器 $CONTAINER 未运行（先 env/docker-compose.yml 起服务）"
fi

SSH_PORT_OPT=""
if [ -n "$SSH_PORT" ]; then
  SSH_PORT_OPT="-p $SSH_PORT"
fi
# accept-new：首次连接自动记录主机指纹，重复执行幂等；不覆盖已记录的指纹
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

TMP_SQL="$(mktemp -t opengauss-setup)"
trap 'rm -f "$TMP_SQL"' EXIT

# 以 omm 身份跑一个 SQL 脚本文件（stdin 传入，避免任何引号转义问题）。
# gsql 无 RPATH，必须显式给 LD_LIBRARY_PATH，否则报 libpq 版本不匹配。
#   $1 数据库名  $2 SQL 文件  $3.. 额外的 gsql 参数
run_as_omm() {
  local db="$1" file="$2"; shift 2
  local extra=" $*"
  if [ -n "$OG_ROOT" ]; then
    # chroot 内没有 sudo，且 omm 禁止远程登录，只能 chroot + runuser 降权
    if [ "$MODE" = "docker" ]; then
      "$DOCKER_BIN" exec -i "$CONTAINER" \
        chroot "$OG_ROOT" /usr/sbin/runuser -u omm -- \
        env "LD_LIBRARY_PATH=${OG_HOME}/lib" "${OG_HOME}/bin/gsql" -d "$db" $extra <"$file"
    else
      ssh -T $SSH_PORT_OPT $SSH_OPTS "$SSH_TARGET" \
        "sudo chroot ${OG_ROOT} /usr/sbin/runuser -u omm -- env LD_LIBRARY_PATH=${OG_HOME}/lib ${OG_HOME}/bin/gsql -d ${db} ${extra}" <"$file"
    fi
  else
    if [ "$MODE" = "docker" ]; then
      "$DOCKER_BIN" exec -i -u omm -e "LD_LIBRARY_PATH=${OG_HOME}/lib" \
        "$CONTAINER" "${OG_HOME}/bin/gsql" -d "$db" $extra <"$file"
    else
      ssh -T $SSH_PORT_OPT $SSH_OPTS "$SSH_TARGET" \
        "sudo -u omm env LD_LIBRARY_PATH=${OG_HOME}/lib ${OG_HOME}/bin/gsql -d ${db} ${extra}" <"$file"
    fi
  fi
}

# 以 omm 身份跑一条标量查询，返回去除空白后的结果
query_scalar() {
  local db="$1" sql="$2"
  printf '%s;\n' "$sql" >"$TMP_SQL"
  run_as_omm "$db" "$TMP_SQL" -t -A | tr -d '[:space:]'
}

# 单引号转义：SQL 字符串字面量里的 ' 写成 ''
sql_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# --- 1) 业务用户 ---------------------------------------------------------
user_count="$(query_scalar postgres "SELECT count(*) FROM pg_roles WHERE rolname=$(sql_quote "$OG_USER")")"

if [ "$user_count" = "0" ]; then
  log "创建业务用户 ${OG_USER}"
  printf 'CREATE USER %s WITH PASSWORD %s;\n' "$OG_USER" "$(sql_quote "$OG_PASSWORD")" >"$TMP_SQL"
else
  # openGauss 对「新口令与旧口令相同」直接报错（New password should not equal to the
  # old ones），所以这里用 DO 块捕获该特定错误：口令一致视为已同步，其他错误照常抛出。
  log "业务用户 ${OG_USER} 已存在，同步口令"
  {
    printf 'DO $$\nBEGIN\n'
    printf '  ALTER USER %s WITH PASSWORD %s;\n' "$OG_USER" "$(sql_quote "$OG_PASSWORD")"
    printf 'EXCEPTION WHEN OTHERS THEN\n'
    printf "  IF SQLERRM NOT LIKE '%%should not equal to the old ones%%' THEN\n"
    printf '    RAISE;\n'
    printf '  END IF;\n'
    printf "  RAISE NOTICE 'password unchanged';\n"
    printf 'END\n$$;\n'
  } >"$TMP_SQL"
fi
run_as_omm postgres "$TMP_SQL" -v ON_ERROR_STOP=1 >/dev/null

# --- 2) 业务库 -----------------------------------------------------------
db_count="$(query_scalar postgres "SELECT count(*) FROM pg_database WHERE datname=$(sql_quote "$OG_DATABASE")")"

if [ "$db_count" = "0" ]; then
  log "创建业务库 ${OG_DATABASE}（owner=${OG_USER}）"
  printf 'CREATE DATABASE %s OWNER %s;\n' "$OG_DATABASE" "$OG_USER" >"$TMP_SQL"
  run_as_omm postgres "$TMP_SQL" -v ON_ERROR_STOP=1 >/dev/null
else
  log "业务库 $OG_DATABASE 已存在"
fi

# --- 3) 授权：public schema 属 omm，必须显式授权才能建表 ----------------
log "在 $OG_DATABASE 内授权 public schema 给 $OG_USER"
{
  printf 'GRANT ALL ON SCHEMA public TO %s;\n' "$OG_USER"
  printf 'GRANT ALL ON DATABASE %s TO %s;\n' "$OG_DATABASE" "$OG_USER"
} >"$TMP_SQL"
run_as_omm "$OG_DATABASE" "$TMP_SQL" -v ON_ERROR_STOP=1 >/dev/null

# --- 4) 自检：以业务用户走 TCP 建表 ------------------------------------
log "自检：以 $OG_USER 身份经 TCP 建表/插入/查询/删表"
{
  printf 'CREATE TABLE IF NOT EXISTS pt8_grant_probe(id bigint primary key, born date);\n'
  printf "INSERT INTO pt8_grant_probe VALUES (1, DATE '2026-01-02');\n"
  printf 'SELECT count(*) FROM pt8_grant_probe;\n'
  printf 'DROP TABLE pt8_grant_probe;\n'
} >"$TMP_SQL"
probe_cmd="env LD_LIBRARY_PATH=${OG_HOME}/lib PGPASSWORD='${OG_PASSWORD}' ${OG_HOME}/bin/gsql -h 127.0.0.1 -p 5432 -U ${OG_USER} -d ${OG_DATABASE} -v ON_ERROR_STOP=1"
if [ -n "$OG_ROOT" ]; then
  if [ "$MODE" = "docker" ]; then
    "$DOCKER_BIN" exec -i "$CONTAINER" \
      chroot "$OG_ROOT" /usr/sbin/runuser -u omm -- /bin/bash -c "$probe_cmd" <"$TMP_SQL" >/dev/null
  else
    ssh -T $SSH_PORT_OPT $SSH_OPTS "$SSH_TARGET" \
      "sudo chroot ${OG_ROOT} /usr/sbin/runuser -u omm -- /bin/bash -c \"${probe_cmd}\"" <"$TMP_SQL" >/dev/null
  fi
else
  if [ "$MODE" = "docker" ]; then
    "$DOCKER_BIN" exec -i -u omm \
      -e "LD_LIBRARY_PATH=${OG_HOME}/lib" -e "PGPASSWORD=${OG_PASSWORD}" "$CONTAINER" \
      "${OG_HOME}/bin/gsql" -h 127.0.0.1 -p 5432 -U "${OG_USER}" -d "${OG_DATABASE}" \
      -v ON_ERROR_STOP=1 <"$TMP_SQL" >/dev/null
  else
    ssh -T $SSH_PORT_OPT $SSH_OPTS "$SSH_TARGET" \
      "sudo -u omm env LD_LIBRARY_PATH=${OG_HOME}/lib PGPASSWORD='${OG_PASSWORD}' ${OG_HOME}/bin/gsql -h 127.0.0.1 -p 5432 -U ${OG_USER} -d ${OG_DATABASE} -v ON_ERROR_STOP=1" \
      <"$TMP_SQL" >/dev/null
  fi
fi

log "完成：业务用户 ${OG_USER} / 库 ${OG_DATABASE} 就绪（${MODE} 模式${OG_ROOT:+，chroot=${OG_ROOT}}）"
