#!/usr/bin/env bash
#
# 给本地 cjpm 依赖缓存中的 opengauss-driver 打补丁。
#
# 背景：PT8 引入的 opengauss-driver（gitcode.com/Cangjie-TPC/opengauss-driver）
# 存在三处影响本仓库构建/运行的上游缺陷，且上游仓库未修复。cjpm 拉下来的依赖
# 源码位于 ~/.cjpm/git/ 下，本脚本就地修补该缓存，使 drivers/driver-pg 可构建、
# 可测试。三处补丁的原因与实测证据见 env/driver-notes.md。
#
# 用法：
#   bash env/patch-opengauss-driver.sh
#
# 幂等：已打过补丁的文件会跳过；修改前把原文件备份为 <file>.bak-pt8。
# 依赖缓存被 cjpm 重新拉取后补丁会失效，重跑本脚本即可。

set -euo pipefail

CACHE_ROOT="${CJPM_GIT_DIR:-$HOME/.cjpm/git}/cangjie_tpc::opengauss"

if [ ! -d "$CACHE_ROOT" ]; then
  echo "[x] 未找到 opengauss-driver 依赖缓存：$CACHE_ROOT"
  echo "    请先在 drivers/driver-pg 执行一次 cjpm build，让 cjpm 拉取依赖。"
  exit 1
fi

python3 - "$CACHE_ROOT" <<'PY'
import os
import shutil
import sys

cache_root = sys.argv[1]


def patch(rel_path, old, new, marker, note):
    """就地替换缓存文件中的锚点；已打过的补丁（marker 命中）跳过。"""
    path = os.path.join(cache_root, rel_path)
    if not os.path.isfile(path):
        print("  [skip] 缺少文件：%s" % rel_path)
        return False
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if marker in text:
        print("  [skip] 已打补丁：%s" % rel_path)
        return False
    if old not in text:
        print("  [x] 补丁锚点未命中：%s（%s）" % (rel_path, note))
        sys.exit(1)
    shutil.copyfile(path, path + ".bak-pt8")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new, 1))
    print("  [ok]   %s —— %s" % (rel_path, note))
    return True


