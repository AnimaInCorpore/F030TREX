// node ./tools/wavefront2object.js ./bin/model.obj ./release/model.o3d

const fs = require("fs");

if(process.argv.length < 4) {
    return;
}

let wfObjectText = fs.readFileSync(process.argv[2], "utf-8");
let wfObjectTextLines = wfObjectText.split("\n");

let points = [];
let normals = [];
let texcoords = [];
let polygons = [];

const TEXTURE_METADATA_WORDS = 8;

let minX = 0;
let maxX = 0;
let minY = 0;
let maxY = 0;
let minZ = 0;
let maxZ = 0;

let activeColor = 1;

let polygonOffset = 0;

for(let wfObjectTextLine of wfObjectTextLines) {
    let lineData = wfObjectTextLine.split(" ");

    switch(lineData[0]) {
        case "v":
            {
                let x = parseFloat(lineData[1]);
                let y = -parseFloat(lineData[2]);
                let z = parseFloat(lineData[3]);

                if(x < minX) {
                    minX = x;
                }

                if(x > maxX) {
                    maxX = x;
                }

                if(y < minY) {
                    minY = y;
                }

                if(y > maxY) {
                    maxY = y;
                }

                if(z < minZ) {
                    minZ = z;
                }

                if(z > maxZ) {
                    maxZ = z;
                }

                points.push({ x: x, y: y, z: z });
            }

            break;

        case "vn":
            {
                let x = parseFloat(lineData[1]);
                let y = -parseFloat(lineData[2]);
                let z = parseFloat(lineData[3]);

                normals.push({ x: x, y: y, z: z });
            }

            break;

        case "vt":
            {
                texcoords.push({
                    u: parseFloat(lineData[1]),
                    v: parseFloat(lineData[2])
                });
            }

            break;

        case "usemtl":
            {
                activeColor = parseInt(lineData[1].substring(5));
            }

            break;
    
        case "f":
            if(lineData.length == 4 || lineData.length == 5) {
                let normalIndex = 0;
                let pointIndices = [];
                let texcoordIndices = [];
                let polygonCenter = { x: 0, y: 0, z: 0 };

                for(let index = 1; index < lineData.length; index++) {
                    let vtn = lineData[index].split("/");

                    if(index == 1) {
                        normalIndex = parseInt(vtn[2]) - 1;
                    }

                    let pointIndex = parseInt(vtn[0]) - 1;
                    let texcoordIndex = vtn[1] ? parseInt(vtn[1]) - 1 : null;

                    pointIndices.push(pointIndex);
                    texcoordIndices.push(texcoordIndex);

                    polygonCenter.x += points[pointIndex].x;
                    polygonCenter.y += points[pointIndex].y;
                    polygonCenter.z += points[pointIndex].z;
                }

                polygonCenter.x /= (lineData.length - 1);
                polygonCenter.y /= (lineData.length - 1);
                polygonCenter.z /= (lineData.length - 1);

                polygons.push({
                    offset: polygonOffset,
                    normalIndex: normalIndex,
                    pointIndices: pointIndices,
                    texcoordIndices: texcoordIndices,
                    center: polygonCenter,
                    color: activeColor,
                    backPolygon: null,
                    frontPolygon: null
                });
            } else {
                console.log("Unsupported polygon size " + (lineData.length - 1) + "!");

                process.exit();
            }

            polygonOffset += lineData.length + 4 + TEXTURE_METADATA_WORDS;

            break;
    }
}

const BSP_EPSILON = 0.000001;
const BSP_STRADDLING_WEIGHT = 5;

function signedDistanceToPolygonPlane(point, splitPolygon) {
    let splitPolygonNormal = normals[splitPolygon.normalIndex];

    let ax = splitPolygonNormal.x;
    let ay = splitPolygonNormal.y;
    let az = splitPolygonNormal.z;

    let bx = point.x - splitPolygon.center.x;
    let by = point.y - splitPolygon.center.y;
    let bz = point.z - splitPolygon.center.z;

    return ax * bx + ay * by + az * bz;
}

function polygonStraddlesPlane(polygon, splitPolygon) {
    let hasBackPoint = false;
    let hasFrontPoint = false;

    for(let pointIndex of polygon.pointIndices) {
        let distance = signedDistanceToPolygonPlane(points[pointIndex], splitPolygon);

        if(distance < -BSP_EPSILON) {
            hasBackPoint = true;
        } else if(distance > BSP_EPSILON) {
            hasFrontPoint = true;
        }

        if(hasBackPoint && hasFrontPoint) {
            return true;
        }
    }

    return false;
}

function classifyPolygonCenter(polygon, splitPolygon) {
    return signedDistanceToPolygonPlane(polygon.center, splitPolygon) < 0 ? "back" : "front";
}

