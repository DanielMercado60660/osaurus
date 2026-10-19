#!/usr/bin/env python3
"""Generate four fixed WAVs and compare production Swift against Transformers
features and mlx_audio's MLX forward pass using the same cached bundle.

Run in an EXISTING Python environment with numpy, transformers, mlx, mlx_audio.
No installs/downloads. --features-only needs no MLX and reports logits unverified.
The Swift probe must be built first (see T17 RESULT/build-probe.py).
"""
import argparse
import hashlib
import json
import os
import subprocess
import wave
from pathlib import Path

import numpy as np
from transformers import WhisperFeatureExtractor


def fixtures(directory):
    texts = ["What is the capital of France?", "I would like to know more about",
             "Please tell me a short story about a friendly dinosaur.",
             "Could you explain why the sky is blue?"]
    paths = []
    for i, text in enumerate(texts):
        wav = directory / f"utterance-{i + 1}.wav"
        if not wav.exists():
            aiff = wav.with_suffix('.aiff')
            subprocess.run(['say', '-v', 'Samantha', '-o', str(aiff), text], check=True)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
        paths.append(wav)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--workdir', type=Path, default=Path('build/T17/golden'))
    parser.add_argument('--features-only', action='store_true')
    parser.add_argument('--fixture-source', type=Path, help='Derive full/cut/pause/long PCM16 fixtures from an existing mono WAV')
    parser.add_argument('--wav', type=Path, action='append', help='Use four existing mono 16 kHz PCM16 WAVs instead of say')
    args = parser.parse_args()
    args.workdir.mkdir(parents=True, exist_ok=True)
    if args.fixture_source:
        with wave.open(str(args.fixture_source)) as w:
            if w.getnchannels() != 1 or w.getsampwidth() != 2:
                parser.error('--fixture-source must be mono PCM16')
            rate = w.getframerate()
            source = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2')
        if len(source) == 0:
            parser.error('--fixture-source is empty')
        source = np.interp(np.arange(int(len(source) * 16000 / rate)) * rate / 16000,
                           np.arange(len(source)), source).round().astype('<i2')
        cases = [('full', source), ('cut55', source[:int(len(source) * .55)]),
                 ('pause', np.r_[source, np.zeros(4000, dtype='<i2')]),
                 ('long', np.tile(source, max(2, 144000 // len(source) + 1)))]
        paths = []
        for name, pcm in cases:
            path = args.workdir / (name + '.wav')
            with wave.open(str(path), 'wb') as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
                w.writeframes(pcm.astype('<i2').tobytes())
            paths.append(path)
    else:
        paths = args.wav or fixtures(args.workdir)
    if len(paths) != 4:
        parser.error('Provide exactly four WAVs')
    for path in paths:
        with wave.open(str(path)) as wav:
            if wav.getnframes() == 0:
                parser.error(f'{path} contains no audio; say can silently fail in a sandbox. Use --wav fixtures.')
    run = subprocess.run([str(args.probe.resolve()), str(args.model.resolve()), *map(str, paths)],
                         check=False, capture_output=True, text=True)
    (args.workdir / 'swift.jsonl').write_text(run.stdout)
    (args.workdir / 'swift-stderr.log').write_text(run.stderr)
    run.check_returncode()
    swift = {Path(row['wav']).name: row for line in run.stdout.splitlines()
             if line.startswith('{') for row in [json.loads(line)]}
    extractor = WhisperFeatureExtractor(chunk_length=8)
    if not args.features_only:
        import mlx.core as mx
        if os.environ.get('SMART_TURN_PROBE_CPU') == '1':
            mx.set_default_device(mx.cpu)
        from mlx_audio.vad.models.smart_turn.smart_turn import Model
        from mlx_audio.vad.models.smart_turn.config import ModelConfig
        model = Model(ModelConfig.from_dict(json.loads((args.model / 'config.json').read_text())))
        model.load_weights(list(model.sanitize(mx.load(str(args.model / 'model.safetensors'))).items()), strict=True)
        model.eval()
    records = []
    for path in paths:
        with wave.open(str(path)) as w:
            assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000)
            audio = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float32) / 32768
        audio = audio[-128000:]
        audio = np.pad(audio, (128000 - len(audio), 0))
        features = extractor(audio, sampling_rate=16000, return_tensors='np', padding='max_length',
                             max_length=128000, truncation=True, do_normalize=True).input_features.reshape(80, 800)
        actual = np.fromfile(str(path) + '.swift.f32', dtype='<f4').reshape(80, 800)
        features.astype('<f4').tofile(str(path) + '.reference.f32')
        diff = np.abs(features - actual)
        row = dict(swift[path.name], sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   featureMaxAbsDiff=float(diff.max()), featureMeanAbsDiff=float(diff.mean()))
        row['pass'] = row['featureMaxAbsDiff'] < 0.01
        if not args.features_only:
            reference_logit = float(model(mx.array(features[None]), return_logits=True).item())
            # Also isolates forward pass error from preprocessing error.
            same_input_logit = float(model(mx.array(actual[None]), return_logits=True).item())
            row.update(referenceLogit=reference_logit, referenceSameInputLogit=same_input_logit,
                       logitAbsDiff=abs(reference_logit - row['logit']),
                       sameInputLogitAbsDiff=abs(same_input_logit - row['logit']))
            row['pass'] &= row['logitAbsDiff'] < 0.02 and row['sameInputLogitAbsDiff'] < 0.002
        records.append(row)
    result = dict(status='PASS' if all(r['pass'] for r in records) else 'FAIL',
                  logits='UNVERIFIED' if args.features_only else 'compared', records=records,
                  device='cpu/Accelerate' if args.features_only else ('cpu' if os.environ.get('SMART_TURN_PROBE_CPU') == '1' else 'gpu'),
                  model=str(args.model), modelSHA256=hashlib.sha256((args.model / 'model.safetensors').read_bytes()).hexdigest(),
                  tolerances=dict(featureMaxAbsDiff=0.01, logitAbsDiff=0.02, sameInputLogitAbsDiff=0.002))
    (args.workdir / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['status'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
