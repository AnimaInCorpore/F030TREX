#!/usr/bin/env node
// Build the host-side opaque-texture qualification sidecar.
//
// One output byte belongs to one O3D source triangle.  A value of one means a
// normal textured packet may use the prepared 16-bit CLUT and omit the
// per-pixel PS1-palette-word validity test.  Zero is always safe: false
// negatives cost speed only, while a false positive would fill a real texture
// hole and is therefore forbidden.

const fs = require("fs");
const path = require("path");

const O3D_HEADER_BYTES = 24;
const O3D_POINT_BYTES = 12;
const O3D_NORMAL_BYTES = 12;
const O3D_POLYGON_WORDS = 16;

const TIM_CLUT_DATA_OFFSET = 20;
const TIM_CLUT_ENTRIES = 256;
const TIM_PIXEL_DATA_OFFSET = 544;
const TIM_SIZE = TIM_PIXEL_DATA_OFFSET + 256 * 256;
const TEXTURE_PAGE_IDS = [10, 12, 14, 26, 28, 30];
const TPAGE_MASK = 0x1f;
const FOOTPRINT_DILATION = 2;

function fail(message) {
    console.error("opaque qualification failed: " + message);
    process.exitCode = 1;
}

function resolveTpage(raw) {
    const page = raw & TPAGE_MASK;
    return TEXTURE_PAGE_IDS.includes(page) ? page : TEXTURE_PAGE_IDS[0];
}

function cross(a, b, c) {
    return ((b[0] - a[0]) * (c[1] - a[1])
        - (b[1] - a[1]) * (c[0] - a[0]));
}

function pointOnSegment(a, b, point) {
    return cross(a, b, point) === 0
        && Math.min(a[0], b[0]) <= point[0]
        && point[0] <= Math.max(a[0], b[0])
        && Math.min(a[1], b[1]) <= point[1]
        && point[1] <= Math.max(a[1], b[1]);
}

function segmentsIntersect(a, b, c, d) {
    const abC = cross(a, b, c);
    const abD = cross(a, b, d);
    const cdA = cross(c, d, a);
    const cdB = cross(c, d, b);

    if ((abC === 0 && pointOnSegment(a, b, c))
        || (abD === 0 && pointOnSegment(a, b, d))
        || (cdA === 0 && pointOnSegment(c, d, a))
        || (cdB === 0 && pointOnSegment(c, d, b))) {
        return true;
    }

    return (abC > 0) !== (abD > 0)
        && (cdA > 0) !== (cdB > 0);
}

function pointInTriangle(point, triangle) {
    const signs = triangle.map((_, index) =>
        cross(triangle[index], triangle[(index + 1) % 3], point));
    return signs.every(value => value >= 0)
        || signs.every(value => value <= 0);
}

function cellIntersectsTriangle(u, v, uvs) {
    // Exact closed-cell/triangle intersection using doubled integers.
    const triangle = uvs.map(([x, y]) => [2 * x, 2 * y]);
    const x0 = 2 * u;
    const y0 = 2 * v;
    const square = [[x0, y0], [x0 + 2, y0],
        [x0 + 2, y0 + 2], [x0, y0 + 2]];

    if (triangle.some(([x, y]) =>
        x0 <= x && x <= x0 + 2 && y0 <= y && y <= y0 + 2)) {
        return true;
    }
    if (square.some(point => pointInTriangle(point, triangle))) {
        return true;
    }

    return triangle.some((_, i) =>
        square.some((_, j) =>
            segmentsIntersect(triangle[i], triangle[(i + 1) % 3],
                square[j], square[(j + 1) % 4])));
}

function conservativeAffineTexels(uvs, dilation = FOOTPRINT_DILATION) {
    // Return a conservative set of wrapped (u, v) texels for one triangle.
    const us = uvs.map(([u]) => u);
    const vs = uvs.map(([, v]) => v);
    let footprint = new Set();

    // The -1 lower bound is needed because the closed cell immediately below
    // an integer vertex touches it.  It is conservative at a floor boundary.
    for (let v = Math.min(...vs) - 1; v <= Math.max(...vs) + 1; v++) {
        for (let u = Math.min(...us) - 1; u <= Math.max(...us) + 1; u++) {
            if (cellIntersectsTriangle(u, v, uvs)) {
                footprint.add(`${u & 0xff},${v & 0xff}`);
            }
        }
    }

    for (let iteration = 0; iteration < dilation; iteration++) {
        const expanded = new Set();
        for (const key of footprint) {
            const [u, v] = key.split(",").map(Number);
            for (const du of [-1, 0, 1]) {
                for (const dv of [-1, 0, 1]) {
                    expanded.add(`${(u + du) & 0xff},${(v + dv) & 0xff}`);
                }
            }
        }
        footprint = expanded;
    }

    return Array.from(footprint, key => key.split(",").map(Number));
}

