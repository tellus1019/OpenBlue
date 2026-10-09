"""Export the 48 kHz DPDFNet8 HR neural core for OpenBlue's stereo worker.

The official checkpoint supplies all learned parameters. Signal normalization,
mask application, deep filtering and transforms remain outside this graph.
"""
import argparse
import contextlib
import hashlib
import io
import json
import math
from pathlib import Path
import sys

import torch
from torch import nn
from torch.nn import functional as F

CHECKPOINT_SHA256 = "7ade8f393e6b845a7f7e8e42b6c7cf169f6821e8489faf8f7fe0792b30482abe"
SOURCE_REVISION = "9bd9844a227bb6aa57e55588d8d0e961fcff1c46"
SOURCE_SHA256 = {
    "onnx_model/dpdfnet_48khz_hr.py": "a13d107b7ebd1745c4fdd29849ec52c1eb2a8597627fe1382346bd42c589c991",
    "onnx_model/layers.py": "ed651a65172501920452d345a28bb38f9a247da32b526a1f600fb602c7fb4cbf",
    "onnx_model/utils.py": "44085dce0a791fca493fccb6742ddd614bcaa88dacf94a93fa971d1f2591e4bf",
    "onnx_model/multiframe.py": "c6469adb82b1bfcb3d1bed50decf7ee3e04fd02328ee5a41c4b491c4b7947f28",
    "model/utils.py": "9f8f4f902d0e1f8dfce6575227d1aca76dde0b6b5781b000b7fca6a6e324e7b3",
}
STATE_WIDTH = 512


class Projection(nn.Module):
    """Keep projection inputs in channel-first, four-dimensional form."""
    def __init__(self, layer, grouped=False):
        super().__init__()
        weight = layer.weight.detach()
        if grouped:
            groups, inputs, outputs = weight.shape
            weight = weight.transpose(1, 2).reshape(groups * outputs, inputs)
            self.groups = groups
        else:
            self.groups = 1
        self.register_buffer("weight", weight[:, :, None, None].contiguous())
        self.register_buffer("bias", None if layer.bias is None else layer.bias.detach())

    def forward(self, x):
        return F.conv2d(x, self.weight, self.bias, groups=self.groups)


class ChannelGRU(nn.Module):
    """PyTorch reset-after GRU gates, with independent lanes in width."""
    def __init__(self, cell):
        super().__init__()
        self.hidden = cell.hidden_size
        for name in ("weight_ih", "weight_hh", "bias_ih", "bias_hh"):
            value = getattr(cell, name).detach()
            if name.startswith("weight"):
                value = value[:, :, None, None]
            self.register_buffer(name, value.contiguous())

    def forward(self, x, h):
        incoming = F.conv2d(x, self.weight_ih, self.bias_ih)
        recurrent = F.conv2d(h, self.weight_hh, self.bias_hh)
        gates = torch.sigmoid(incoming[:, :2*self.hidden] + recurrent[:, :2*self.hidden])
        reset, update = gates[:, :self.hidden], gates[:, self.hidden:]
        candidate = torch.tanh(incoming[:, 2*self.hidden:] + reset * recurrent[:, 2*self.hidden:])
        return candidate + update * (h - candidate)


class ChannelNorm(nn.Module):
    def __init__(self, layer):
        super().__init__()
        self.epsilon = layer.eps
        self.register_buffer("scale", layer.weight.detach()[None, :, None, None])
        self.register_buffer("offset", layer.bias.detach()[None, :, None, None])

    def forward(self, x):
        centered = x - x.mean(dim=1, keepdim=True)
        variance = (centered * centered).mean(dim=1, keepdim=True)
        return centered * torch.rsqrt(variance + self.epsilon) * self.scale + self.offset


