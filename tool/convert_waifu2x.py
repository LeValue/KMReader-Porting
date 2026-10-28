"""Convert the upstream bundled Waifu2x network to portable ONNX.

Needs coremltools (protobuf parser only), numpy, onnx and onnxruntime.
Validates against an independent NumPy implementation of the source layers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto
import onnxruntime as ort
from coremltools.proto import Model_pb2


def values(weight):
    if weight.float16Value:
        return np.frombuffer(weight.float16Value, dtype='<f2').astype(np.float32)
    return np.asarray(weight.floatValue, dtype=np.float32)


def convolution(x, weight, bias):
    windows = np.lib.stride_tricks.sliding_window_view(x, weight.shape[2:], axis=(2, 3))
    return np.einsum('nchwkl,ockl->nohw', windows, weight, optimize=True) + bias[None, :, None, None]


def reference(source, sample):
    tensors = {'input': sample}
    for layer in source.neuralNetwork.layers:
        x = tensors[layer.input[0]]
        kind = layer.WhichOneof('layer')
        if kind == 'convolution':
            p = layer.convolution
            shape = (p.kernelChannels, p.outputChannels, *p.kernelSize) if p.isDeconvolution else (p.outputChannels, p.kernelChannels, *p.kernelSize)
            w, b = values(p.weights).reshape(shape), values(p.bias)
            if p.isDeconvolution:
                up = np.zeros((x.shape[0], x.shape[1], (x.shape[2]-1)*2+1, (x.shape[3]-1)*2+1), dtype=np.float32)
                up[:, :, ::2, ::2] = x
                x = convolution(up, w.transpose(1, 0, 2, 3)[:, :, ::-1, ::-1], b)
            else:
                x = convolution(x, w, b)
        elif kind == 'activation':
            x = np.where(x >= 0, x, x * layer.activation.leakyReLU.alpha)
        elif kind == 'clip':
            x = np.clip(x, layer.clip.minVal, layer.clip.maxVal)
        else:
            raise ValueError(kind)
        tensors[layer.output[0]] = x
    return tensors['output']


def convert(source_path, destination):
    original = source_path.read_bytes()
    source = Model_pb2.Model()
    source.ParseFromString(original)
    assert source.WhichOneof('Type') == 'neuralNetwork'
    assert list(source.description.input[0].type.multiArrayType.shape) == [1, 3, 156, 156]
    nodes, initializers = [], []
    for i, layer in enumerate(source.neuralNetwork.layers):
        kind = layer.WhichOneof('layer')
        if kind == 'convolution':
            p = layer.convolution
            assert p.nGroups == 1 and p.WhichOneof('ConvolutionPaddingType') == 'valid'
            shape = (p.kernelChannels, p.outputChannels, *p.kernelSize) if p.isDeconvolution else (p.outputChannels, p.kernelChannels, *p.kernelSize)
            names = [f'weight_{i}', f'bias_{i}']
            initializers += [numpy_helper.from_array(values(p.weights).reshape(shape), names[0]), numpy_helper.from_array(values(p.bias), names[1])]
            pad = list(p.valid.paddingAmounts.borderAmounts)
            pads = [pad[0].startEdgeSize, pad[1].startEdgeSize, pad[0].endEdgeSize, pad[1].endEdgeSize]
            nodes.append(helper.make_node('ConvTranspose' if p.isDeconvolution else 'Conv', [layer.input[0], *names], list(layer.output), name=layer.name, kernel_shape=list(p.kernelSize), strides=list(p.stride), dilations=list(p.dilationFactor), pads=pads, group=1))
        elif kind == 'activation':
            assert layer.activation.WhichOneof('NonlinearityType') == 'leakyReLU'
            nodes.append(helper.make_node('LeakyRelu', list(layer.input), list(layer.output), name=layer.name, alpha=layer.activation.leakyReLU.alpha))
        elif kind == 'clip':
            for label, value in [('minimum', layer.clip.minVal), ('maximum', layer.clip.maxVal)]:
                initializers.append(numpy_helper.from_array(np.array(value, dtype=np.float32), label))
            nodes.append(helper.make_node('Clip', [layer.input[0], 'minimum', 'maximum'], list(layer.output), name=layer.name))
        else:
            raise ValueError(f'Unsupported source layer: {kind}')
    graph = helper.make_graph(nodes, 'KMReader Waifu2x photo noise0 scale2x',
        [helper.make_tensor_value_info('input', TensorProto.FLOAT, [1, 3, 'height', 'width'])],
        [helper.make_tensor_value_info('output', TensorProto.FLOAT, [1, 3, 'output_height', 'output_width'])], initializers)
    model = helper.make_model(graph, producer_name='KMReader-Porting', opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 9
    onnx.checker.check_model(model)
    destination.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, destination)
    options = ort.SessionOptions(); options.intra_op_num_threads = 2
    session = ort.InferenceSession(str(destination), options, providers=['CPUExecutionProvider'])
    errors = []
    rng = np.random.default_rng(417)
    for sample in [rng.random((1, 3, 22, 24), dtype=np.float32), np.broadcast_to(np.linspace(0, 1, 38, dtype=np.float32)[None, None, :, None], (1, 3, 38, 38)).copy()]:
        expected = reference(source, sample)
        actual = session.run(None, {'input': sample})[0]
        assert actual.shape == (1, 3, (sample.shape[2]-14)*2, (sample.shape[3]-14)*2)
        error = float(np.max(np.abs(expected-actual)));errors.append(error)
        np.testing.assert_allclose(actual, expected, atol=2e-5, rtol=2e-5)
    metadata = {'sourceRepository': 'https://github.com/kmworks/kmreader', 'sourceRef': 'e2b35f8796cc830fc6e7464e161b2172d8f916e9', 'sourcePath': 'KMReader/Resources/Upscaling/waifu2x_photo_noise0_scale2x.mlmodel', 'sourceSha256': hashlib.sha256(original).hexdigest(), 'onnxSha256': hashlib.sha256(destination.read_bytes()).hexdigest(), 'license': 'MIT', 'scale': 2, 'shrink': 7, 'tileSize': 156, 'validationMaxAbsoluteErrors': errors}
    destination.with_suffix('.json').write_text(json.dumps(metadata, indent=2)+'\n')
    print(json.dumps(metadata))


if __name__ == '__main__':
    parser = argparse.ArgumentParser();parser.add_argument('source', type=Path);parser.add_argument('destination', type=Path)
    args = parser.parse_args();convert(args.source, args.destination)
