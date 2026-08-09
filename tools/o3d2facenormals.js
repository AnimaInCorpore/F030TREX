// node ./tools/o3d2facenormals.js ./TREX/model/trex.o3d ./TREX/model/trex_facenormals.bin
//
// Derive one unit face normal per O3D polygon for the flat-shading stage.
//
// The O3D already carries the mesh's vertex normals, but each polygon only
// references the normal of its FIRST vertex.  On this mesh those deviate from
// the polygon plane by 28 degrees at the median and by 58 degrees at the 90th
// percentile, which turns per-face shading into noise.  The geometric normal
// of the polygon itself is the value the flat shader actually wants, so it is
// derived here instead - offline, in floating point, once per model.
//
// Orientation follows the source TMD normals: cross(v2-v0, v1-v0) in object
// space agrees with them (mean dot product +0.79).  Do not infer the active
// screen-space culling sign from this object-space order: the PS1 fixed-view
// conversion negates one matrix row and reverses handedness, so its visible
// faces have negative screen area.
//
// Output is DSP-ready: three 24-bit 1.23 fractional words per polygon, each
// zero-extended into a big-endian longword, in polygon order.  The M68030
// front end INCBINs the file and streams it straight to the DSP.

const fs = require("fs");

if(process.argv.length < 4) {
    console.error("usage: o3d2facenormals.js <input.o3d> <output.bin>");
    process.exit(1);
}

const HEADER_BYTES = 24;
const POINT_BYTES = 12;
const NORMAL_BYTES = 12;
const POLYGON_HEADER_WORDS = 5;
const TEXTURE_METADATA_WORDS = 8;

// 1.23 fixed point: $7fffff is 1-2^-23 and $800001 is -1.0.  $800000 is the
// one value the DSP reads as exactly -1.0 but which no rounded unit component
// should produce, so the magnitude is clamped to $7fffff.
const FRACTIONAL_ONE = 0x7fffff;

let o3d = fs.readFileSync(process.argv[2]);

let pointCount = o3d.readUInt16BE(0);
let normalCount = o3d.readUInt16BE(2);
let polygonCount = o3d.readUInt16BE(4);

let pointOffset = HEADER_BYTES;
let polygonOffset = pointOffset + pointCount * POINT_BYTES + normalCount * NORMAL_BYTES;

function readPoint(index) {
    let offset = pointOffset + index * POINT_BYTES;

    return {
        x: o3d.readInt32BE(offset),
        y: o3d.readInt32BE(offset + 4),
        z: o3d.readInt32BE(offset + 8)
    };
}

function subtract(a, b) {
    return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

function cross(a, b) {
    return {
        x: a.y * b.z - a.z * b.y,
        y: a.z * b.x - a.x * b.z,
        z: a.x * b.y - a.y * b.x
    };
}

function toFractional(value) {
    let word = Math.round(value * FRACTIONAL_ONE);

    if(word > FRACTIONAL_ONE) {
        word = FRACTIONAL_ONE;
    } else if(word < -FRACTIONAL_ONE) {
        word = -FRACTIONAL_ONE;
    }

    return word & 0xffffff;
}

let output = Buffer.alloc(polygonCount * 3 * 4);
let outputOffset = 0;
let degenerateCount = 0;

let cursor = polygonOffset;

for(let polygon = 0; polygon < polygonCount; polygon++) {
    let pointsInPolygon = o3d.readUInt16BE(cursor);

    // The point indices are stored pre-scaled by three for the legacy
    // interleaved point/normal array in src/3d.asm.
    let i0 = o3d.readUInt16BE(cursor + POLYGON_HEADER_WORDS * 2) / 3;
    let i1 = o3d.readUInt16BE(cursor + POLYGON_HEADER_WORDS * 2 + 2) / 3;
    let i2 = o3d.readUInt16BE(cursor + POLYGON_HEADER_WORDS * 2 + 4) / 3;

    let v0 = readPoint(i0);
    let v1 = readPoint(i1);
    let v2 = readPoint(i2);

    let normal = cross(subtract(v2, v0), subtract(v1, v0));
    let length = Math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z);

    if(length == 0) {
        // Collinear vertices.  Such a polygon also has zero screen-space area,
        // so the DSP culls it before the shade is ever used.
        degenerateCount++;
        normal = { x: 0, y: 0, z: 0 };
    } else {
        normal = { x: normal.x / length, y: normal.y / length, z: normal.z / length };
    }

    output.writeUInt32BE(toFractional(normal.x), outputOffset);
    output.writeUInt32BE(toFractional(normal.y), outputOffset + 4);
    output.writeUInt32BE(toFractional(normal.z), outputOffset + 8);
    outputOffset += 12;

    cursor += (POLYGON_HEADER_WORDS + pointsInPolygon + TEXTURE_METADATA_WORDS) * 2;
}

if(cursor != o3d.length) {
    console.error("polygon stream ends at " + cursor + " but the file is " + o3d.length + " bytes");
    process.exit(1);
}

fs.writeFileSync(process.argv[3], output);

console.error(polygonCount + " face normals written (" + degenerateCount + " degenerate)");