function scanTexturePages(textureDir) {
    const pages = new Map();

    for (const page of TEXTURE_PAGE_IDS) {
        const texturePath = path.join(textureDir, `trex_texture_page_${page}.tim`);
        let data;
        try {
            data = fs.readFileSync(texturePath);
        } catch (error) {
            throw new Error(`cannot read ${texturePath}: ${error.message}`);
        }

        if (data.length < TIM_SIZE) {
            throw new Error(`${texturePath} is ${data.length} bytes, expected at least ${TIM_SIZE}`);
        }

        const clut = Array.from({ length: TIM_CLUT_ENTRIES }, (_, index) =>
            data.readUInt16LE(TIM_CLUT_DATA_OFFSET + index * 2));
        const pixels = data.subarray(TIM_PIXEL_DATA_OFFSET, TIM_SIZE);
        const used = new Set(pixels);
        const invalidIndices = new Set(
            Array.from(used).filter(index => clut[index] === 0));
        let invalidTexels = 0;

        for (const index of pixels) {
            if (invalidIndices.has(index)) {
                invalidTexels++;
            }
        }

        pages.set(page, {
            pixels,
            invalidIndices,
            opaque: invalidIndices.size === 0,
            usedIndices: used.size,
            invalidTexels
        });
    }

    return pages;
}

function readO3dPolygons(filePath) {
    let data;
    try {
        data = fs.readFileSync(filePath);
    } catch (error) {
        throw new Error(`cannot read ${filePath}: ${error.message}`);
    }

    if (data.length < O3D_HEADER_BYTES) {
        throw new Error(`${filePath} is shorter than the O3D header`);
    }

    // Point/normal counts come from the O3D header, the same way the other JS
    // tools read them, rather than from constants that can silently go stale.
    const pointCount = data.readUInt16BE(0);
    const normalCount = data.readUInt16BE(2);
    const offset = O3D_HEADER_BYTES
        + pointCount * O3D_POINT_BYTES
        + normalCount * O3D_NORMAL_BYTES;
    const stride = O3D_POLYGON_WORDS * 2;

    if (data.length < offset || (data.length - offset) % stride !== 0) {
        throw new Error(`${filePath} has a malformed polygon block`);
    }

    const polygons = [];
    for (let cursor = offset; cursor < data.length; cursor += stride) {
        const words = [];
        for (let index = 0; index < O3D_POLYGON_WORDS; index++) {
            words.push(data.readUInt16BE(cursor + index * 2));
        }
        polygons.push(words);
    }
    return polygons;
}

function qualifyO3d(o3dPath, textureDir, dilation = FOOTPRINT_DILATION) {
    const pages = scanTexturePages(textureDir);
    const polygons = readO3dPolygons(o3dPath);
    const sidecar = Buffer.alloc(polygons.length);
    const tally = new Map(TEXTURE_PAGE_IDS.map(page => [page, [0, 0]]));
    let untextured = 0;

    polygons.forEach((word, index) => {
        if (word[15] === 0) {
            untextured++;
            return;
        }

        const page = resolveTpage(word[15]);
        const pageTally = tally.get(page);
        pageTally[0]++;
        const info = pages.get(page);
        let qualifies = info.opaque;

        if (!qualifies) {
            const uvs = [[word[8] & 0xff, word[9] & 0xff],
                [word[10] & 0xff, word[11] & 0xff],
                [word[12] & 0xff, word[13] & 0xff]];
            qualifies = conservativeAffineTexels(uvs, dilation).every(([u, v]) =>
                !info.invalidIndices.has(info.pixels[v * 256 + u]));
        }

        if (qualifies) {
            sidecar[index] = 1;
            pageTally[1]++;
        }
    });

    return { sidecar, tally, untextured, pages };
}

function writeSidecar(filePath, payload) {
    // Normal generation runs through make; keep the write atomic so an
    // interrupted qualification cannot leave a plausible truncated table.
    const temporary = filePath + ".tmp";
    fs.writeFileSync(temporary, payload);
    fs.renameSync(temporary, filePath);
}

function parseArguments(argv) {
    if (argv.length < 3) {
        throw new Error("usage: o3d2opaque.js <o3d> <texture_dir> <output> [--dilation N]");
    }

    let dilation = FOOTPRINT_DILATION;
    if (argv.length > 3) {
        if (argv.length !== 5 || argv[3] !== "--dilation") {
            throw new Error("usage: o3d2opaque.js <o3d> <texture_dir> <output> [--dilation N]");
        }
        dilation = Number(argv[4]);
    }
    if (!Number.isInteger(dilation) || dilation < 0) {
        throw new Error("--dilation must be non-negative");
    }

    return { o3d: argv[0], textureDir: argv[1], output: argv[2], dilation };
}

try {
    const args = parseArguments(process.argv.slice(2));
    const result = qualifyO3d(args.o3d, args.textureDir, args.dilation);
    writeSidecar(args.output, result.sidecar);

    const qualified = Array.from(result.sidecar).reduce((sum, value) => sum + value, 0);
    console.log(`${args.output}: ${qualified}/${result.sidecar.length - result.untextured}`
        + ` textured triangles qualified; ${result.untextured} untextured stay on the flat path`);

    for (const page of TEXTURE_PAGE_IDS) {
        const [count, pageQualified] = result.tally.get(page);
        const info = result.pages.get(page);
        console.log(`  page ${String(page).padStart(2)}: ${String(pageQualified).padStart(4)}`
            + `/${String(count).padStart(4)} triangles, ${String(info.invalidTexels).padStart(5)}`
            + ` invalid texels, ${String(info.usedIndices).padStart(3)} used indices`);
    }
} catch (error) {
    fail(error.message);
}
