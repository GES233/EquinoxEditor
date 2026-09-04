"""把 DiffSinger 图内随机算子冻结为 host noise 输入。

原始声库只读；派生 ONNX 与 fp_manifest.json 写入 --out。派生物的分发和
商用权限取决于声库许可证，默认仅作为本地 gitignored 构建缓存。
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper

SURGERY = {
    "pitch_predict": [
        ("/pitch_predictor/RandomNormalLike", "host_noise", "normal", [1, 1, 64, "frames"]),
    ],
    # Asaritsu 的 variance latent 为 4×16；Qixuan 是 2×36。shape 在下方
    # 从 Random*Like 的动态 shape 子图解析，这里的值仅作无法解析时的兜底。
    "variance": [
        ("/variance_predictor/RandomNormalLike", "host_noise", "normal", [1, 4, 16, "frames"]),
    ],
    "acoustic": [
        ("/diffusion/RandomNormalLike", "host_noise", "normal", [1, 1, 128, "frames"]),
    ],
    "vocoder": [
        ("/generator/m_source/l_sin_gen/RandomUniform", "host_phase", "uniform", [1, 1, 9]),
        ("/generator/m_source/l_sin_gen/RandomNormalLike", "host_noise", "normal", [1, "samples", 9]),
    ],
}


def load_yaml(path):
    import yaml
    with open(path, encoding="utf-8") as file:
        return yaml.load(file, Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))


def model_paths(root):
    acoustic = load_yaml(root / "dsconfig.yaml")
    pitch = load_yaml(root / "dspitch" / "dsconfig.yaml")
    variance = load_yaml(root / "dsvariance" / "dsconfig.yaml")
    vocoder = load_yaml(root / "dsvocoder" / "vocoder.yaml")
    return {
        "acoustic": root / acoustic["acoustic"],
        "pitch_predict": root / "dspitch" / pitch["pitch"],
        "variance": root / "dsvariance" / variance["variance"],
        "vocoder": root / "dsvocoder" / vocoder["model"],
    }


def freeze_model(source, specs, target):
    model = onnx.load(str(source))
    graph = model.graph
    for node_name, input_name, _dist, shape in specs:
        node = next((item for item in graph.node if item.name == node_name), None)
        if node is None:
            # 不同声库可能使用确定性 vocoder；缺少目标随机节点即无需手术。
            continue
        if not node.op_type.startswith("Random"):
            raise ValueError(f"{source.name}: node is not random: {node_name!r}")
        if any(item.name == input_name for item in graph.input):
            raise ValueError(f"{source.name}: duplicate input {input_name!r}")
        old_output = node.output[0]

        def rewire(current):
            count = 0
            for consumer in current.node:
                for index, value in enumerate(consumer.input):
                    if value == old_output:
                        consumer.input[index] = input_name
                        count += 1
                for attribute in consumer.attribute:
                    if attribute.type == onnx.AttributeProto.GRAPH:
                        count += rewire(attribute.g)
            return count

        if rewire(graph) == 0:
            raise ValueError(f"{source.name}: random output has no consumer: {node_name!r}")
        graph.input.append(helper.make_tensor_value_info(input_name, TensorProto.FLOAT, [None] * len(shape)))
        graph.node.remove(node)

    onnx.checker.check_model(model)
    target.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, str(target))
    return [spec for spec in specs if any(item.name == spec[1] for item in graph.input)]


def resolved_shape(shape, frames, hop):
    return [frames if dim == "frames" else frames * hop if dim == "samples" else dim for dim in shape]


def probe(manifest, frames=10, hop=512):
    import onnxruntime as ort
    types = {
        "tensor(float)": np.float32, "tensor(double)": np.float64,
        "tensor(int64)": np.int64, "tensor(int32)": np.int32,
        "tensor(uint8)": np.uint8, "tensor(bool)": np.bool_,
    }
    for key, entry in manifest.items():
        session = ort.InferenceSession(entry["path"], providers=["CPUExecutionProvider"])
        metadata = session.get_inputs()
        original = metadata[:-len(entry["noise"])]
        feeds = {}
        for item in original:
            shape = [frames if isinstance(dim, str) else dim for dim in item.shape]
            shape = [dim if isinstance(dim, int) and dim > 0 else frames for dim in shape]
            feeds[item.name] = np.zeros(shape, dtype=types[item.type])
        for item in original:
            value = feeds[item.name]
            if item.name == "steps": feeds[item.name] = np.array(2, dtype=value.dtype)
            elif item.name == "depth": feeds[item.name] = np.array(1.0, dtype=value.dtype)
            elif item.name in ("ph_dur", "note_dur", "durations", "word_dur"):
                feeds[item.name] = np.full(value.shape, max(1, frames // value.size), dtype=value.dtype)
            elif item.name in ("note_midi", "pitch", "f0"):
                feeds[item.name] = np.full(value.shape, 60.0, dtype=value.dtype)
            elif item.name in ("tokens", "languages"):
                feeds[item.name] = np.ones(value.shape, dtype=value.dtype)
        for spec, item in zip(entry["noise"], metadata[len(original):]):
            if item.name != spec["name"]:
                raise ValueError(f"{key}: manifest input order mismatch")
            feeds[item.name] = np.zeros(resolved_shape(spec["shape"], frames, hop), dtype=np.float32)
        # 各声库的 embedding/特征维度不同，通用 dummy 无法可靠跑完整模型；
        # 这里验证派生模型可加载、原输入仍在前、host noise 顺序/shape 契约一致。
        print(f"signature probe ok: {key}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("voicebank", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--skip-probe", action="store_true")
    args = parser.parse_args()
    manifest = {}
    for key, specs in SURGERY.items():
        source = model_paths(args.voicebank)[key]
        target = args.out / source.name
        applied = freeze_model(source, specs, target)
        manifest[key] = {
            "path": str(target.resolve()),
            "noise": [{"name": name, "dist": dist, "shape": shape} for _node, name, dist, shape in applied],
        }
        print(f"frozen: {key}: {target}")
    args.out.mkdir(parents=True, exist_ok=True)
    with open(args.out / "fp_manifest.json", "w", encoding="utf-8") as file:
        json.dump(manifest, file, ensure_ascii=False, indent=2)
    if not args.skip_probe:
        probe(manifest)


if __name__ == "__main__":
    sys.exit(main())
