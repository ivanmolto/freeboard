import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The page imports ../results/price-path.json — the committed run — so the replay is the
// artifact the tests keep honest, not a copy of it.
export default defineConfig({
  plugins: [react()],
  server: { fs: { allow: [".."] } },
});
