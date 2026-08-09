// node ./tools/o3d2facecolors.js ./TREX/model/trex.o3d ./TREX/model/trex.tmd ./TREX/model/trex_facecolors.bin
//
// One base colour per O3D polygon, taken from the PS1 source.
//
// The 136 untextured primitives of this mesh carry their own RGB in the TMD -
// 120 in (255,230,110) and 16 in (35,30,0), the yellow and dark parts of the
// eyes.  The O3D conversion did not keep them: every polygon there has the
// same material word 0x0020, so the renderer had nothing to go on and filled
// those triangles with a diagnostic green or blue instead.  On a small dark
// head a bright green dot is the most conspicuous thing in the frame.
//
// The two files describe the same 2,724 triangles - verified here by matching
// on the vertex-index set - but in a different order: the O3D stream is BSP
// sorted, the TMD is in authoring order.  So the colours are reordered offline
// into O3D order, the same way trex_facenormals.bin is produced, and the
// M68030 front end INCBINs the result and indexes it by source triangle.
//
// Output is one big-endian longword per polygon: the Falcon RGB555X colour in
// the low word, or zero for a textured polygon, which never reads it.

const fs = require("fs");

if(process.argv.length < 5) {
    console.error("usage: o3d2facecolors.js <input.o3d> <input.tmd> <output.bin>");
    process.exit(1);
}

const O3D_HEADER_BYTES = 24;
const O3D_POINT_BYTES = 12;
const O3D_NORMAL_BYTES = 12;
const O3D_POLYGON_HEADER_WORDS = 5;
const O3D_TEXTURE_METADATA_WORDS = 8;

// TMD primitive modes present in this mesh: 0x34 textured Gouraud triangle,
// 0x30 untextured Gouraud triangle.  Only the latter carries an RGB triple,
// in the first word of its packet.
const TMD_MODE_TEXTURED = 0x34;
const TMD_MODE_FLAT = 0x30;

let o3d = fs.readFileSync(process.argv[2]);
let tmd = fs.readFileSync(process.argv[3]);

// ---- TMD: colour per vertex-index set ------------------------------------
// Object table pointers are relative to the end of the 12-byte file header.
const TMD_OBJECT_TABLE = 12;
let vertexTop = tmd.readUInt32LE(TMD_OBJECT_TABLE);
let primitiveTop = tmd.readUInt32LE(TMD_OBJECT_TABLE + 16);
let primitiveCount = tmd.readUInt32LE(TMD_OBJECT_TABLE + 20);

let colourByVertices = new Map();
let cursor = TMD_OBJECT_TABLE + primitiveTop;

for(let primitive = 0; primitive < primitiveCount; primitive++) {
    let inputLength = tmd[cursor + 1];
    let mode = tmd[cursor + 3];
    let body = cursor + 4;

    if(mode != TMD_MODE_TEXTURED && mode != TMD_MODE_FLAT) {
        console.error("primitive " + primitive + " has unexpected mode " + mode.toString(16));
        process.exit(1);
    }

    // Textured packets open with three UV words, untextured ones with the RGB
    // triple; the three normal/vertex index pairs follow either way.
    let indices = body + (mode == TMD_MODE_TEXTURED ? 12 : 4);
    let key = [
        tmd.readUInt16LE(indices + 2),
        tmd.readUInt16LE(indices + 6),
        tmd.readUInt16LE(indices + 10)
    ].sort((a, b) => a - b).join(",");

    if(mode == TMD_MODE_FLAT) {
        colourByVertices.set(key, {
            r: tmd[body],
            g: tmd[body + 1],
            b: tmd[body + 2]
        });
    }

    cursor += 4 + inputLength * 4;
}

if(cursor != TMD_OBJECT_TABLE + vertexTop) {
    console.error("primitive stream ends at " + cursor + " but the vertex table starts at "
        + (TMD_OBJECT_TABLE + vertexTop));
    process.exit(1);
}

// ---- O3D: walk the polygons in their own order ---------------------------
let pointCount = o3d.readUInt16BE(0);
let normalCount = o3d.readUInt16BE(2);
let polygonCount = o3d.readUInt16BE(4);
let polygonOffset = O3D_HEADER_BYTES + pointCount * O3D_POINT_BYTES + normalCount * O3D_NORMAL_BYTES;

let output = Buffer.alloc(polygonCount * 4);
let matched = 0;
let unmatched = 0;

cursor = polygonOffset;

for(let polygon = 0; polygon < polygonCount; polygon++) {
    let pointsInPolygon = o3d.readUInt16BE(cursor);
    let base = cursor + O3D_POLYGON_HEADER_WORDS * 2;
    let key = [
        o3d.readUInt16BE(base) / 3,
        o3d.readUInt16BE(base + 2) / 3,
        o3d.readUInt16BE(base + 4) / 3
    ].sort((a, b) => a - b).join(",");

    let tpage = o3d.readUInt16BE(base + pointsInPolygon * 2 + 14);
    let colour = colourByVertices.get(key);

    if(tpage == 0) {
        if(colour === undefined) {
            console.error("untextured polygon " + polygon + " has no TMD colour (vertices " + key + ")");
            process.exit(1);
        }
        // Falcon RGB555X: R in bits 11..15, G in 6..10, B in 0..4.  Bit 5 is
        // the overlay bit and stays clear, exactly as in the CLUT conversion.
        let falcon = ((colour.r >> 3) << 11) | ((colour.g >> 3) << 6) | (colour.b >> 3);
        output.writeUInt32BE(falcon, polygon * 4);
        matched++;
    } else {
        unmatched++;
    }

    cursor += (O3D_POLYGON_HEADER_WORDS + pointsInPolygon + O3D_TEXTURE_METADATA_WORDS) * 2;
}

if(cursor != o3d.length) {
    console.error("polygon stream ends at " + cursor + " but the file is " + o3d.length + " bytes");
    process.exit(1);
}

fs.writeFileSync(process.argv[4], output);

console.error(matched + " untextured polygons coloured from the TMD, "
    + unmatched + " textured ones left at zero");
