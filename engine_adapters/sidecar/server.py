"""ds_sidecar server：行分隔 JSON-RPC（MCP 形状）over stdio。

协议面对齐 kernel `Equinox.Kernel.MCP.StdioClient` 的最小 MCP 子集：

- `initialize` → {protocolVersion, capabilities, serverInfo}
- `notifications/initialized`（通知，无响应）
- `tools/list` → {tools: [...]}
- `tools/call` {name, arguments} → {content: [{type: "text", text: <json>}], isError: false}

工具：

- `predict(words)` → {ph_dur, pitch_pred_midi, total_frames}
- `render(words, out_path, seed?, ph_dur_override?, curves?)`
    → {path, sample_rate, frames}

words 线上形状：`[[phonemes, dur_sec, midi], ...]`，其中
`phonemes = [[lang, ph], ...]`（如 `[["zh", "l"], ["zh", "iang"]]`）。

纪律：stdout 只过 JSON-RPC（每行一条消息）；日志一律 stderr。
启动慢（uv 依赖解析 + 8 个 ONNX session 加载）——client 端 initialize
timeout 需放宽（秒级到分钟级）。
"""
import argparse
import json
import os
import sys
import traceback

from engine import DiffSingerEngine

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "ds-sidecar", "version": "0.1.0"}

TOOLS = [
    {
        "name": "predict",
        "description": "编码 + dur + pitch 前向（确定性），返回逐音素帧数与预测 pitch（MIDI）",
        "inputSchema": {
            "type": "object",
            "properties": {"words": {"type": "array"}},
            "required": ["words"],
        },
    },
    {
        "name": "render",
        "description": "完整五段管线 → wav 落盘，返回 {path, sample_rate, frames}",
        "inputSchema": {
            "type": "object",
            "properties": {
                "words": {"type": "array"},
                "out_path": {"type": "string"},
                "seed": {"type": "integer"},
                "ph_dur_override": {"type": "array"},
                "curves": {"type": "object"},
            },
            "required": ["words", "out_path"],
        },
    },
]


def log(message):
    print(f"[ds-sidecar] {message}", file=sys.stderr, flush=True)


def result_text(payload):
    return {"content": [{"type": "text", "text": json.dumps(payload)}], "isError": False}


def call_tool(engine, name, arguments):
    if name == "predict":
        return result_text(engine.check(arguments["words"]))
    if name == "render":
        return result_text(engine.render(
            arguments["words"],
            arguments["out_path"],
            seed=arguments.get("seed"),
            ph_dur_override=arguments.get("ph_dur_override"),
            curves=arguments.get("curves"),
        ))
    raise ValueError(f"未知工具：{name}")


def dispatch(engine, message):
    """返回响应 dict；通知与无法识别的消息返回 None（不应答）。"""
    method = message.get("method")
    msg_id = message.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO,
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}

    if method == "tools/call":
        params = message.get("params") or {}
        try:
            result = call_tool(engine, params.get("name"), params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": msg_id, "result": result}
        except Exception as exc:  # 工具错误走 JSON-RPC error，不让进程死
            traceback.print_exc(file=sys.stderr)
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {"code": -32000, "message": str(exc)},
            }

    # 有 id 的未知方法按协议报错；通知类静默忽略
    if msg_id is not None and method:
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "error": {"code": -32601, "message": f"method not found: {method}"},
        }
    return None


def main():
    parser = argparse.ArgumentParser(description="DiffSinger 推理 sidecar（MCP stdio）")
    parser.add_argument("--model-root", required=True, help="OpenUtau 式声库目录")
    parser.add_argument("--out-dir", required=True, help="wav 产物落盘目录")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    # 8 个 session 加载完才进消息循环——initialize 之前的等待是预期行为
    engine = DiffSingerEngine(args.model_root)
    log(f"ready: model_root={args.model_root} sample_rate={engine.sample_rate} hop={engine.hop_size}")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            log(f"丢弃无法解析的行：{line[:200]}")
            continue
        response = dispatch(engine, message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