for entry in sorted(os.listdir(cache_root)):
    root = os.path.join(cache_root, entry)
    if not os.path.isdir(root):
        continue
    print("==> 处理依赖缓存：%s" % entry)

    # 补丁 1：仓库根目录的 src/main_test.cj 声明 package opengauss，与 organization
    # = "cangjie_tpc" 推出的包名 cangjie_tpc::opengauss 不一致，cjpm test 直接报
    # "the package name in .../src is wrong" 并中止（上游自测同样失败）。
    patch(
        os.path.join(entry, "src", "main_test.cj"),
        "\npackage opengauss\n",
        "\n// PT8-PATCH-1: 补齐 organization 前缀，与 cjpm.toml 的 organization/name 对齐\n"
        "package cangjie_tpc::opengauss\n",
        "package cangjie_tpc::opengauss",
        "修正根包名 cangjie_tpc::opengauss",
    )

    # 补丁 2：上游 output-type = "dynamic" 时，其包初始化先于 stdx.serialization
    # 运行，unittest 可执行文件启动即 SIGABRT：
    # "funcTable is nullptr, ti: std.collection:HashMap<...>"。
    # 改 static 后包初始化随静态初始化链执行，崩溃消失。
    patch(
        os.path.join(entry, "cjpm.toml"),
        'output-type = "dynamic"',
        '# PT8-PATCH-2: 动态包初始化早于 stdx.serialization，unittest 二进制启动即崩溃\n'
        'output-type = "static"',
        'output-type = "static"',
        "output-type dynamic -> static",
    )

    # 补丁 3：NoticeResponse.serialize() 用 field<HashMap<UInt8, String>> 序列化
    # 参数表，而 stdx 的 HashMap 序列化要求键为 String，否则抛
    # DataModelException("This data is not String.")。上游对 ErrorResponse 已用
    # params.toString() 绕过，NoticeResponse 漏改；服务端只要回一条 NOTICE
    # （如 DROP TABLE IF EXISTS 命中不存在的表）驱动就崩。
    patch(
        os.path.join(entry, "src", "proto3", "notice_response.cj"),
        '            .add(field<HashMap<UInt8, String>>("params", params))\n',
        '            // PT8-PATCH-3a: stdx 序列化 HashMap 要求键为 String，UInt8 键会抛\n'
        '            // "This data is not String."；与 ErrorResponse 的既有修法一致。\n'
        '            .add(field<String>("params", params.toString()))\n',
        "PT8-PATCH-3a",
        "NoticeResponse.serialize 改用 params.toString()",
    )

    patch(
        os.path.join(entry, "src", "proto3", "notice_response.cj"),
        '        result.params = HashMap<UInt8, String>.deserialize(dms.get("params"))\n',
        '        // PT8-PATCH-3b: params 序列化时已退化为字符串，反序列化不再还原（上游 ErrorResponse 同此处理）\n'
        '        // result.params = HashMap<UInt8, String>.deserialize(dms.get("params"))\n',
        "PT8-PATCH-3b",
        "NoticeResponse.deserialize 停用 params 还原",
    )

    # 补丁 4：Config.toString() 把 params（HashMap）插值进字符串。上游的
    # logger.debug("${cfg}") 在每次建连时都会走到这里，而 stdx 的 HashMap 序列化
    # 扩展要求运行时实现 std.core:Collection<Tuple<K,V>>——SDK 1.1.0-beta.25 的
    # std.collection.HashMap 不满足该接口检查，插值即 SIGABRT
    # （"expected interface std.core:Collection<Tuple<String,String>> is not in
    # class std.collection:HashMap<String,String>"），unittest 二进制启动即挂。
    # 改为只输出条目数；顺带把口令换成固定掩码（上游原文会写出口令明文）。
    patch(
        os.path.join(entry, "src", "pgconn", "config.cj"),
        "    public func toString(): String {\n"
        "        return \"host='${host}', port='${port}', database='${database}', "
        "user='${user}', password='${password}', sslmode='${sslmode}', params='${params}'\"\n"
        "    }\n",
        "    public func toString(): String {\n"
        "        // PT8-PATCH-4a: 不再插值 params（HashMap）——stdx 的 HashMap 序列化扩展要求\n"
        "        // 运行时实现 std.core:Collection<Tuple<K,V>>，SDK 1.1.0-beta.25 的 std.collection\n"
        "        // HashMap 不满足该接口检查，插值即 SIGABRT。改为输出条目数。\n"
        "        // PT8-PATCH-4b: 口令不写入日志（spec：密码不得写入日志），改为固定掩码。\n"
        "        return \"host='${host}', port='${port}', database='${database}', "
        "user='${user}', password='***', sslmode='${sslmode}', paramsCount=${params.size}\"\n"
        "    }\n",
        "PT8-PATCH-4a",
        "Config.toString 不插值 HashMap 且口令掩码",
    )

    # 补丁 5：建连日志与 URL 解析失败的异常里带上了完整连接串（含口令明文）。
    # spec 要求「密码不得写入日志」，故改为对 userinfo 中的口令段落做掩码。
    patch(
        os.path.join(entry, "src", "driver", "driver.cj"),
        '        logger.debug("in PGDriver.openDb ${connstr}")\n',
        '        // PT8-PATCH-5a: 连接串含口令，日志与异常一律脱敏（spec：密码不得写入日志）\n'
        '        logger.debug("in PGDriver.openDb ${maskConnStrPassword(connstr)}")\n',
        "PT8-PATCH-5a",
        "建连日志对连接串口令脱敏",
    )

    patch(
        os.path.join(entry, "src", "driver", "driver.cj"),
        '        throw SqlException("failed to parse as URL ${connstr}")\n',
        '        // PT8-PATCH-5b: 解析失败异常同样带连接串，口令须脱敏（spec：密码不得写入日志）\n'
        '        throw SqlException("failed to parse as URL ${maskConnStrPassword(connstr)}")\n',
        "PT8-PATCH-5b",
        "URL 解析失败异常对连接串口令脱敏",
    )

    patch(
        os.path.join(entry, "src", "driver", "driver.cj"),
        "    public func getDriverStartTime(): DateTime {\n"
        "        return driverstarttime\n"
        "    }\n"
        "}\n",
        "    public func getDriverStartTime(): DateTime {\n"
        "        return driverstarttime\n"
        "    }\n"
        "}\n"
        "\n"
        "/// PT8-PATCH-5c: 连接串里的口令不得写入日志/异常（spec：密码不得写入日志）。\n"
        "///\n"
        "/// 形如 scheme://user:password@host:port/db?opts —— 把 userinfo 中的口令\n"
        "/// 段落替换为固定掩码，其余部分原样保留，便于排障时仍能看到端点信息。\n"
        "private func maskConnStrPassword(connstr: String): String {\n"
        "    let n = connstr.size\n"
        "    // 定位 \"://\" 之后的位置\n"
        "    var schemeEnd = -1\n"
        "    var i = 0\n"
        "    while (i + 2 < n) {\n"
        "        if (connstr[i] == b':' && connstr[i + 1] == b'/' && connstr[i + 2] == b'/') {\n"
        "            schemeEnd = i + 3\n"
        "            break\n"
        "        }\n"
        "        i++\n"
        "    }\n"
        "    if (schemeEnd < 0) {\n"
        "        return connstr\n"
        "    }\n"
        "    // 定位 userinfo 结束处的 '@'\n"
        "    var at = -1\n"
        "    i = schemeEnd\n"
        "    while (i < n) {\n"
        "        if (connstr[i] == b'@') {\n"
        "            at = i\n"
        "            break\n"
        "        }\n"
        "        i++\n"
        "    }\n"
        "    if (at < 0) {\n"
        "        return connstr\n"
        "    }\n"
        "    // 定位 userinfo 内 user 与 password 之间的 ':'\n"
        "    var colon = -1\n"
        "    i = schemeEnd\n"
        "    while (i < at) {\n"
        "        if (connstr[i] == b':') {\n"
        "            colon = i\n"
        "            break\n"
        "        }\n"
        "        i++\n"
        "    }\n"
        "    if (colon < 0) {\n"
        "        return connstr\n"
        "    }\n"
        "    return connstr[..colon + 1] + \"***\" + connstr[at..]\n"
        "}\n",
        "PT8-PATCH-5c",
        "补充 maskConnStrPassword 脱敏辅助函数",
    )
PY

echo "[done] opengauss-driver 依赖缓存补丁完成"
