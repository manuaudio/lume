import * as esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["src/editor.js"],
  bundle: true,
  format: "iife",
  globalName: "LumeEditor",
  outfile: "dist/editor.bundle.js",
  minify: true,
  target: ["safari16"],
});
console.log("built dist/editor.bundle.js");