class FrequencyGRU(nn.Module):
    """Evaluate ERB/DF, forward/reverse lanes in the same 48-step scan.

    Reverse each real sequence before appending padding. Both directions then
    have suffix padding, which cannot change their retained outputs.
    """
    def __init__(self, erb_gru, df_gru):
        super().__init__()
        self.hidden = erb_gru.hidden_size
        self.steps = 48
        self.lanes = 4
        for kind in ("ih", "hh"):
            for label, gates in (("gates", (0, 1)), ("candidate", (2,))):
                weight = torch.zeros(len(gates)*self.lanes*self.hidden, self.lanes*self.hidden)
                bias = torch.zeros(weight.shape[0])
                for lane, (gru, suffix) in enumerate(((erb_gru, ""), (erb_gru, "_reverse"),
                                                    (df_gru, ""), (df_gru, "_reverse"))):
                    source_weight = getattr(gru, f"weight_{kind}_l0{suffix}").detach()
                    source_bias = getattr(gru, f"bias_{kind}_l0{suffix}").detach()
                    for slot, gate in enumerate(gates):
                        row = (slot*self.lanes + lane)*self.hidden
                        column = lane*self.hidden
                        source = slice(gate*self.hidden, (gate+1)*self.hidden)
                        weight[row:row+self.hidden, column:column+self.hidden] = source_weight[source]
                        bias[row:row+self.hidden] = source_bias[source]
                self.register_buffer(f"{kind}_{label}_weight", weight[:, :, None, None])
                self.register_buffer(f"{kind}_{label}_bias", bias)

    def forward(self, erb, df):
        width = self.lanes*self.hidden
        sequence = torch.cat((F.pad(erb, (0, 8)), F.pad(erb.flip(3), (0, 8)), df, df.flip(3)), dim=1)
        gates = F.conv2d(sequence, self.ih_gates_weight, self.ih_gates_bias)
        candidate = F.conv2d(sequence, self.ih_candidate_weight, self.ih_candidate_bias)
        hidden = erb.new_zeros((erb.shape[0], width, 1, 1))
        outputs = []
        for position in range(self.steps):
            recurrent = F.conv2d(hidden, self.hh_gates_weight, self.hh_gates_bias)
            rz = torch.sigmoid(gates[:, :, :, position:position+1] + recurrent)
            r, z = rz[:, :width], rz[:, width:]
            recurrent_n = F.conv2d(hidden, self.hh_candidate_weight, self.hh_candidate_bias)
            n = torch.tanh(candidate[:, :, :, position:position+1] + r*recurrent_n)
            hidden = n + z*(hidden-n)
            outputs.append(hidden)
        result = torch.cat(outputs, dim=3)
        h = self.hidden
        erb_result = torch.cat((result[:, :h, :, :40], result[:, h:2*h, :, :40].flip(3)), dim=1)
        df_result = torch.cat((result[:, 2*h:3*h], result[:, 3*h:].flip(3)), dim=1)
        return erb_result, df_result


class RecurrentBlock(nn.Module):
    def __init__(self, block):
        super().__init__()
        self.intra_projection = Projection(block.fc_intra)
        self.intra_norm = ChannelNorm(block.ln_intra)
        self.inter = ChannelGRU(block.inter_gru.grucell)
        self.inter_projection = Projection(block.fc_inter)
        self.inter_norm = ChannelNorm(block.ln_inter)

    def forward(self, x, intra, state):
        x = x + self.intra_norm(self.intra_projection(intra))
        state = self.inter(x, state)
        return x + self.inter_norm(self.inter_projection(state)), state


class EmbeddingGRU(nn.Module):
    def __init__(self, module):
        super().__init__()
        if module.gru_skip is not None:
            raise ValueError("The HR checkpoint must not contain an embedding GRU skip")
        self.input = Projection(module.linear_in[0], grouped=True)
        self.cells = nn.ModuleList(ChannelGRU(cell.grucell) for cell in module.gru)
        self.output = None if isinstance(module.linear_out, nn.Identity) else Projection(module.linear_out[0], grouped=True)

    def forward(self, x, states):
        x = F.relu(self.input(x))
        updated = []
        for cell, state in zip(self.cells, states):
            x = cell(x, state)
            updated.append(x)
        if self.output is not None:
            x = F.relu(self.output(x))
        return x, updated


def flatten_features(x):
    batch, channels, _, bins = x.shape
    return x.permute(0, 3, 1, 2).reshape(batch, bins*channels, 1, 1)


def expand_features(x, channels, bins):
    return x.reshape(x.shape[0], bins, channels, 1).permute(0, 2, 3, 1)


def upsample(sequence, x):
    branches = [convolution(x) for convolution in sequence[0].convs]
    batch, channels, _, bins = branches[0].shape
    x = torch.cat(branches, dim=2).permute(0, 1, 3, 2).reshape(batch, channels, 1, bins*len(branches))
    for layer in list(sequence)[1:]:
        x = layer(x)
    return x