function scoreSplitPolygon(splitPolygon, polygons) {
    let backCount = 0;
    let frontCount = 0;
    let straddlingCount = 0;

    for(let polygon of polygons) {
        if(polygon === splitPolygon) {
            continue;
        }

        if(classifyPolygonCenter(polygon, splitPolygon) == "back") {
            backCount++;
        } else {
            frontCount++;
        }

        if(polygonStraddlesPlane(polygon, splitPolygon)) {
            straddlingCount++;
        }
    }

    return straddlingCount * BSP_STRADDLING_WEIGHT + Math.abs(backCount - frontCount);
}

function chooseSplitPolygon(polygons) {
    let bestPolygon = polygons[0];
    let bestScore = scoreSplitPolygon(bestPolygon, polygons);

    for(let index = 1; index < polygons.length; index++) {
        let polygon = polygons[index];
        let score = scoreSplitPolygon(polygon, polygons);

        if(score < bestScore) {
            bestPolygon = polygon;
            bestScore = score;
        }
    }

    return bestPolygon;
}

function splitPolygons(polygons) {
    if(polygons.length == 0) {
        return null;
    }

    let splitPolygon = chooseSplitPolygon(polygons);

    let backPolygons = [];
    let frontPolygons = [];

    for(let polygon of polygons) {
        if(polygon === splitPolygon) {
            continue;
        }

        if(classifyPolygonCenter(polygon, splitPolygon) == "back") {
            backPolygons.push(polygon);
        } else {
            frontPolygons.push(polygon);
        }
    }

    splitPolygon.backPolygon = splitPolygons(backPolygons);
    splitPolygon.frontPolygon = splitPolygons(frontPolygons);

    return splitPolygon;
}

function collectPolygons(rootPolygon, orderedPolygons) {
    if(rootPolygon == null) {
        return;
    }

    orderedPolygons.push(rootPolygon);
    collectPolygons(rootPolygon.backPolygon, orderedPolygons);
    collectPolygons(rootPolygon.frontPolygon, orderedPolygons);
}

function polygonWordSize(polygon) {
    return 5 + polygon.pointIndices.length + TEXTURE_METADATA_WORDS;
}

function mostCommon(values) {
    let counts = new Map();

    for(let value of values) {
        counts.set(value, (counts.get(value) || 0) + 1);
    }

    let bestValue = values[0];
    let bestCount = 0;

    for(let value of values) {
        let count = counts.get(value);

        if(count > bestCount) {
            bestValue = value;
            bestCount = count;
        }
    }

    return bestValue;
}

/*
 * The OBJ was generated from the PS1 texture pages into a 768x512 atlas.
 * Its V coordinate is the conventional bottom-up value, while the original
 * PS1 UV is a top-down 8-bit coordinate. Convert it back to native page
 * coordinates and rebuild the exact CBA/TSB values used by the TIM pages.
 */
function textureMetadata(polygon) {
    if(polygon.texcoordIndices.length != 3 || polygon.texcoordIndices.some(index => index === null)) {
        return [0, 0, 0, 0, 0, 0, 0, 0];
    }

    let samples = polygon.texcoordIndices.map(index => {
        let texcoord = texcoords[index];
        let atlasU = Math.round(texcoord.u * 768);
        let atlasV = Math.round(texcoord.v * 512);
        let psxV = 512 - atlasV;
        let pageX = Math.floor(atlasU / 256);
        let pageY = Math.floor(psxV / 256);

        if(pageX < 0) {
            pageX = 0;
        } else if(pageX > 2) {
            pageX = 2;
        }

        if(pageY < 0) {
            pageY = 0;
        } else if(pageY > 1) {
            pageY = 1;
        }

        return {
            u: atlasU & 0xff,
            v: psxV & 0xff,
            pageX: pageX,
            pageY: pageY
        };
    });

    let pageX = mostCommon(samples.map(sample => sample.pageX));
    let pageY = mostCommon(samples.map(sample => sample.pageY));
    let pageId = 10 + pageX * 2 + pageY * 16;
    let clut = (480 + pageY * 3 + pageX) << 6;
    let tpage = pageId | 0x80; // 8-bit indexed texture, ABR=0

    return [
        samples[0].u, samples[0].v,
        samples[1].u, samples[1].v,
        samples[2].u, samples[2].v,
        clut, tpage
    ];
}

function buildBspTree(polygons) {
    let rootPolygon = splitPolygons(polygons);
    let orderedPolygons = [];

    collectPolygons(rootPolygon, orderedPolygons);

    let offset = 0;

    for(let polygon of orderedPolygons) {
        polygon.offset = offset;
        offset += polygonWordSize(polygon);
    }

    return orderedPolygons;
}

if(polygons.length > 1) {
    polygons = buildBspTree(polygons);
}

