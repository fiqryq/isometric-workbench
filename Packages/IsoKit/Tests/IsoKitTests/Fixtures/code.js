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
  };
}
