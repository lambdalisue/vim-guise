import type { Denops } from "https://deno.land/x/denops_std@v2.1.3/mod.ts";
import * as autocmd from "https://deno.land/x/denops_std@v2.1.3/autocmd/mod.ts";
import * as anonymous from "https://deno.land/x/denops_std@v2.1.3/anonymous/mod.ts";
import * as batch from "https://deno.land/x/denops_std@v2.1.3/batch/mod.ts";
import * as fn from "https://deno.land/x/denops_std@v2.1.3/function/mod.ts";
import * as vars from "https://deno.land/x/denops_std@v2.1.3/variable/mod.ts";
import * as option from "https://deno.land/x/denops_std@v2.1.3/option/mod.ts";
import { deferred } from "https://deno.land/std@0.111.0/async/mod.ts";

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
  let opener = await vars.g.get(denops, "guise_edit_opener", "tab drop");
  await denops.cmd(`silent noswapfile ${opener} \`=filename\` | edit`, {
    filename,
  });
  const [winid, bufnr] = await batch.gather(denops, async (denops) => {
    await fn.win_getid(denops);
    await fn.bufnr(denops);
  }) as [number, number];
  const auname = `guise_editor_${winid}_${bufnr}`;
  const waiter = deferred<void>();
  const [waiterId] = anonymous.add(denops, async () => {
    await autocmd.group(denops, auname, (helper) => {
      helper.remove();
    });
    anonymous.remove(denops, waiterId);
    waiter.resolve();
  });
  await batch.batch(denops, async (denops) => {
    await option.bufhidden.setLocal(denops, "wipe");
    await autocmd.group(denops, auname, (helper) => {
      helper.remove();
      helper.define(
        ["BufWipeout", "VimLeave"],
        "*",
        `call denops#request('${denops.name}', '${waiterId}', [])`,
        {
          once: true,
        },
      );
    });
  });
  await waiter;
}
