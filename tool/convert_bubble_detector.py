"""Port the upstream YOLO bubble model from Core ML MIL to portable ONNX.

Reads the original FP16 weights as FP32; retains every detection operation.
The unused segmentation coefficients are omitted from the exported output.
An independent NumPy MIL interpreter checks all boxes/scores on two probes.
Requires coremltools (protobuf/blob reader only), numpy, onnx, onnxruntime.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

from coremltools.libmilstoragepython import _BlobStorageReader
from coremltools.proto import MIL_pb2, Model_pb2
import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
import onnxruntime as ort


def shape(value):
    dims = value.type.tensorType.dimensions
    assert all(d.WhichOneof('dimension') == 'constant' for d in dims)
    return tuple(d.constant.size for d in dims)


def load(source):
    model = Model_pb2.Model()
    model.ParseFromString(source.read_bytes())
    assert model.WhichOneof('Type') == 'mlProgram'
    block = model.mlProgram.functions['main'].block_specializations['CoreML7']
    reader = _BlobStorageReader(str(source.parent / 'weights/weight.bin'))
    constants = {}
    for op in block.operations:
        if op.type != 'const':
            continue
        value = op.attributes['val']
        dtype = value.type.tensorType.dataType
        if value.WhichOneof('value') == 'blobFileValue':
            assert value.blobFileValue.fileName == '@model_path/weights/weight.bin'
            assert dtype == MIL_pb2.FLOAT16
            data = np.asarray(reader.read_fp16_data(value.blobFileValue.offset)).view(np.float16).astype(np.float32)
        else:
            tensor = value.immediateValue.tensor
            field = tensor.WhichOneof('value')
            if field == 'bytes':
                assert dtype == MIL_pb2.FLOAT16
                data = np.frombuffer(tensor.bytes.values, dtype='<f2').astype(np.float32)
            else:
                kind = {'ints': np.int32, 'floats': np.float32, 'bools': np.bool_, 'strings': np.str_}[field]
                data = np.asarray(getattr(tensor, field).values, dtype=kind)
        constants[op.outputs[0].name] = data.reshape(shape(value))
    return block, constants


def names(op, key):
    args = op.inputs[key].arguments
    assert all(arg.WhichOneof('binding') == 'name' for arg in args)
    return [arg.name for arg in args]


def parameter(op, constants, key):
    return constants[names(op, key)[0]]


def pads(op, constants):
    assert parameter(op, constants, 'pad_type').item() in ['custom', 'valid']
    top, bottom, left, right = parameter(op, constants, 'pad').tolist()
    return [top, left, bottom, right]


def convert(block, constants):
    nodes, initializers, added = [], [], set()

    def constant(name, value):
        if name not in added:
            initializers.append(numpy_helper.from_array(np.asarray(value), name))
            added.add(name)
        return name

    def inputs(op, key):
        result = names(op, key)
        for name in result:
            if name in constants:
                constant(name, constants[name])
        return result

    def setting(op, key):
        return parameter(op, constants, key)

    for op in block.operations:
        if op.type == 'const':
            continue
        out = [o.name for o in op.outputs]
        name = out[0]
        if op.type == 'conv':
            nodes.append(helper.make_node('Conv', inputs(op, 'x') + inputs(op, 'weight') + inputs(op, 'bias'), out,
                pads=pads(op, constants), strides=setting(op, 'strides').tolist(),
                dilations=setting(op, 'dilations').tolist(), group=int(setting(op, 'groups'))))
        elif op.type == 'silu':
            x = inputs(op, 'x')
            nodes.append(helper.make_node('Sigmoid', x, [name + '_sigmoid']))
            nodes.append(helper.make_node('Mul', x + [name + '_sigmoid'], out))
        elif op.type in ['add', 'sub', 'mul']:
            nodes.append(helper.make_node({'add': 'Add', 'sub': 'Sub', 'mul': 'Mul'}[op.type], inputs(op, 'x') + inputs(op, 'y'), out))
        elif op.type == 'concat':
            assert not bool(setting(op, 'interleave'))
            nodes.append(helper.make_node('Concat', inputs(op, 'values'), out, axis=int(setting(op, 'axis'))))
        elif op.type == 'split':
            split = constant(name + '_sizes', setting(op, 'split_sizes').astype(np.int64))
            nodes.append(helper.make_node('Split', inputs(op, 'x') + [split], out, axis=int(setting(op, 'axis'))))
        elif op.type == 'reshape':
            target = setting(op, 'shape').astype(np.int64)
            assert 0 not in target
            nodes.append(helper.make_node('Reshape', inputs(op, 'x') + [constant(name + '_shape', target)], out))
        elif op.type == 'transpose':
            nodes.append(helper.make_node('Transpose', inputs(op, 'x'), out, perm=setting(op, 'perm').tolist()))
        elif op.type == 'max_pool':
            nodes.append(helper.make_node('MaxPool', inputs(op, 'x'), out, kernel_shape=setting(op, 'kernel_sizes').tolist(),
                strides=setting(op, 'strides').tolist(), pads=pads(op, constants), ceil_mode=int(setting(op, 'ceil_mode'))))
        elif op.type == 'matmul':
            data = []
            for key in ['x', 'y']:
                value = inputs(op, key)[0]
                if bool(setting(op, 'transpose_' + key)):
                    rank = len(next(o for p in block.operations for o in p.outputs if o.name == value).type.tensorType.dimensions)
                    perm = list(range(rank)); perm[-2:] = perm[-2:][::-1]
                    nodes.append(helper.make_node('Transpose', [value], [name + '_' + key], perm=perm))
                    value = name + '_' + key
                data.append(value)
            nodes.append(helper.make_node('MatMul', data, out))
        elif op.type == 'softmax':
            nodes.append(helper.make_node('Softmax', inputs(op, 'x'), out, axis=int(setting(op, 'axis'))))
        elif op.type == 'sigmoid':
            nodes.append(helper.make_node('Sigmoid', inputs(op, 'x'), out))
        elif op.type == 'upsample_nearest_neighbor':
            scales = np.array([1, 1, float(setting(op, 'scale_factor_height')), float(setting(op, 'scale_factor_width'))], dtype=np.float32)
            assert all(value == int(value) for value in scales)
            nodes.append(helper.make_node('Resize', inputs(op, 'x') + ['', constant(name + '_scales', scales)], out,
                mode='nearest', coordinate_transformation_mode='asymmetric', nearest_mode='floor'))
        else:
            raise ValueError('Unsupported MIL operation: ' + op.type)
    nodes.append(helper.make_node('Slice', ['preds', constant('boxes_start', np.array([0], np.int64)),
        constant('boxes_end', np.array([5], np.int64)), constant('boxes_axis', np.array([1], np.int64))], ['boxes']))
    graph = helper.make_graph(nodes, 'KMReader original YOLO bubble detector',
        [helper.make_tensor_value_info('pixel_values', TensorProto.FLOAT, [1, 3, 640, 640])],
        [helper.make_tensor_value_info('boxes', TensorProto.FLOAT, [1, 5, 8400])], initializers)
    model = helper.make_model(graph, producer_name='KMReader-Porting', opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 9
    onnx.checker.check_model(model)
    return model


def reference(block, constants, image):
    """Evaluate MIL directly with NumPy, independently of the ONNX graph."""
    tensors = {'pixel_values': image, **constants}
    uses = Counter(arg.name for op in block.operations for v in op.inputs.values() for arg in v.arguments)
    def sigmoid(x):
        return 1 / (1 + np.exp(-np.clip(x, -80, 80)))
    for op in block.operations:
        if op.type == 'const':
            continue
        def value(key):
            return tensors[names(op, key)[0]]
        kind, x = op.type, value('values' if op.type == 'concat' else 'x')
        if kind == 'conv':
            w = value('weight')
            b = value('bias') if names(op, 'bias') else np.zeros(w.shape[0], np.float32)
            group = int(value('groups'))
            top, left, bottom, right = pads(op, constants)
            sh, sw = value('strides'); dh, dw = value('dilations')
            kh, kw = (w.shape[2] - 1) * dh + 1, (w.shape[3] - 1) * dw + 1
            padded = np.pad(x, ((0, 0), (0, 0), (top, bottom), (left, right)))
            windows = np.lib.stride_tricks.sliding_window_view(padded, (kh, kw), axis=(2, 3))[:, :, ::sh, ::sw, ::dh, ::dw]
            chunks = []
            for inputs, weights in zip(np.split(windows, group, axis=1), np.split(w, group, axis=0)):
                chunks.append(np.einsum('nchwkl,ockl->nohw', inputs, weights, optimize=True))
            result = np.concatenate(chunks, axis=1) + b[None, :, None, None]
        elif kind == 'silu': result = x * sigmoid(x)
        elif kind == 'add': result = x + value('y')
        elif kind == 'sub': result = x - value('y')
        elif kind == 'mul': result = x * value('y')
        elif kind == 'concat': result = np.concatenate([tensors[n] for n in names(op, 'values')], axis=int(value('axis')))
        elif kind == 'reshape': result = x.reshape(value('shape'))
        elif kind == 'transpose': result = x.transpose(value('perm'))
        elif kind == 'split': result = np.split(x, np.cumsum(value('split_sizes'))[:-1], axis=int(value('axis')))
        elif kind == 'max_pool':
            assert not bool(value('ceil_mode'))
            top, left, bottom, right = pads(op, constants)
            padded = np.pad(x, ((0, 0), (0, 0), (top, bottom), (left, right)), constant_values=-np.inf)
            windows = np.lib.stride_tricks.sliding_window_view(padded, tuple(value('kernel_sizes')), axis=(2, 3))
            sh, sw = value('strides'); result = windows[:, :, ::sh, ::sw].max(axis=(-1, -2))
        elif kind == 'matmul':
            y = value('y')
            if bool(value('transpose_x')): x = x.swapaxes(-1, -2)
            if bool(value('transpose_y')): y = y.swapaxes(-1, -2)
            result = np.matmul(x, y)
        elif kind == 'softmax':
            axis = int(value('axis')); result = np.exp(x - x.max(axis=axis, keepdims=True)); result /= result.sum(axis=axis, keepdims=True)
        elif kind == 'sigmoid': result = sigmoid(x)
        elif kind == 'upsample_nearest_neighbor':
            result = x.repeat(int(value('scale_factor_height')), axis=2).repeat(int(value('scale_factor_width')), axis=3)
        else: raise ValueError(kind)
        results = result if kind == 'split' else [result]
        for output, data in zip(op.outputs, results):
            assert data.shape == shape(output), (output.name, data.shape, shape(output))
            tensors[output.name] = data
        for binding in op.inputs.values():
            for arg in binding.arguments:
                uses[arg.name] -= 1
                if uses[arg.name] == 0 and arg.name not in constants:
                    tensors.pop(arg.name, None)
    return tensors['preds'][:, :5]


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('source', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert hashlib.sha256(args.source.read_bytes()).hexdigest() == 'a0dd0cdafb93e47c3b8153a0345488f52c6d8725415d6ddeed985f48150a3e50', 'Expected the pinned upstream YOLO model'
    weight_path = args.source.parent / 'weights/weight.bin'
    assert hashlib.sha256(weight_path.read_bytes()).hexdigest() == '8cfa29b46427f2e3134f21cda078638efbb4c03bc594332149c8b214bff27d62', 'Expected the pinned upstream weights'
    block, constants = load(args.source)
    model = convert(block, constants)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, args.output)
    options = ort.SessionOptions(); options.intra_op_num_threads = 2
    session = ort.InferenceSession(str(args.output), options, providers=['CPUExecutionProvider'])
    samples = {'white': np.ones((1, 3, 640, 640), np.float32),
        'checkerboard': np.broadcast_to((np.indices((640, 640)).sum(axis=0) // 16 % 2).astype(np.float32)[None, None], (1, 3, 640, 640)).copy()}
    validation = {}
    columns = [0, 1, 42, 799, 1600, 6399, 6400, 8000, 8399]
    for name, sample in samples.items():
        expected = reference(block, constants, sample)
        actual = session.run(None, {'pixel_values': sample})[0]
        assert np.isfinite(actual).all()
        np.testing.assert_allclose(actual[:, :4], expected[:, :4], atol=.03, rtol=2e-3)
        np.testing.assert_allclose(actual[:, 4], expected[:, 4], atol=2e-5, rtol=2e-3)
        validation[name] = {'maxBoxError': float(np.max(np.abs(actual[:, :4] - expected[:, :4]))),
            'maxScoreError': float(np.max(np.abs(actual[:, 4] - expected[:, 4]))),
            'columns': columns, 'expected': expected[0][:, columns].tolist(), 'maxScore': float(expected[0, 4].max())}
        print(name, {key: value for key, value in validation[name].items() if key not in ['expected', 'columns']}, flush=True)
    metadata = {'sourceUrl': 'https://models.kmworks.date/v1/yolo-seg-detector-2026-v1.tar',
        'archiveSha256': '025f6cb2f9d7e9c55b9f539c10a2441f43d4e6605fbf724cc41ee1cc43cc5975',
        'modelSha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
        'weightsSha256': hashlib.sha256(weight_path.read_bytes()).hexdigest(),
        'onnxSha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'license': 'Apache-2.0', 'input': [1, 3, 640, 640], 'output': [1, 5, 8400],
        'threshold': .3, 'suppressionIoU': .7, 'floatingPoint': 'FP16 weights evaluated in FP32',
        'validation': validation}
    args.output.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps({key: value for key, value in metadata.items() if key != 'validation'}))


if __name__ == '__main__': main()
