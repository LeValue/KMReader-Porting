# Portable comic bubble detection

The optional **Group Text by Speech Bubbles** OCR menu uses the original
YOLO11n segmentation detector distributed in the upstream model catalog.
It merges native OCR blocks inside detected bubbles, retaining narration and
text outside bubbles. It does not replace the text recognizer or add the
upstream MangaOCR models and exact translated typesetting.

The model is bundled for offline use. Its Apache-2.0 license and attribution are
in `assets/models/BUBBLE-LICENSE` and `BUBBLE-NOTICE`, and the app's license view.
`bubble_detector.json` records the source URL, archive/model/weight/output hashes,
shapes and numerical probes. The model retains the upstream 640×640 stretched
RGB input, 0.3 confidence threshold and 0.7 overlap suppression threshold.

`tool/convert_bubble_detector.py` converts the pinned Core ML MIL program to
ONNX opset 17. It evaluates the original FP16 weights in FP32 and exports the
five detection rows; unused segmentation coefficients are omitted. A separate
NumPy interpreter evaluates the source operations on two full-resolution probes
and compares every predicted box and score. The largest measured box error is
0.0013 pixels and score error is below 7.2e-7. These checks establish numerical
conversion behavior, not real-page detection accuracy or bit-identical Apple
hardware inference.

To reproduce, download and verify the archive SHA256 from the metadata, extract
it safely, and install `coremltools`, `numpy`, `onnx` and `onnxruntime` in an
isolated Python environment. Pass the extracted
`detector.mlpackage/Data/com.apple.CoreML/model.mlmodel` and output ONNX path
to the converter. Core ML execution is not required on the Linux converter host.

Inference and suppression run in a worker isolate with two CPU threads, one
session and at most two pending requests. Results use a four-image memory cache;
incognito calls bypass it. The worker releases native resources after one idle
minute and when the account closes. No detection cache is written to disk.
The option defaults off and is only invoked from the OCR screen.

Tests compare ONNX outputs with stored source-network probes, execute the
actual worker, check suppression/grouping and closure during decoding, and
exercise opt-in, pending guards, incognito and OCR fallback at mobile/desktop
widths. Native CI runs the real model on Android and Windows as well.
