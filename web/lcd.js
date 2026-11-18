// The Game Boy's screen, drawn as the LCD it was rather than as square grey pixels.
//
// The emulator hands over each frame as 160 x 144 shades of grey.  WebGL then draws it the
// way the original screen showed it:
//   * colour: a shade is how dark the dot is; an unlit dot is the pale green of the screen,
//     a full one dark olive (or, for the "Pocket" look, a grey screen and near-black dots);
//   * dots: there is a thin gap between the dots, and an unlit dot is a shade darker than
//     the gap, so the grid shows faintly, as on the real screen; where the picture is too
//     small for that to read (fewer than ~3 screen pixels a dot) the grid fades out, rather
//     than making moire;
//   * shadows: the dots sit above a reflective backing and cast a soft shadow on it, a
//     little below and to the right;
//   * ghosting: the liquid crystal is slow, darkening in about two frames and clearing in
//     about three, so what moves leaves a trail and what flickers looks half-lit, as it did;
//   * glass: a little light on the top left, and a shadow under the bezel's edge.
// The ghosting runs once per emulated frame (a 160 x 144 pass, ping-ponged between two
// textures); the rest once per displayed frame, at the canvas's own resolution.
//
// The skins: "lcd" all of that; "smooth" the same without the gaps between the dots (no
// one-pixel lines); "classic" the plain grey pixels, as before.  Without WebGL the page still
// works: the shades are coloured and ghosted on a 160 x 144 canvas (no dots, no shadows).
//
//   const screen = createScreen(canvas, { look })   look: "lcd" | "smooth" | "classic"
//   screen.frame(rgba)    a new frame from the emulator (160 x 144 x 4 bytes)
//   screen.draw()         show it (once per animation frame; nothing to do without a new frame)
//   screen.look = "..."   another look

const W = 160, H = 144;
const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
export const LOOKS = {
  lcd:     { name: "LCD",     paper: rgb("#b4bd7b"), ink: rgb("#222f1c"), grid: 1, shadow: 1, glass: 1, ghost: [0.55, 0.4] },
  smooth:  { name: "Smooth",  paper: rgb("#b4bd7b"), ink: rgb("#222f1c"), grid: 0, shadow: 1, glass: 1, ghost: [0.55, 0.4] },
  classic: { name: "Classic", paper: [1, 1, 1],      ink: [0, 0, 0],      grid: 0, shadow: 0, glass: 0, ghost: [1, 1] },
};
// (Skins that were offered before.)
export const OLD_LOOKS = { pocket: "lcd", sharp: "classic" };

const VERT = `
attribute vec2 pos;
varying vec2 uv;
void main() { uv = vec2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5); gl_Position = vec4(pos, 0.0, 1.0); }`;

// How dark each dot is now: it moves towards the new frame's shade at the liquid crystal's pace.
// (Row r of every texture is the Game Boy's line r: this pass works in texels, not in uv.)
const GHOST = `
precision mediump float;
uniform sampler2D frame, prev;
uniform vec2 rate;              // of the way there in one frame: darkening, clearing
void main() {
  vec2 t = gl_FragCoord.xy / vec2(160.0, 144.0);
  float c = 1.0 - dot(texture2D(frame, t).rgb, vec3(0.299, 0.587, 0.114));
  float p = texture2D(prev, t).r;
  float d = mix(p, c, c > p ? rate.x : rate.y);
  if (abs(d - c) < 0.008) d = c;
  gl_FragColor = vec4(d, d, d, 1.0);
}`;

const SHOW = `
precision mediump float;
uniform sampler2D dark;
uniform vec2 size;              // the canvas, in its own pixels
uniform vec3 paper, ink;
uniform float grid, shadow, glass;
varying vec2 uv;
const vec2 GB = vec2(160.0, 144.0);
float at(vec2 cell) { return texture2D(dark, (cell + 0.5) / GB).r; }
void main() {
  vec2 p = uv * GB, cell = floor(p), f = p - cell;
  float d = at(cell);
  // The dots and the gaps between them (antialiased over one canvas pixel).
  float px = GB.x / size.x;
  float show = grid * (1.0 - smoothstep(0.25, 0.45, px));
  float gap = 0.055 * show, h = 0.5 * px;
  vec2 lo = smoothstep(vec2(gap - h), vec2(gap + h), f);
  vec2 hi = 1.0 - smoothstep(vec2(1.0 - gap - h), vec2(1.0 - gap + h), f);
  float cover = mix(1.0, lo.x * lo.y * hi.x * hi.y, show);
  // The shadow the dots cast on the backing: their darkness, softened, a little down-right.
  vec2 q = p - vec2(0.62, 0.72), qc = floor(q), qf = q - qc;
  float s = mix(mix(at(qc), at(qc + vec2(1.0, 0.0)), qf.x), mix(at(qc + vec2(0.0, 1.0)), at(qc + vec2(1.0, 1.0)), qf.x), qf.y);
  vec3 back = paper * (1.0 - 0.38 * shadow * s);
  vec3 lit = mix(back * (1.0 - 0.03 * show), ink, d);
  vec3 col = mix(back, lit, cover);
  // The glass: light from the top left, and the bezel's edge shading the screen a little.
  vec2 e = min(uv, 1.0 - uv);
  float rim = smoothstep(0.0, 0.018, e.x) * smoothstep(0.0, 0.02, e.y);
  vec2 l = uv - vec2(0.3, 0.25);
  col *= 1.0 + glass * (0.05 - 0.1 * dot(l, l) - 0.12 * (1.0 - rim));
  gl_FragColor = vec4(col, 1.0);
}`;