function saveAsSource() {
    console.log("wavefront_object");
    console.log("    dc.w    " + points.length);
    console.log("    dc.w    " + normals.length);
    console.log("    dc.w    " + polygons.length);
    console.log();
    console.log("    dc.w    0,0,0");
    console.log("    dc.l    0,0,5000");
    console.log();

    let maxSize = Math.max(maxX - minX, maxY - minY, maxZ - minZ);
    let resizeFactor = 2000 / maxSize;

    for(let point of points) {
        let x = Math.round(point.x * resizeFactor);
        let y = Math.round(point.y * resizeFactor);
        let z = Math.round(point.z * resizeFactor);

        console.log("    dc.l    " + x + "," + y + "," + z);
    }

    console.log();

    for(let normal of normals) {
        let x = Math.round(normal.x * 0x7fffff) & 0xffffff;
        let y = Math.round(normal.y * 0x7fffff) & 0xffffff;
        let z = Math.round(normal.z * 0x7fffff) & 0xffffff;

        console.log("    dc.l    $" + x.toString(16) + ",$" + y.toString(16) + ",$" + z.toString(16));
    }

    console.log();

    for(let polygon of polygons) {
        let numberOfPoints = polygon.pointIndices.length;
        let colorIndex = polygon.color;
        let normalIndex = points.length + polygon.normalIndex;
        let backIndex = polygon.backPolygon ? polygon.backPolygon.offset + 3 : 0;
        let frontIndex = polygon.frontPolygon ? polygon.frontPolygon.offset + 3 : 0;
        
        let pointIndicesText = "";

        for(let pointIndex of polygon.pointIndices) {
            pointIndicesText += "," + pointIndex + "*3";
        }

        let textureMetadataText = "";

        for(let word of textureMetadata(polygon)) {
            textureMetadataText += "," + word;
        }

        console.log("    dc.w    " + numberOfPoints + "," + colorIndex + "*32," + normalIndex + "*3," + backIndex + "," + frontIndex + pointIndicesText + textureMetadataText);
    }

    console.log("wavefront_object_end")
}

function saveAsBinary() {
    let binarySize = 2 + 2 + 2 + 3 * 2 + 3 * 4;

    binarySize += points.length * 3 * 4;
    binarySize += normals.length * 3 * 4;

    for(let polygon of polygons) {
        binarySize += (5 + polygon.pointIndices.length + TEXTURE_METADATA_WORDS) * 2;
    }

    let binaryBuffer = Buffer.alloc(binarySize);

    let binaryBufferOffset = 0;

    function writeWord(word) {
        binaryBuffer[binaryBufferOffset] = (word >> 8) & 0xff;
        binaryBuffer[binaryBufferOffset + 1] = word & 0xff;

        binaryBufferOffset += 2;
    }

    function writeLong(long) {
        binaryBuffer[binaryBufferOffset] = (long >> 24) & 0xff;
        binaryBuffer[binaryBufferOffset + 1] = (long >> 16) & 0xff;
        binaryBuffer[binaryBufferOffset + 2] = (long >> 8) & 0xff;
        binaryBuffer[binaryBufferOffset + 3] = long & 0xff;

        binaryBufferOffset += 4;
    }

    writeWord(points.length);
    writeWord(normals.length);
    writeWord(polygons.length);

    writeWord(0);
    writeWord(1000);
    writeWord(0);

    writeLong(0);
    writeLong(0);
    writeLong(2500);


    let maxSize = Math.max(maxX - minX, maxY - minY, maxZ - minZ);
    let resizeFactor = 2000 / maxSize;

    for(let point of points) {
        writeLong(Math.round(point.x * resizeFactor));
        writeLong(Math.round(point.y * resizeFactor));
        writeLong(Math.round(point.z * resizeFactor));
    }

    for(let normal of normals) {
        writeLong(Math.round(normal.x * (0x7fffff - 0xff)) & 0xffffff);
        writeLong(Math.round(normal.y * (0x7fffff - 0xff)) & 0xffffff);
        writeLong(Math.round(normal.z * (0x7fffff - 0xff)) & 0xffffff);
    }

    for(let polygon of polygons) {
        writeWord(polygon.pointIndices.length);
        writeWord(polygon.color * 32);
        writeWord((points.length + polygon.normalIndex) * 3);
        writeWord(polygon.backPolygon ? polygon.backPolygon.offset + 3 : 0);
        writeWord(polygon.frontPolygon ? polygon.frontPolygon.offset + 3 : 0);

        for(let pointIndex of polygon.pointIndices) {
            writeWord(pointIndex * 3);
        }

        for(let word of textureMetadata(polygon)) {
            writeWord(word);
        }
    }

    fs.writeFileSync(process.argv[3], binaryBuffer);
}

//saveAsSource();
saveAsBinary();