class StereoCore(nn.Module):
    def __init__(self, source):
        super().__init__()
        self.encoder = source.enc
        self.erb_decoder = source.erb_dec
        self.df_decoder = source.df_dec
        self.frequency = nn.ModuleList(FrequencyGRU(e.intra_gru, d.intra_gru)
            for e, d in zip(source.enc.dprnn_erb.blocks, source.enc.dprnn_df.blocks))
        self.erb_blocks = nn.ModuleList(RecurrentBlock(b) for b in source.enc.dprnn_erb.blocks)
        self.df_blocks = nn.ModuleList(RecurrentBlock(b) for b in source.enc.dprnn_df.blocks)
        self.erb_embedding = Projection(source.enc.erb_fc_emb[0], grouped=True)
        self.df_embedding = Projection(source.enc.df_fc_emb[0], grouped=True)
        self.encoder_gru = EmbeddingGRU(source.enc.emb_gru)
        self.erb_gru = EmbeddingGRU(source.erb_dec.emb_gru)
        self.df_gru = EmbeddingGRU(source.df_dec.df_gru)
        self.erb_projection = Projection(source.erb_dec.erb_fc_emb[0], grouped=True)
        self.df_skip = Projection(source.df_dec.df_skip, grouped=True)
        self.df_projection = Projection(source.df_dec.df_out[0], grouped=True)
        self.layout = [("erb_history", (1, 2, 481)), ("df_history", (2, 2, 96))]
        self.layout += [(f"erb_block_{i}", (64, 1, 40)) for i in range(8)]
        self.layout += [(f"df_block_{i}", (64, 1, 48)) for i in range(8)]
        self.layout += [(name, (256, 1, 1)) for name in ("encoder", "erb_0", "erb_1", "df_0", "df_1")]
        self.layout += [("df_history_out", (64, 4, 96))]
        self.rows = sum(math.ceil(math.prod(shape)/STATE_WIDTH) for _, shape in self.layout)

    def unpack(self, packed):
        result, row = {}, 0
        for name, shape in self.layout:
            count = math.prod(shape)
            rows = math.ceil(count/STATE_WIDTH)
            result[name] = packed[:, :, row:row+rows].reshape(2, -1)[:, :count].reshape(2, *shape)
            row += rows
        return result

    def pack(self, state):
        chunks = []
        for name, shape in self.layout:
            count = math.prod(shape)
            rows = math.ceil(count/STATE_WIDTH)
            value = state[name].reshape(2, count)
            chunks.append(F.pad(value, (0, rows*STATE_WIDTH-count)).reshape(2, 1, rows, STATE_WIDTH))
        return torch.cat(chunks, dim=2)

    def forward(self, feat_erb, feat_spec, state_in):
        previous, updated = self.unpack(state_in), {}
        erb = torch.cat((previous["erb_history"], feat_erb), dim=2)
        updated["erb_history"] = erb[:, :, 1:]
        e = self.encoder
        e0 = e.erb_conv0(erb[:, :, :, :-1])
        e1 = e.erb_conv1(e0)
        e2 = e.erb_conv2(e1)
        e3 = e.erb_conv3(e2)
        df = torch.cat((previous["df_history"], feat_spec), dim=2)
        updated["df_history"] = df[:, :, 1:]
        c0 = e.df_conv0(df)
        erb, df = e3, e.df_conv1(c0)
        for i, frequency in enumerate(self.frequency):
            erb_intra, df_intra = frequency(erb, df)
            erb, updated[f"erb_block_{i}"] = self.erb_blocks[i](erb, erb_intra, previous[f"erb_block_{i}"])
            df, updated[f"df_block_{i}"] = self.df_blocks[i](df, df_intra, previous[f"df_block_{i}"])
        embedding = torch.cat((F.relu(self.erb_embedding(flatten_features(erb))),
                               F.relu(self.df_embedding(flatten_features(df)))), dim=1)
        embedding, hidden = self.encoder_gru(embedding, [previous["encoder"]])
        updated["encoder"] = hidden[0]
        erb, hidden = self.erb_gru(embedding, [previous["erb_0"], previous["erb_1"]])
        updated["erb_0"], updated["erb_1"] = hidden
        erb = expand_features(F.relu(self.erb_projection(erb)), 64, 40)
        d = self.erb_decoder
        erb = upsample(d.convt3, d.conv3p(e3) + erb)
        erb = upsample(d.convt2, d.conv2p(e2) + erb)
        erb = upsample(d.convt1, d.conv1p(e1) + erb)
        mask = d.conv0_out(d.conv0p(e0) + erb)
        mask = torch.cat((mask, mask[:, :, :, -2:-1]), dim=3)
        df, hidden = self.df_gru(embedding, [previous["df_0"], previous["df_1"]])
        updated["df_0"], updated["df_1"] = hidden
        df = df + self.df_skip(embedding)
        history = torch.cat((previous["df_history_out"], c0), dim=2)
        updated["df_history_out"] = history[:, :, 1:]
        coefficients = expand_features(torch.tanh(self.df_projection(df)), 10, 96)
        coefficients = coefficients + self.df_decoder.df_convp(history)
        return mask, coefficients, self.pack(updated)


