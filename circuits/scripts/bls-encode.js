// BLS12-381 point encoding bridge: snarkjs JSON ↔ BLST compressed bytes.
//
// snarkjs outputs proof points as:
//   G1 = [x, y, "1"]              (decimal strings, affine coords)
//   G2 = [[x0, x1], [y0, y1], ["1", "0"]]
//
// TVM (and v1 mixer.fc) consumes points as BLST compressed bytes packed
// into 48-bit (G1) or 96-bit (G2) chunks in a Cell. We convert here.

import { bls12_381 as bls } from "@noble/curves/bls12-381.js";

// snarkjs JSON G1 → BLST compressed 48 bytes
export function g1ToBytes(point) {
    const [x, y] = point;
    const p = bls.G1.Point.fromAffine({ x: BigInt(x), y: BigInt(y) });
    p.assertValidity();
    return p.toBytes(true);
}

// snarkjs JSON G2 → BLST compressed 96 bytes
export function g2ToBytes(point) {
    const [[x0, x1], [y0, y1]] = point;
    const Fp2 = bls.fields.Fp2;
    const p = bls.G2.Point.fromAffine({
        x: Fp2.fromBigTuple([BigInt(x0), BigInt(x1)]),
        y: Fp2.fromBigTuple([BigInt(y0), BigInt(y1)]),
    });
    p.assertValidity();
    return p.toBytes(true);
}

// 48 raw bytes → 8 × 48-bit chunks (big-endian), as bigints
export function bytesToG1Chunks(bytes) {
    if (bytes.length !== 48) throw new Error(`expected 48 bytes, got ${bytes.length}`);
    const chunks = [];
    for (let i = 0; i < 8; i++) {
        let v = 0n;
        for (let j = 0; j < 6; j++) {
            v = (v << 8n) | BigInt(bytes[i * 6 + j]);
        }
        chunks.push(v);
    }
    return chunks;
}

// 96 raw bytes → 8 × 96-bit chunks
export function bytesToG2Chunks(bytes) {
    if (bytes.length !== 96) throw new Error(`expected 96 bytes, got ${bytes.length}`);
    const chunks = [];
    for (let i = 0; i < 8; i++) {
        let v = 0n;
        for (let j = 0; j < 12; j++) {
            v = (v << 8n) | BigInt(bytes[i * 12 + j]);
        }
        chunks.push(v);
    }
    return chunks;
}

export function g1ToChunks(point) {
    return bytesToG1Chunks(g1ToBytes(point));
}

export function g2ToChunks(point) {
    return bytesToG2Chunks(g2ToBytes(point));
}
