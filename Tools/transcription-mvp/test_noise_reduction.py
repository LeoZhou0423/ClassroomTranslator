import unittest
import numpy as np
from noise_reduction import NoiseReducer
from app_paths import MODEL_ROOT

@unittest.skipUnless((MODEL_ROOT/'denoise'/'gtcrn_simple.onnx').is_file(),'Requires GTCRN test model')
class NoiseReductionTests(unittest.TestCase):
    def test_backend_failure_returns_pending_audio_and_continues(self):
        processor=NoiseReducer()
        class Broken:
            def run(self,*args):raise RuntimeError('backend failed')
        processor.engine=Broken()
        processor.pending=np.array([.1,.2],dtype=np.float32)
        np.testing.assert_array_equal(processor.process(np.array([.3],dtype=np.float32)),np.array([.1,.2,.3],dtype=np.float32))
        np.testing.assert_array_equal(processor.process(np.array([.4],dtype=np.float32)),np.array([.4],dtype=np.float32))
        self.assertEqual(len(processor.flush()),0)

    def test_streaming_flush_preserves_sample_count_and_finite_output(self):
        processor=NoiseReducer()
        original=np.random.default_rng(8).normal(0,.03,16000+123).astype(np.float32)
        parts=[processor.process(original[i:i+3200]) for i in range(0,len(original),3200)]
        parts.append(processor.flush())
        output=np.concatenate(parts)
        self.assertEqual(len(output),len(original))
        self.assertTrue(np.isfinite(output).all())
        self.assertLess(float(np.mean(output**2)),float(np.mean(original**2)))

if __name__=='__main__':unittest.main()
