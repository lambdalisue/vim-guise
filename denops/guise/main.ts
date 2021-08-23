import type { Denops } from "https://deno.land/x/denops_std@v1.7.3/mod.ts";

export function main(denops: Denops): Promise<void> {
  console.log(`${denops.name} is ready`);
  return Promise.resolve();
}
