import type { Denops } from "https://deno.land/x/denops_std@v1.8.0/mod.ts";
import * as autocmd from "https://deno.land/x/denops_std@v1.8.0/autocmd/mod.ts";
import * as anonymous from "https://deno.land/x/denops_std@v1.8.0/anonymous/mod.ts";
import * as batch from "https://deno.land/x/denops_std@v1.8.0/batch/mod.ts";
import * as fn from "https://deno.land/x/denops_std@v1.8.0/function/mod.ts";
import { deferred } from "https://deno.land/std@0.106.0/async/mod.ts";

/**
 * Open a scratch buffer in a new tab page and return immediately.
 */
export async function open(denops: Denops): Promise<void> {
  await denops.cmd("tabnew");
}

/**
 * Open a `filename` buffer in a new tab page and wait the buffer is closed.
 */
export async function edit(denops: Denops, filename: string): Promise<void> {
  await denops.cmd("noswapfile tabedit `=filename`", { filename });
  const [winid, bufnr] = await batch.gather(denops, async (denops) => {
    await fn.win_getid(denops);
    await fn.bufnr(denops);
  }) as [number, number];
  const auname = `guise_editor_${winid}_${bufnr}`;
  const waiter = deferred<void>();
  const [waiterId] = anonymous.add(denops, async (force: unknown) => {
    if (
      !force &&
      (await fn.win_findbuf(denops, bufnr) as number[]).includes(winid)
    ) {
      return;
    }
    await autocmd.group(denops, auname, (helper) => {
      helper.remove();
    });
    anonymous.remove(denops, waiterId);
    waiter.resolve();
  });
  await autocmd.group(denops, auname, (helper) => {
    helper.remove();
    helper.define(
      ["BufEnter", "WinEnter"],
      "*",
      `call denops#request('${denops.name}', '${waiterId}', [v:false])`,
    );
    helper.define(
      "VimLeave",
      "*",
      `call denops#request('${denops.name}', '${waiterId}', [v:true])`,
      {
        once: true,
      },
    );
  });
  await waiter;
}