export function createScreen(canvas, { look = "lcd" } = {}) {
  let gl = null;
  try { gl = canvas.getContext("webgl", { alpha: false, antialias: false, depth: false, stencil: false, premultipliedAlpha: false, powerPreference: "low-power" }); } catch (err) { gl = null; }
  return gl ? webglScreen(canvas, gl, look) : flatScreen(canvas, look);
}

function webglScreen(canvas, gl, look) {
  let L = LOOKS[look] || LOOKS.lcd, fresh = false, sized = false, s = null;
  function build() {
    const compile = (type, src) => { const sh = gl.createShader(type); gl.shaderSource(sh, src); gl.compileShader(sh); if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(sh)); return sh; };
    const program = (frag) => {
      const pr = gl.createProgram();
      gl.attachShader(pr, compile(gl.VERTEX_SHADER, VERT)); gl.attachShader(pr, compile(gl.FRAGMENT_SHADER, frag));
      gl.bindAttribLocation(pr, 0, "pos"); gl.linkProgram(pr);
      if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(pr));
      const u = {}; for (const n of ["frame", "prev", "rate", "dark", "size", "paper", "ink", "grid", "shadow", "glass"]) u[n] = gl.getUniformLocation(pr, n);
      return { pr, u };
    };
    const texture = () => {
      const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
      for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.NEAREST], [gl.TEXTURE_MAG_FILTER, gl.NEAREST], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, W, H, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      return t;
    };
    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    const ghosts = [texture(), texture()];
    const fbs = ghosts.map((t) => { const fb = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fb); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0); return fb; });
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    s = { ghost: program(GHOST), show: program(SHOW), frameTex: texture(), ghosts, fbs, cur: 0 };
  }
  build();

  // The canvas's pixels follow its size on the page (device pixels, for a sharp grid).
  const fit = (w, h) => { if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) { canvas.width = w; canvas.height = h; } sized = true; fresh = true; };
  // (The larger of the browser's two counts: some report the device-pixel box in CSS pixels.)
  const onResize = ([en]) => {
    const dpr = window.devicePixelRatio || 1, box = en.devicePixelContentBoxSize && en.devicePixelContentBoxSize[0];
    const w = Math.round(en.contentRect.width * dpr), h = Math.round(en.contentRect.height * dpr);
    fit(Math.max(w, box ? box.inlineSize : 0), Math.max(h, box ? box.blockSize : 0));
  };
  try { new ResizeObserver(onResize).observe(canvas, { box: "device-pixel-content-box" }); }
  catch (err) {
    try { new ResizeObserver(onResize).observe(canvas); }
    catch (err2) { fit(W * 4, H * 4); }
  }
  canvas.addEventListener("webglcontextlost", (ev) => { ev.preventDefault(); s = null; });
  canvas.addEventListener("webglcontextrestored", () => { build(); fresh = true; });

  return {
    webgl: true,
    get look() { return look; },
    set look(v) { if (LOOKS[v]) { look = v; L = LOOKS[v]; fresh = true; } },
    frame(rgba) {
      if (!s) return;
      gl.bindTexture(gl.TEXTURE_2D, s.frameTex);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, rgba);
      const next = 1 - s.cur;
      gl.bindFramebuffer(gl.FRAMEBUFFER, s.fbs[next]);
      gl.viewport(0, 0, W, H);
      gl.useProgram(s.ghost.pr);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, s.frameTex); gl.uniform1i(s.ghost.u.frame, 0);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, s.ghosts[s.cur]); gl.uniform1i(s.ghost.u.prev, 1);
      gl.uniform2f(s.ghost.u.rate, L.ghost[0], L.ghost[1]);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      s.cur = next;
      fresh = true;
    },
    draw() {
      if (!s || !fresh || !sized) return;
      fresh = false;
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.useProgram(s.show.pr);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, s.ghosts[s.cur]); gl.uniform1i(s.show.u.dark, 0);
      gl.uniform2f(s.show.u.size, canvas.width, canvas.height);
      gl.uniform3fv(s.show.u.paper, L.paper); gl.uniform3fv(s.show.u.ink, L.ink);
      gl.uniform1f(s.show.u.grid, L.grid); gl.uniform1f(s.show.u.shadow, L.shadow); gl.uniform1f(s.show.u.glass, L.glass);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    },
  };
}

// No WebGL: the shades coloured and ghosted on the 160 x 144 canvas itself.
function flatScreen(canvas, look) {
  canvas.width = W; canvas.height = H;
  const ctx = canvas.getContext("2d"), img = ctx.createImageData(W, H), dark = new Float32Array(W * H);
  let L = LOOKS[look] || LOOKS.lcd, fresh = false;
  return {
    webgl: false,
    get look() { return look; },
    set look(v) { if (LOOKS[v]) { look = v; L = LOOKS[v]; } },
    frame(rgba) {
      const [on, off] = L.ghost, o = img.data;
      for (let i = 0, j = 0; i < W * H; i++, j += 4) {
        const c = 1 - (0.299 * rgba[j] + 0.587 * rgba[j + 1] + 0.114 * rgba[j + 2]) / 255;
        const p = dark[i], d = p + (c - p) * (c > p ? on : off);
        dark[i] = Math.abs(d - c) < 0.008 ? c : d;
        for (let k = 0; k < 3; k++) o[j + k] = 255 * (L.paper[k] + (L.ink[k] - L.paper[k]) * dark[i]);
        o[j + 3] = 255;
      }
      fresh = true;
    },
    draw() { if (fresh) { fresh = false; ctx.putImageData(img, 0, 0); } },
  };
}
