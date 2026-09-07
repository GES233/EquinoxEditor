"""实验后端契约测试；不加载声库、不需要安装 OpenVINO 或 GPU。"""

from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import numpy as np

from openvino_session import OpenVinoSession
from worker import DiffSingerEngine


class OpenVinoSessionTest(unittest.TestCase):
    def test_dynamic_model_compiled_once_and_results_owned(self):
        input_port = Mock()
        input_port.get_any_name.return_value = "tokens"
        output_port = Mock()
        output_port.get_any_name.return_value = "mel"
        model = SimpleNamespace(inputs=[input_port], outputs=[output_port])
        output = np.array([1.0], dtype=np.float32)
        compiled = Mock(return_value={"mel": output})
        compiled.output.side_effect = lambda name: name
        core = Mock()
        core.read_model.return_value = model
        core.compile_model.return_value = compiled
        session = OpenVinoSession(core, "model.onnx")
        first = session.run(["mel"], {"tokens": np.zeros((1, 3))})
        session.run(["mel"], {"tokens": np.zeros((1, 9))})
        output[0] = 9.0
        self.assertEqual(first[0][0], 1.0)
        self.assertEqual(session.get_inputs()[0].name, "tokens")
        self.assertEqual(session.get_outputs()[0].name, "mel")
        core.compile_model.assert_called_once_with(
            model, "GPU", {"INFERENCE_PRECISION_HINT": "f32"}
        )
        self.assertEqual(compiled.call_count, 2)

    def test_worker_routes_gpu_explicitly_and_reuses_sessions(self):
        engine = DiffSingerEngine.__new__(DiffSingerEngine)
        engine.backend = "openvino"
        engine.openvino_core = object()
        engine._sessions = {}
        with patch("worker.ort.InferenceSession") as cpu, patch(
            "openvino_session.OpenVinoSession"
        ) as gpu:
            engine._session("pitch.onnx")
            first = engine._session("acoustic.onnx", gpu=True)
            self.assertIs(first, engine._session("acoustic.onnx", gpu=True))
            cpu.assert_called_once_with("pitch.onnx", providers=["CPUExecutionProvider"])
            gpu.assert_called_once_with(engine.openvino_core, "acoustic.onnx")

    def test_gpu_failure_does_not_silently_fall_back(self):
        engine = DiffSingerEngine.__new__(DiffSingerEngine)
        engine.backend = "openvino"
        engine.openvino_core = object()
        engine._sessions = {}
        with patch("worker.ort.InferenceSession") as cpu, patch(
            "openvino_session.OpenVinoSession", side_effect=RuntimeError("unsupported model")
        ):
            with self.assertRaisesRegex(RuntimeError, "unsupported model"):
                engine._session("acoustic.onnx", gpu=True)
            cpu.assert_not_called()
            self.assertEqual(engine._sessions, {})

    def test_default_cpu_does_not_create_gpu_session(self):
        engine = DiffSingerEngine.__new__(DiffSingerEngine)
        engine.backend = "cpu"
        engine._sessions = {}
        with patch("worker.ort.InferenceSession") as cpu, patch(
            "openvino_session.OpenVinoSession"
        ) as gpu:
            engine._session("acoustic.onnx", gpu=True)
            cpu.assert_called_once_with("acoustic.onnx", providers=["CPUExecutionProvider"])
            gpu.assert_not_called()

    def test_unknown_backend_is_rejected_before_model_loading(self):
        with self.assertRaisesRegex(ValueError, "unsupported inference backend"):
            DiffSingerEngine("missing", backend="unknown")

    def test_missing_gpu_is_rejected_before_model_loading(self):
        core = SimpleNamespace(available_devices=["CPU"])
        module = SimpleNamespace(Core=lambda: core)
        with patch.dict("sys.modules", {"openvino": module}):
            with self.assertRaisesRegex(ValueError, "GPU is unavailable"):
                DiffSingerEngine("missing", backend="openvino")


if __name__ == "__main__":
    unittest.main()