def load_source(root, checkpoint):
    if hashlib.sha256(checkpoint.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
        raise ValueError("Checkpoint hash does not match DPDFNet8 48 kHz HR")
    for name, digest in SOURCE_SHA256.items():
        if hashlib.sha256((root/name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Upstream source differs from revision {SOURCE_REVISION}: {name}")
    sys.path.insert(0, str(root))
    from onnx_model.dpdfnet_48khz_hr import DPDFNet48HR, correct_state_dict
    from onnx_model.layers import convert_grouped_linear_to_einsum
    with contextlib.redirect_stdout(io.StringIO()):
        model = DPDFNet48HR(conv_kernel_inp=(3, 3), conv_ch=64, enc_gru_dim=256,
            erb_dec_gru_dim=256, df_dec_gru_dim=256, enc_lin_groups=32, lin_groups=16,
            upsample_conv_type="subpixel", group_linear_type="loop", point_wise_type="cnn",
            separable_first_conv=True, dprnn_num_blocks=8)
    model.load_state_dict(correct_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True)), strict=True)
    convert_grouped_linear_to_einsum(model)
    return model.eval().requires_grad_(False)


def validate(source, core):
    """Compare recurrent output sequences against official streaming modules."""
    states = [source.initial_state() for _ in range(2)]
    packed = torch.zeros(2, 1, core.rows, STATE_WIDTH)
    generator = torch.Generator().manual_seed(731)
    maximum = [0.0, 0.0]
    with torch.no_grad():
        for _ in range(20):
            erb = torch.randn(2, 1, 1, 481, generator=generator)*0.25
            spec = torch.randn(2, 2, 1, 96, generator=generator)*0.05
            mask, coefficients, packed = core(erb, spec, packed)
            for channel in range(2):
                state = states[channel]
                e0, e1, e2, e3, embedding, c0, _, enc_state, offset = source.enc(
                    erb[channel:channel+1], spec[channel:channel+1], state=state, offset=577)
                expected_mask, erb_state, offset = source.erb_dec(embedding, e3, e2, e1, e0, state=state, offset=offset)
                expected_coef, df_state, offset = source.df_dec(embedding, c0, state=state, offset=offset)
                states[channel] = torch.cat((state[:577], enc_state, erb_state, df_state, state[offset:]))
                expected_coef = expected_coef.permute(0, 3, 1, 2)
                maximum[0] = max(maximum[0], (mask[channel:channel+1]-expected_mask).abs().max().item())
                maximum[1] = max(maximum[1], (coefficients[channel:channel+1]-expected_coef).abs().max().item())
    if max(maximum) > 1e-5:
        raise ValueError(f"Streaming neural outputs differ from official modules: {maximum}")
    print(json.dumps({"hops":20, "channels":2, "max_mask_error":maximum[0],
                      "max_coefficient_error":maximum[1], "packed_state_rows":core.rows}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-dir", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--normalization-output", type=Path)
    args = parser.parse_args()
    torch.set_num_threads(1)
    source = load_source(args.upstream_dir.resolve(), args.checkpoint)
    core = StereoCore(source).eval()
    validate(source, core)
    initial = source.initial_state().detach().cpu().flatten()
    if initial.numel() != 90228 or torch.count_nonzero(initial[577:]).item():
        raise ValueError("The checkpoint requires a nonzero neural initial state")
    if args.normalization_output is not None:
        import struct
        args.normalization_output.write_bytes(struct.pack("<577f", *initial[:577].tolist()))
    if args.output is None:
        return
    import coremltools as ct
    import numpy as np
    samples = (torch.zeros(2, 1, 1, 481), torch.zeros(2, 2, 1, 96),
               torch.zeros(2, 1, core.rows, STATE_WIDTH))
    with torch.no_grad():
        traced = torch.jit.trace(core, samples, check_trace=False)
    model = ct.convert(traced, convert_to="mlprogram", skip_model_load=True,
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name=name, shape=sample.shape, dtype=np.float16)
                for name, sample in zip(("feat_erb", "feat_spec", "state_in"), samples)],
        outputs=[ct.TensorType(name=name, dtype=np.float16) for name in ("mask", "coefs", "state_out")])
    model.user_defined_metadata["checkpoint_sha256"] = CHECKPOINT_SHA256
    model.user_defined_metadata["source_revision"] = SOURCE_REVISION
    model.user_defined_metadata["sample_rate"] = "48000"
    model.user_defined_metadata["hop_frames"] = "480"
    model.user_defined_metadata["state_shape"] = f"2,1,{core.rows},{STATE_WIDTH}"
    model.save(str(args.output))


if __name__ == "__main__":
    main()
