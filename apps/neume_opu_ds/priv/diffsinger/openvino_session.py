"""实验性 OpenVINO 动态 GPU session；接口只覆盖当前 worker 的消费需求。"""

from types import SimpleNamespace


class OpenVinoSession:
    def __init__(self, core, path):
        model = core.read_model(path)
        self.inputs = [SimpleNamespace(name=port.get_any_name()) for port in model.inputs]
        self.outputs = [SimpleNamespace(name=port.get_any_name()) for port in model.outputs]
        self.compiled = core.compile_model(
            model, "GPU", {"INFERENCE_PRECISION_HINT": "f32"}
        )

    def get_inputs(self):
        return self.inputs

    def get_outputs(self):
        return self.outputs

    def run(self, outputs, inputs):
        result = self.compiled(inputs)
        return [result[self.compiled.output(name)].copy() for name in outputs]
