const esbuild = require("esbuild");

const production = process.argv.includes("--production");

esbuild
  .build({
    entryPoints: ["src/main.ts"],
    bundle: true,
    format: "cjs",
    platform: "node",
    target: "node18",
    outfile: "dist/main.js",
    external: ["electron"],
    minify: production,
    sourcemap: !production,
    logLevel: "info",
  })
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
