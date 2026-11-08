// Loaded with `node --import ./test/setup.ts --test`. Workflow classes must
// extend WorkflowEntrypoint from "cloudflare:workers", which only exists
// inside the Workers runtime; in tests it resolves to a small stand-in.
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") {
      return { url: new URL("./stubs/cloudflare-workers.ts", import.meta.url).href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});
