// node ./tools/tmd2cornernormals.js ./TREX/model/trex.o3d ./TREX/model/trex.tmd \
//                                   ./TREX/model/trex_cornernormals.bin
//
// Three TMD normal indices per O3D polygon, in O3D polygon order.
//
// The PS1 source shades per corner: every TMD triangle carries three
// (normal, vertex) index pairs into the 3,610-entry Q12 normal table, and
// 3,609 of those normals are referenced (OPTIMIZATION.md section 4.4).  The
// O3D conversion kept only the first vertex's normal index, which sits up
// to 58 degrees off the polygon plane -- useless for shading, which is why
// flat shading derives geometric normals offline instead.  Gouraud needs
// the real three, so this tool recovers them the same way o3d2facecolors.js
// recovers the eye colours: match the two files' triangles on their
// vertex-index SET, then resolve each O3D corner through a vertex->normal
// map so the SORTED set key never scrambles the corner order.
//
// Output: three big-endian uint16 TMD normal indices per polygon (6 bytes
// each), aligned with the O3D polygon stream like the other sidecars.

const fs = require("fs");

if (process.argv.length < 5) {
    console.error("usage: tmd2cornernormals.js <input.o3d> <input.tmd> <output.bin>");
    process.exit(1);
}

const O3D_HEADER_BYTES = 24;
const O3D_POINT_BYTES = 12;
const O3D_NORMAL_BYTES = 12;
const O3D_POLYGON_HEADER_WORDS = 5;
const O3D_TEXTURE_METADATA_WORDS = 8;

const TMD_MODE_TEXTURED = 0x34;
const TMD_MODE_FLAT = 0x30;

const o3d = fs.readFileSync(process.argv[2]);
const tmd = fs.readFileSync(process.argv[3]);

// ---- TMD: vertex->normal map per vertex-index set -------------------------
const TMD_OBJECT_TABLE = 12;
const vertexTop = tmd.readUInt32LE(TMD_OBJECT_TABLE);
const primitiveTop = tmd.readUInt32LE(TMD_OBJECT_TABLE + 16);
const primitiveCount = tmd.readUInt32LE(TMD_OBJECT_TABLE + 20);

const normalsByVertices = new Map();
let cursor = TMD_OBJECT_TABLE + primitiveTop;

for (let primitive = 0; primitive < primitiveCount; primitive++) {
    const inputLength = tmd[cursor + 1];
    const mode = tmd[cursor + 3];
    const body = cursor + 4;

    if (mode != TMD_MODE_TEXTURED && mode != TMD_MODE_FLAT) {
        console.error("primitive " + primitive + " has unexpected mode " + mode.toString(16));
        process.exit(1);
    }

    const indices = body + (mode == TMD_MODE_TEXTURED ? 12 : 4);
    const pairs = [0, 1, 2].map(corner => ({
        normal: tmd.readUInt16LE(indices + corner * 4),
        vertex: tmd.readUInt16LE(indices + corner * 4 + 2)
    }));
    const key = pairs.map(p => p.vertex).sort((a, b) => a - b).join(",");

    const byVertex = new Map();
    for (const p of pairs) byVertex.set(p.vertex, p.normal);
    normalsByVertices.set(key, byVertex);

    cursor += 4 + inputLength * 4;
}

if (cursor != TMD_OBJECT_TABLE + vertexTop) {
    console.error("primitive stream ends at " + cursor + " but the vertex table starts at "
        + (TMD_OBJECT_TABLE + vertexTop));
    process.exit(1);
}

// ---- O3D: resolve each polygon's corners ----------------------------------
const pointCount = o3d.readUInt16BE(0);
const normalCount = o3d.readUInt16BE(2);
const polygonCount = o3d.readUInt16BE(4);
const polygonOffset = O3D_HEADER_BYTES + pointCount * O3D_POINT_BYTES
    + normalCount * O3D_NORMAL_BYTES;

const output = Buffer.alloc(polygonCount * 6);
let matched = 0;
let referenced = new Set();

cursor = polygonOffset;

for (let polygon = 0; polygon < polygonCount; polygon++) {
    const pointsInPolygon = o3d.readUInt16BE(cursor);
    const base = cursor + O3D_POLYGON_HEADER_WORDS * 2;
    const corners = [
        o3d.readUInt16BE(base) / 3,
        o3d.readUInt16BE(base + 2) / 3,
        o3d.readUInt16BE(base + 4) / 3
    ];
    const key = corners.slice().sort((a, b) => a - b).join(",");
    const byVertex = normalsByVertices.get(key);

    if (byVertex === undefined) {
        console.error("polygon " + polygon + " has no TMD match (vertices " + key + ")");
        process.exit(1);
    }
    corners.forEach((vertex, corner) => {
        const normal = byVertex.get(vertex);
        if (normal === undefined) {
            console.error("polygon " + polygon + " corner " + corner
                + " vertex " + vertex + " missing from the TMD pair map");
            process.exit(1);
        }
        output.writeUInt16BE(normal, polygon * 6 + corner * 2);
        referenced.add(normal);
    });
    matched++;

    cursor += (O3D_POLYGON_HEADER_WORDS + pointsInPolygon + O3D_TEXTURE_METADATA_WORDS) * 2;
}

if (cursor != o3d.length) {
    console.error("polygon stream ends at " + cursor + " but the file is " + o3d.length + " bytes");
    process.exit(1);
}

fs.writeFileSync(process.argv[4], output);

console.error(matched + " polygons resolved, " + referenced.size
    + " distinct TMD normals referenced");
